package com.example.myapplication.ble

import android.annotation.SuppressLint
import android.Manifest
import android.content.pm.PackageManager
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import androidx.core.content.ContextCompat
import com.example.myapplication.R
import com.example.myapplication.localization.AppTextResolver
import com.example.myapplication.protocol.WoonaV2Discovery
import com.example.myapplication.protocol.WoonaV2LiveSession
import com.example.myapplication.protocol.WoonaV2StreamDecoder
import java.util.ArrayDeque
import java.util.Locale
import java.util.IdentityHashMap
import java.util.UUID

interface BleSessionListener {
    fun onDeviceFound(device: BleDevice)
    fun onPacketReceived(packetFragment: ByteArray)
    fun onPacketReceived(
        packetFragment: ByteArray,
        receivedAtWallClockMillis: Long,
        receivedAtMonotonicNs: Long,
    ) = onPacketReceived(packetFragment)
    fun onDiagnosticMessage(message: String)
    fun onCaptureReady()
    fun onV2DiscoveryStarted() = Unit
    /** Called only after explicit V2 discovery has completed successfully. */
    fun onV2DiscoveryReady(device: WoonaV2Discovery.Device) = Unit
    fun onV2LiveStarted(sessionId: Long, streamMask: Long) = Unit
    /** Fully validated frame, still containing original LE sample bytes. */
    fun onV2LiveSamples(event: WoonaV2LiveSession.Event.Samples) = Unit
    fun onV2LiveStopped(sessionId: Long) = Unit
    fun onStateChanged(state: BleSessionState)
    fun onError(message: String, throwable: Throwable? = null)
}

interface BleSessionController {
    fun currentState(): BleSessionState
    fun currentTransportProfile(): BleTransportProfile
    fun updateTransportProfile(profile: BleTransportProfile)
    fun startScanning()
    fun stopScanning()
    fun connect(address: String)
    /** Explicit preview intent; this must not create a persistent recording. */
    fun connectForV2Preview(address: String) = connect(address)
    /** Explicit opt-in; never probe Legacy automatically (HELLO switches firmware to V2). */
    fun beginV2Discovery(): Boolean = false
    /** Only after explicit discovery, never during an ordinary Legacy capture. */
    fun startV2Live(streamMask: Long): Boolean = false
    fun stopV2Live(): Boolean = false
    fun setCaptureActive(active: Boolean) = Unit
    fun disconnect()
    fun close()
}

class BleSessionManager(
    private val context: Context,
    private val serviceUuid: UUID,
    private val characteristicUuid: UUID,
    private val descriptorUuid: UUID,
    private val listener: BleSessionListener,
    private val appTextResolver: AppTextResolver,
) : BleSessionController {
    private val scanHandler = Handler(Looper.getMainLooper())
    private val bluetoothAdapter by lazy {
        (context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
    }

    private val v2WriteUuid = UUID.fromString("0000fff2-0000-1000-8000-00805f9b34fb")
    private val v2GattWrites = WoonaV2GattWriteQueue()
    private val v2PendingFrames = ArrayDeque<ByteArray>()
    private var v2Discovery: WoonaV2Discovery? = null
    private var v2Live: WoonaV2LiveSession? = null
    private var v2LiveReceiver: WoonaV2StreamDecoder? = null
    private var v2SupportsLive = false
    private var v2WriteCharacteristic: BluetoothGattCharacteristic? = null
    @Volatile private var v2Requested = false
    @Volatile private var v2ConnectionIntent = false
    private var v2Failed = false
    private val v2ResponseTimeoutRunnable = Runnable { synchronized(this) {
        val discovery = v2Discovery ?: return@synchronized
        if (!v2Requested || v2Failed) return@synchronized
        if (discovery.phase == WoonaV2Discovery.Phase.READY) {
            val live = v2Live ?: return@synchronized
            if (live.phase == WoonaV2LiveSession.Phase.WAIT_START ||
                live.phase == WoonaV2LiveSession.Phase.WAIT_STOP
            ) dispatchV2LiveEvent(live.onResponseTimeout())
        } else if (discovery.phase != WoonaV2Discovery.Phase.FAILED) {
            emitDiagnostic("V2 response timeout in ${discovery.phase}; retrying if possible", DiagnosticLevel.WARNING)
            dispatchV2Event(discovery.onResponseTimeout())
        }
    } }
    private val v2ChunkTimeoutRunnable = Runnable { synchronized(this) {
        if (v2Requested && v2GattWrites.isBusy) failV2Discovery("FFF2 GATT write timed out")
    } }

    private val discoveredAddresses = linkedSetOf<String>()
    private val stopScanRunnable = Runnable { stopScanning() }

    private var bluetoothGatt: BluetoothGatt? = null
    private val gattGenerations = IdentityHashMap<BluetoothGatt, Long>()
    private var nextGattGeneration = 0L
    private var activeGattGeneration: Long? = null
    private var activeDeviceAddress: String? = null
    private var pendingNotificationDescriptorUuid: UUID? = null
    private var notificationsReady = false
    private var sessionState = BleSessionState.IDLE
    @Volatile
    private var transportProfile = BleTransportProfile.COMPATIBILITY
    @Volatile
    private var captureActive = false
    @Volatile
    private var activeTransportProfile: BleTransportProfile? = null
    private var negotiatedMtu: Int? = null
    private var negotiatedTxPhy: Int? = null
    private var negotiatedRxPhy: Int? = null
    private var negotiatedConnectionIntervalUnits: Int? = null
    private var negotiatedConnectionLatency: Int? = null
    private var negotiatedSupervisionTimeoutUnits: Int? = null
    private var notificationCount = 0L
    private var notificationGapSampleCount = 0L
    private var notificationGapTotalMillis = 0L
    private var notificationGapMaxMillis = 0L
    private var longNotificationGapCount = 0L
    private var lastNotificationElapsedRealtimeMs: Long? = null
    private var notificationMonitoringStartedElapsedRealtimeMs: Long? = null
    private var lastLongGapLoggedElapsedRealtimeMs = 0L
    private var manualDisconnectRequested = false
    private var recoveryInProgress = false
    private var awaitingRecoveryNotification = false
    private var recoveryAttempt = 0
    private var recoveryStartedElapsedRealtimeMs: Long? = null
    private val recoveryRunnable = Runnable {
        val address = activeDeviceAddress
        if (!manualDisconnectRequested && recoveryInProgress && address != null) {
            openGatt(address)
        }
    }
    private val notificationWatchdogRunnable = object : Runnable {
        override fun run() {
            if (!isCurrentGattConnected()) return

            val now = SystemClock.elapsedRealtime()
            val lastActivity = lastNotificationElapsedRealtimeMs
                ?: notificationMonitoringStartedElapsedRealtimeMs
                ?: now
            if (now - lastActivity >= NOTIFICATION_SILENCE_TIMEOUT_MS) {
                beginTransportRecovery(now - lastActivity)
                return
            }
            scanHandler.postDelayed(this, NOTIFICATION_WATCHDOG_INTERVAL_MS)
        }
    }
    private val gattConnectionTimeoutRunnable = Runnable {
        val gatt = bluetoothGatt
        if (gatt == null || sessionState != BleSessionState.CONNECTING || !isCurrentGatt(gatt)) return@Runnable

        val wasRecovering = recoveryInProgress
        clearGattReference(gatt)
        safeCloseGatt(gatt)
        if (wasRecovering) {
            scheduleNextRecoveryAttempt()
        } else {
            transition(BleSessionEvent.Failure)
            listener.onError("BLE connection setup timed out")
        }
    }
    private val gattSetupTimeoutRunnable = Runnable {
        val gatt = bluetoothGatt
        if (gatt == null || notificationsReady || !isCurrentGatt(gatt)) return@Runnable
        handleGattSetupFailure(gatt, "BLE notification setup timed out")
    }
    private val recoveryConfirmationRunnable = Runnable {
        if (!recoveryInProgress || !awaitingRecoveryNotification) return@Runnable
        val gatt = bluetoothGatt
        if (gatt != null && isCurrentGatt(gatt)) {
            clearGattReference(gatt)
            safeCloseGatt(gatt)
        }
        awaitingRecoveryNotification = false
        scheduleNextRecoveryAttempt()
    }
    private val transportSummaryRunnable = object : Runnable {
        override fun run() {
            if (sessionState != BleSessionState.CONNECTED || bluetoothGatt == null) return
            emitDiagnostic(
                message = buildTransportSummaryMessage(),
                level = DiagnosticLevel.INFO,
            )
            scanHandler.postDelayed(this, TRANSPORT_SUMMARY_INTERVAL_MS)
        }
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            if (
                ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.BLUETOOTH_CONNECT,
                ) != PackageManager.PERMISSION_GRANTED
            ) {
                listener.onError(appTextResolver.getString(R.string.ble_missing_connect_permission_scan_result))
                return
            }

            val address = result.device.address
            if (!discoveredAddresses.add(address)) return

            listener.onDeviceFound(
                BleDevice(
                    name = result.device.name ?: appTextResolver.getString(R.string.ble_unknown_device),
                    address = address,
                ),
            )
        }

        override fun onScanFailed(errorCode: Int) {
            scanHandler.removeCallbacks(stopScanRunnable)
            transition(BleSessionEvent.Failure)
            listener.onError(appTextResolver.getString(R.string.ble_scan_failed, describeScanFailure(errorCode)))
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (!isCurrentGatt(gatt)) {
                Log.w(TAG, "Ignoring stale GATT state callback generation=${gattGenerations[gatt]}")
                return
            }

            when {
                status != BluetoothGatt.GATT_SUCCESS -> {
                    stopTransportSummaryLoop()
                    stopNotificationWatchdog()
                    val wasRecovering = recoveryInProgress
                    clearGattReference(gatt)
                    safeCloseGatt(gatt)
                    when (bleDisconnectAction(manualDisconnectRequested, wasRecovering,
                        captureActive && activeDeviceAddress != null)) {
                        BleDisconnectAction.DISCONNECTED -> transition(BleSessionEvent.Disconnected)
                        BleDisconnectAction.RETRY -> scheduleNextRecoveryAttempt()
                        BleDisconnectAction.RECOVER -> beginTransportRecovery(0, "GATT error $status")
                        BleDisconnectAction.FAIL -> {
                            transition(BleSessionEvent.Failure)
                            listener.onError(appTextResolver.getString(R.string.ble_gatt_connection_error, status))
                        }
                    }
                }

                newState == BluetoothProfile.STATE_CONNECTED -> {
                    scanHandler.removeCallbacks(gattConnectionTimeoutRunnable)
                    scanHandler.removeCallbacks(gattSetupTimeoutRunnable)
                    if (manualDisconnectRequested) {
                        clearGattReference(gatt)
                        safeCloseGatt(gatt)
                        transition(BleSessionEvent.Disconnected)
                        return
                    }
                    transition(BleSessionEvent.Connected)
                    resetTransportDiagnostics()
                    scanHandler.postDelayed(gattSetupTimeoutRunnable, GATT_SETUP_TIMEOUT_MS)
                    val activeProfile = activeTransportProfile ?: transportProfile
                    if (
                        ContextCompat.checkSelfPermission(
                            context,
                            Manifest.permission.BLUETOOTH_CONNECT,
                        ) != PackageManager.PERMISSION_GRANTED
                    ) {
                        handleGattSetupFailure(
                            gatt,
                            appTextResolver.getString(R.string.ble_missing_connect_permission_before_mtu),
                        )
                        return
                    }

                    emitDiagnostic(
                        message = appTextResolver.getString(
                            R.string.ble_transport_profile_message,
                            appTextResolver.getString(activeProfile.titleRes),
                            appTextResolver.getString(activeProfile.shortDescriptionRes),
                        ),
                        level = DiagnosticLevel.INFO,
                    )
                    emitDiagnostic(
                        message = appTextResolver.getString(R.string.ble_best_effort_connection_logging),
                        level = DiagnosticLevel.INFO,
                    )

                    if (activeProfile.requestsHighConnectionPriority) {
                        val priorityRequested = gatt.requestConnectionPriority(
                            BluetoothGatt.CONNECTION_PRIORITY_HIGH,
                        )
                        if (priorityRequested) {
                            emitDiagnostic(
                                message = appTextResolver.getString(R.string.ble_requested_high_priority),
                                level = DiagnosticLevel.INFO,
                            )
                        } else {
                            emitDiagnostic(
                                message = appTextResolver.getString(R.string.ble_failed_high_priority),
                                level = DiagnosticLevel.WARNING,
                            )
                        }
                    } else {
                        emitDiagnostic(
                            message = appTextResolver.getString(R.string.ble_skipped_priority_profile),
                            level = DiagnosticLevel.INFO,
                        )
                    }

                    val requestedMtu = activeProfile.requestedMtu
                    if (requestedMtu != null) {
                        val mtuRequested = gatt.requestMtu(requestedMtu)
                        if (mtuRequested) {
                            emitDiagnostic(
                                message = appTextResolver.getString(R.string.ble_requested_mtu, requestedMtu),
                                level = DiagnosticLevel.INFO,
                            )
                        } else {
                            emitDiagnostic(
                                message = appTextResolver.getString(R.string.ble_failed_mtu_continue, requestedMtu),
                                level = DiagnosticLevel.WARNING,
                            )
                            requestPreferredPhy(gatt, activeProfile)
                            gatt.discoverServices()
                        }
                    } else {
                        emitDiagnostic(
                            message = appTextResolver.getString(R.string.ble_skipped_explicit_mtu),
                            level = DiagnosticLevel.INFO,
                        )
                        requestPreferredPhy(gatt, activeProfile)
                        gatt.discoverServices()
                    }
                }

                newState == BluetoothProfile.STATE_DISCONNECTED -> {
                    stopTransportSummaryLoop()
                    stopNotificationWatchdog()
                    val wasRecovering = recoveryInProgress
                    clearGattReference(gatt)
                    safeCloseGatt(gatt)
                    when (bleDisconnectAction(manualDisconnectRequested, wasRecovering,
                        captureActive && activeDeviceAddress != null)) {
                        BleDisconnectAction.RETRY -> scheduleNextRecoveryAttempt()
                        BleDisconnectAction.RECOVER -> beginTransportRecovery(0, "Unexpected GATT disconnect")
                        else -> transition(BleSessionEvent.Disconnected)
                    }
                }
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            if (!isCurrentGatt(gatt)) return

            if (
                ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.BLUETOOTH_CONNECT,
                ) != PackageManager.PERMISSION_GRANTED
            ) {
                handleGattSetupFailure(
                    gatt,
                    appTextResolver.getString(R.string.ble_missing_connect_permission_after_mtu),
                )
                return
            }

            emitDiagnostic(
                message = appTextResolver.getString(R.string.ble_mtu_changed, mtu, status),
                level = DiagnosticLevel.INFO,
            )
            negotiatedMtu = mtu
            emitDiagnostic(
                message = buildTransportSnapshotMessage(),
                level = DiagnosticLevel.INFO,
            )
            if (status == BluetoothGatt.GATT_SUCCESS) {
                requestPreferredPhy(gatt, activeTransportProfile ?: transportProfile)
            }
            gatt.discoverServices()
        }

        override fun onPhyUpdate(
            gatt: BluetoothGatt,
            txPhy: Int,
            rxPhy: Int,
            status: Int,
        ) {
            if (!isCurrentGatt(gatt)) return

            emitDiagnostic(
                message = appTextResolver.getString(R.string.ble_phy_updated, txPhy, rxPhy, status),
                level = DiagnosticLevel.INFO,
            )
            negotiatedTxPhy = txPhy
            negotiatedRxPhy = rxPhy
            emitDiagnostic(
                message = buildTransportSnapshotMessage(),
                level = DiagnosticLevel.INFO,
            )
        }

        // This callback is hidden from the public Android SDK stubs, so this is a
        // best-effort runtime hook for debug builds rather than a guaranteed override.
        @Suppress("unused")
        fun onConnectionUpdated(
            gatt: BluetoothGatt,
            interval: Int,
            latency: Int,
            timeout: Int,
            status: Int,
        ) {
            if (!isCurrentGatt(gatt)) return

            negotiatedConnectionIntervalUnits = interval
            negotiatedConnectionLatency = latency
            negotiatedSupervisionTimeoutUnits = timeout
            emitDiagnostic(
                message = appTextResolver.getString(
                    R.string.ble_connection_updated,
                    formatConnectionIntervalMillis(interval),
                    latency,
                    timeout * 10,
                    status,
                ),
                level = DiagnosticLevel.INFO,
            )
            emitDiagnostic(
                message = buildTransportSnapshotMessage(),
                level = DiagnosticLevel.INFO,
            )
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (!isCurrentGatt(gatt)) return
            if (manualDisconnectRequested) {
                clearGattReference(gatt)
                safeCloseGatt(gatt)
                return
            }

            if (
                ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.BLUETOOTH_CONNECT,
                ) != PackageManager.PERMISSION_GRANTED
            ) {
                handleGattSetupFailure(
                    gatt,
                    appTextResolver.getString(R.string.ble_missing_connect_permission_service_discovery),
                )
                return
            }

            if (status != BluetoothGatt.GATT_SUCCESS) {
                handleGattSetupFailure(
                    gatt,
                    appTextResolver.getString(R.string.ble_service_discovery_failed, status),
                )
                return
            }

            val service = gatt.getService(serviceUuid)
            val characteristic = service?.getCharacteristic(characteristicUuid)
            val descriptor = characteristic?.getDescriptor(descriptorUuid)

            if (service == null || characteristic == null || descriptor == null) {
                handleGattSetupFailure(
                    gatt,
                    appTextResolver.getString(R.string.ble_required_service_missing),
                )
                return
            }

            if (!gatt.setCharacteristicNotification(characteristic, true)) {
                pendingNotificationDescriptorUuid = null
                handleGattSetupFailure(
                    gatt,
                    appTextResolver.getString(R.string.ble_failed_register_notification_callback),
                )
                return
            }

            pendingNotificationDescriptorUuid = descriptor.uuid
            val writeResult = writeNotificationDescriptor(gatt, descriptor)

            if (writeResult != BluetoothStatusCodes.SUCCESS) {
                pendingNotificationDescriptorUuid = null
                stopTransportSummaryLoop()
                stopNotificationWatchdog()
                val wasRecovering = recoveryInProgress
                clearGattReference(gatt)
                safeCloseGatt(gatt)
                if (wasRecovering) {
                    scheduleNextRecoveryAttempt()
                } else {
                    transition(BleSessionEvent.Failure)
                    listener.onError(appTextResolver.getString(R.string.ble_failed_enable_notifications, writeResult))
                }
                return
            }
        }

        override fun onDescriptorWrite(
            gatt: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int,
        ) {
            if (!isCurrentGatt(gatt)) return
            if (manualDisconnectRequested) {
                clearGattReference(gatt)
                safeCloseGatt(gatt)
                return
            }

            val pendingDescriptorUuid = pendingNotificationDescriptorUuid
            if (pendingDescriptorUuid == null || descriptor.uuid != pendingDescriptorUuid) {
                return
            }
            pendingNotificationDescriptorUuid = null

            if (!hasConnectPermission()) {
                stopTransportSummaryLoop()
                stopNotificationWatchdog()
                val wasRecovering = recoveryInProgress
                clearGattReference(gatt)
                safeCloseGatt(gatt)
                if (wasRecovering) {
                    scheduleNextRecoveryAttempt()
                } else {
                    transition(BleSessionEvent.Failure)
                    listener.onError(appTextResolver.getString(R.string.ble_missing_connect_permission_notification_setup))
                }
                return
            }

            if (status != BluetoothGatt.GATT_SUCCESS) {
                stopTransportSummaryLoop()
                stopNotificationWatchdog()
                val wasRecovering = recoveryInProgress
                clearGattReference(gatt)
                safeCloseGatt(gatt)
                if (wasRecovering) {
                    scheduleNextRecoveryAttempt()
                } else {
                    transition(BleSessionEvent.Failure)
                    listener.onError(appTextResolver.getString(R.string.ble_descriptor_write_failed, status))
                }
                return
            }

            val wasRecovering = recoveryInProgress
            if (wasRecovering) {
                awaitingRecoveryNotification = true
                startRecoveryConfirmation()
            } else {
                recoveryAttempt = 0
                recoveryStartedElapsedRealtimeMs = null
            }
            notificationsReady = true
            scanHandler.removeCallbacks(gattSetupTimeoutRunnable)
            startTransportSummaryLoop()
            if (!wasRecovering && captureActive) startNotificationWatchdog()
            if (v2ConnectionIntent) {
                listener.onV2DiscoveryStarted()
                if (!beginV2Discovery()) failV2Discovery("V2 negotiation is unavailable on this connection")
            } else {
                listener.onCaptureReady()
            }
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            if (!isCurrentGatt(gatt) || characteristic.uuid != v2WriteUuid) return
            synchronized(this@BleSessionManager) {
                if (!isCurrentGatt(gatt) || !v2Requested || v2Failed) return@synchronized
                scanHandler.removeCallbacks(v2ChunkTimeoutRunnable)
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    failV2Discovery("FFF2 GATT write failed (status=$status)")
                } else {
                    try {
                        val nextChunk = v2GattWrites.acknowledgeChunk()
                        if (nextChunk != null) writeV2Chunk(gatt, nextChunk)
                        else startNextV2Frame(gatt)
                    } catch (exception: IllegalStateException) {
                        failV2Discovery("Unexpected FFF2 write callback: ${exception.message}")
                    }
                }
            }
        }

        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
        ) {
            if (!isCurrentGatt(gatt) || characteristic.uuid != characteristicUuid) return
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) return
            val value = characteristic.value?.clone() ?: return
            handleCharacteristicChanged(gatt, value)
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            if (!isCurrentGatt(gatt) || characteristic.uuid != characteristicUuid) return
            handleCharacteristicChanged(gatt, value)
        }
    }

    override fun currentState(): BleSessionState = sessionState

    override fun currentTransportProfile(): BleTransportProfile = transportProfile

    override fun updateTransportProfile(profile: BleTransportProfile) {
        transportProfile = profile
    }

    @Synchronized
    override fun beginV2Discovery(): Boolean {
        val gatt = bluetoothGatt ?: return false
        if (v2Requested || captureActive || recoveryInProgress || !notificationsReady ||
            sessionState != BleSessionState.CONNECTED || !isCurrentGatt(gatt) || !hasConnectPermission()
        ) return false

        val writeCharacteristic = gatt.getService(serviceUuid)?.getCharacteristic(v2WriteUuid)
        if (writeCharacteristic == null ||
            writeCharacteristic.properties and BluetoothGattCharacteristic.PROPERTY_WRITE == 0
        ) {
            emitDiagnostic("V2 requires FFF2 with acknowledged GATT WRITE", DiagnosticLevel.WARNING)
            return false
        }

        val discovery = WoonaV2Discovery()
        v2WriteCharacteristic = writeCharacteristic
        v2Discovery = discovery
        v2Failed = false
        v2Requested = true
        emitDiagnostic("V2 discovery explicitly requested; Legacy packets are now ignored", DiagnosticLevel.INFO)
        dispatchV2Event(discovery.begin())
        return true
    }

    @Synchronized
    override fun startV2Live(streamMask: Long): Boolean {
        val gatt = bluetoothGatt ?: return false
        val live = v2Live ?: return false
        if (!v2Requested || v2Failed || !v2SupportsLive || !isCurrentGatt(gatt) || !notificationsReady ||
            !hasConnectPermission() || captureActive || recoveryInProgress ||
            v2Discovery?.phase != WoonaV2Discovery.Phase.READY ||
            live.phase !in setOf(WoonaV2LiveSession.Phase.IDLE, WoonaV2LiveSession.Phase.STOPPED)
        ) return false
        return try {
            dispatchV2LiveEvent(live.start(streamMask))
            true
        } catch (exception: IllegalArgumentException) {
            emitDiagnostic("V2 LIVE start rejected: ${exception.message}", DiagnosticLevel.WARNING)
            false
        }
    }

    @Synchronized
    override fun stopV2Live(): Boolean {
        val gatt = bluetoothGatt ?: return false
        val live = v2Live ?: return false
        if (!v2Requested || v2Failed || !isCurrentGatt(gatt) || !hasConnectPermission() ||
            live.phase != WoonaV2LiveSession.Phase.RUNNING) return false
        dispatchV2LiveEvent(live.stop())
        return true
    }

    override fun setCaptureActive(active: Boolean) {
        if (active && v2Requested) {
            listener.onError("Legacy capture is not available after V2 HELLO; disconnect or use the V2 capture path")
            return
        }
        captureActive = active
        if (!active) {
            stopNotificationWatchdog()
        } else if (sessionState == BleSessionState.CONNECTED && !recoveryInProgress) {
            startNotificationWatchdog()
        }
    }

    override fun startScanning() {
        if (!hasScanPermission()) {
            transition(BleSessionEvent.Failure)
            listener.onError(appTextResolver.getString(R.string.ble_missing_scan_permission))
            return
        }

        if (!hasConnectPermission()) {
            transition(BleSessionEvent.Failure)
            listener.onError(appTextResolver.getString(R.string.ble_missing_connect_permission))
            return
        }

        val adapter = bluetoothAdapter
        if (adapter == null) {
            transition(BleSessionEvent.Failure)
            listener.onError(appTextResolver.getString(R.string.bluetooth_adapter_unavailable))
            return
        }

        if (!adapter.isEnabled) {
            transition(BleSessionEvent.Failure)
            listener.onError(appTextResolver.getString(R.string.bluetooth_off))
            return
        }

        val scanner = adapter.bluetoothLeScanner
        if (scanner == null) {
            transition(BleSessionEvent.Failure)
            listener.onError(appTextResolver.getString(R.string.ble_scanner_unavailable))
            return
        }

        try {
            discoveredAddresses.clear()
            scanner.startScan(scanCallback)
            scanHandler.removeCallbacks(stopScanRunnable)
            scanHandler.postDelayed(stopScanRunnable, SCAN_TIMEOUT_MS)
            transition(BleSessionEvent.ScanStarted)
        } catch (exception: SecurityException) {
            transition(BleSessionEvent.Failure)
            listener.onError(appTextResolver.getString(R.string.ble_failed_start_scan), exception)
        }
    }

    override fun stopScanning() {
        scanHandler.removeCallbacks(stopScanRunnable)
        if (!hasScanPermission()) {
            transition(BleSessionEvent.ScanStopped)
            listener.onError(appTextResolver.getString(R.string.ble_missing_scan_permission_stop))
            return
        }

        try {
            bluetoothAdapter?.bluetoothLeScanner?.stopScan(scanCallback)
        } catch (exception: SecurityException) {
            listener.onError(appTextResolver.getString(R.string.ble_failed_stop_scan), exception)
        }
        transition(BleSessionEvent.ScanStopped)
    }

    override fun connect(address: String) = connectWithIntent(address, false)

    override fun connectForV2Preview(address: String) = connectWithIntent(address, true)

    @Synchronized
    private fun connectWithIntent(address: String, preview: Boolean) {
        manualDisconnectRequested = false
        recoveryInProgress = false
        awaitingRecoveryNotification = false
        recoveryAttempt = 0
        recoveryStartedElapsedRealtimeMs = null
        scanHandler.removeCallbacks(recoveryRunnable)
        if (!hasConnectPermission()) {
            transition(BleSessionEvent.Failure)
            listener.onError(appTextResolver.getString(R.string.ble_missing_connect_permission))
            return
        }

        forceCloseCurrentGatt()
        v2ConnectionIntent = preview
        activeDeviceAddress = address
        openGatt(address)
    }

    @SuppressLint("MissingPermission")
    private fun openGatt(address: String) {
        activeTransportProfile = transportProfile

        val device = bluetoothAdapter?.getRemoteDevice(address)
        if (device == null) {
            activeTransportProfile = null
            if (recoveryInProgress) {
                scheduleNextRecoveryAttempt()
            } else {
                transition(BleSessionEvent.Failure)
                listener.onError(appTextResolver.getString(R.string.ble_device_not_found, address))
            }
            return
        }

        try {
            val gatt = device.connectGatt(context, false, gattCallback)
            val generation = ++nextGattGeneration
            gattGenerations[gatt] = generation
            activeGattGeneration = generation
            bluetoothGatt = gatt
            notificationsReady = false
            transition(BleSessionEvent.ConnectRequested)
            scanHandler.postDelayed(gattConnectionTimeoutRunnable, GATT_CONNECTION_TIMEOUT_MS)
        } catch (exception: SecurityException) {
            activeTransportProfile = null
            if (recoveryInProgress) {
                scheduleNextRecoveryAttempt()
            } else {
                transition(BleSessionEvent.Failure)
                listener.onError(appTextResolver.getString(R.string.ble_failed_connect_device), exception)
            }
        }
    }

    override fun disconnect() {
        captureActive = false
        manualDisconnectRequested = true
        recoveryInProgress = false
        awaitingRecoveryNotification = false
        recoveryAttempt = 0
        recoveryStartedElapsedRealtimeMs = null
        scanHandler.removeCallbacks(recoveryRunnable)
        stopNotificationWatchdog()
        activeDeviceAddress = null
        val gatt = bluetoothGatt ?: return
        if (!hasConnectPermission()) {
            clearGattReference(gatt)
            safeCloseGatt(gatt)
            transition(BleSessionEvent.Disconnected)
            listener.onError(appTextResolver.getString(R.string.ble_missing_connect_permission_disconnect))
            return
        }

        try {
            gatt.disconnect()
        } catch (exception: SecurityException) {
            clearGattReference(gatt)
            safeCloseGatt(gatt)
            transition(BleSessionEvent.Disconnected)
            listener.onError(appTextResolver.getString(R.string.ble_failed_disconnect_device), exception)
        }
    }

    override fun close() {
        captureActive = false
        manualDisconnectRequested = true
        recoveryInProgress = false
        awaitingRecoveryNotification = false
        recoveryAttempt = 0
        recoveryStartedElapsedRealtimeMs = null
        scanHandler.removeCallbacks(recoveryRunnable)
        stopNotificationWatchdog()
        activeDeviceAddress = null
        stopTransportSummaryLoop()
        stopScanning()
        forceCloseCurrentGatt()
    }

    private fun transition(event: BleSessionEvent) {
        sessionState = BleSessionStateMachine.transition(sessionState, event)
        listener.onStateChanged(sessionState)
    }

    @Synchronized
    private fun clearGattReference(gatt: BluetoothGatt) {
        if (bluetoothGatt === gatt) {
            scanHandler.removeCallbacks(gattConnectionTimeoutRunnable)
            scanHandler.removeCallbacks(gattSetupTimeoutRunnable)
            resetV2OnDisconnect()
            bluetoothGatt = null
            gattGenerations.remove(gatt)
            activeGattGeneration = null
            pendingNotificationDescriptorUuid = null
            activeTransportProfile = null
            notificationsReady = false
            awaitingRecoveryNotification = false
            notificationMonitoringStartedElapsedRealtimeMs = null
            resetTransportDiagnostics()
        }
    }

    @SuppressLint("MissingPermission")
    private fun requestPreferredPhy(
        gatt: BluetoothGatt,
        profile: BleTransportProfile,
    ) {
        when (profile.preferredPhy) {
            PreferredPhyMode.LE_2M -> {
                if (!hasConnectPermission()) {
                    listener.onError(appTextResolver.getString(R.string.ble_missing_connect_permission))
                    return
                }

                emitDiagnostic(
                    message = appTextResolver.getString(R.string.ble_requested_preferred_phy),
                    level = DiagnosticLevel.INFO,
                )
                try {
                    gatt.setPreferredPhy(
                        BluetoothDevice.PHY_LE_2M_MASK,
                        BluetoothDevice.PHY_LE_2M_MASK,
                        BluetoothDevice.PHY_OPTION_NO_PREFERRED,
                    )
                } catch (exception: SecurityException) {
                    listener.onError(appTextResolver.getString(R.string.ble_missing_connect_permission), exception)
                }
            }

            PreferredPhyMode.SYSTEM_DEFAULT -> {
                emitDiagnostic(
                    message = appTextResolver.getString(R.string.ble_skipped_preferred_phy),
                    level = DiagnosticLevel.INFO,
                )
            }
        }
    }

    @Suppress("DEPRECATION")
    @SuppressLint("MissingPermission")
    private fun writeNotificationDescriptor(
        gatt: BluetoothGatt,
        descriptor: BluetoothGattDescriptor,
    ): Int {
        if (!hasConnectPermission()) {
            return BluetoothStatusCodes.ERROR_MISSING_BLUETOOTH_CONNECT_PERMISSION
        }

        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeDescriptor(
                    descriptor,
                    BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE,
                )
            } else {
                if (!descriptor.setValue(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)) {
                    BluetoothStatusCodes.ERROR_UNKNOWN
                } else if (gatt.writeDescriptor(descriptor)) {
                    BluetoothStatusCodes.SUCCESS
                } else {
                    BluetoothStatusCodes.ERROR_UNKNOWN
                }
            }
        } catch (_: SecurityException) {
            BluetoothStatusCodes.ERROR_MISSING_BLUETOOTH_CONNECT_PERMISSION
        }
    }

    @Synchronized
    private fun handleCharacteristicChanged(sourceGatt: BluetoothGatt, value: ByteArray) {
        if (!isCurrentGatt(sourceGatt)) return
        val nowElapsedRealtimeMs = SystemClock.elapsedRealtime()
        val previousNotificationElapsedRealtimeMs = lastNotificationElapsedRealtimeMs
        lastNotificationElapsedRealtimeMs = nowElapsedRealtimeMs
        notificationCount++
        if (recoveryInProgress && awaitingRecoveryNotification) {
            awaitingRecoveryNotification = false
            recoveryInProgress = false
            recoveryAttempt = 0
            recoveryStartedElapsedRealtimeMs = null
            scanHandler.removeCallbacks(recoveryConfirmationRunnable)
            emitDiagnostic(
                message = "BLE transport recovered after notification silence",
                level = DiagnosticLevel.INFO,
            )
            if (captureActive) startNotificationWatchdog()
        }
        if (previousNotificationElapsedRealtimeMs != null) {
            val gapMillis = (nowElapsedRealtimeMs - previousNotificationElapsedRealtimeMs).coerceAtLeast(0L)
            notificationGapSampleCount++
            notificationGapTotalMillis += gapMillis
            notificationGapMaxMillis = maxOf(notificationGapMaxMillis, gapMillis)
            val longGapThresholdMillis = longNotificationGapThresholdMillis()
            if (gapMillis >= longGapThresholdMillis) {
                longNotificationGapCount++
                if (nowElapsedRealtimeMs - lastLongGapLoggedElapsedRealtimeMs >= LONG_GAP_LOG_COOLDOWN_MS) {
                    lastLongGapLoggedElapsedRealtimeMs = nowElapsedRealtimeMs
                    emitDiagnostic(
                        message = appTextResolver.getString(
                            R.string.ble_notification_gap,
                            gapMillis,
                            longGapThresholdMillis,
                            notificationCount,
                        ),
                        level = DiagnosticLevel.WARNING,
                    )
                }
            }
        }
        if (v2Requested) {
            // The firmware leaves Legacy mode as soon as it accepts HELLO. Do not
            // feed any V2 bytes to the Legacy PacketAssembler, even on failure.
            val gatt = sourceGatt
            if (isCurrentGatt(gatt) && v2Requested && !v2Failed) {
                    if (v2Discovery?.phase == WoonaV2Discovery.Phase.READY) {
                        val live = v2Live
                        val frames = v2LiveReceiver?.append(value.clone()).orEmpty()
                        for (frame in frames) {
                            val events = live?.receive(frame).orEmpty()
                            if (events.any { it !is WoonaV2LiveSession.Event.Samples }) {
                                scanHandler.removeCallbacks(v2ResponseTimeoutRunnable)
                            }
                            events.forEach(::dispatchV2LiveEvent)
                        }
                    } else {
                        val events = v2Discovery?.receive(value.clone()).orEmpty()
                        if (events.isNotEmpty()) scanHandler.removeCallbacks(v2ResponseTimeoutRunnable)
                        events.forEach(::dispatchV2Event)
                    }
            }
            return
        }
        if (v2ConnectionIntent) return // Legacy bytes queued before HELLO are not preview samples.
        listener.onPacketReceived(
            packetFragment = value.clone(),
            receivedAtWallClockMillis = System.currentTimeMillis(),
            receivedAtMonotonicNs = SystemClock.elapsedRealtimeNanos(),
        )
    }

    @Synchronized
    private fun dispatchV2Event(event: WoonaV2Discovery.Event) {
        if (v2Failed) return
        when (event) {
            is WoonaV2Discovery.Event.Transmit -> {
                emitDiagnostic("V2 command queued (${v2Discovery?.phase}, ${event.bytes.size} bytes COBS)",
                    DiagnosticLevel.INFO)
                v2PendingFrames.addLast(event.bytes.clone())
                bluetoothGatt?.let(::startNextV2Frame)
            }
            is WoonaV2Discovery.Event.Complete -> {
                scanHandler.removeCallbacks(v2ResponseTimeoutRunnable)
                emitDiagnostic("V2 ready: streams=${event.device.streams.descriptors.size}, " +
                    "capabilities=0x${event.device.hello.capabilities.toString(16)}", DiagnosticLevel.INFO)
                v2SupportsLive = event.device.hello.hasCapability(0)
                v2Live = WoonaV2LiveSession(event.device.streams)
                v2LiveReceiver = WoonaV2StreamDecoder()
                listener.onV2DiscoveryReady(event.device)
            }
            is WoonaV2Discovery.Event.Failure -> failV2Discovery(event.reason)
        }
    }

    @Synchronized
    private fun dispatchV2LiveEvent(event: WoonaV2LiveSession.Event) {
        if (v2Failed) return
        when (event) {
            is WoonaV2LiveSession.Event.Transmit -> {
                v2PendingFrames.addLast(event.bytes.clone())
                bluetoothGatt?.let(::startNextV2Frame)
            }
            is WoonaV2LiveSession.Event.Started -> {
                emitDiagnostic("V2 LIVE started: id=${event.sessionId} mask=0x${event.streamMask.toString(16)}", DiagnosticLevel.INFO)
                listener.onV2LiveStarted(event.sessionId, event.streamMask)
            }
            is WoonaV2LiveSession.Event.Samples -> listener.onV2LiveSamples(event)
            is WoonaV2LiveSession.Event.Stopped -> {
                emitDiagnostic("V2 LIVE stopped: id=${event.sessionId}", DiagnosticLevel.INFO)
                listener.onV2LiveStopped(event.sessionId)
            }
            is WoonaV2LiveSession.Event.Failure -> failV2Discovery(event.reason)
        }
    }

    @Synchronized
    private fun startNextV2Frame(gatt: BluetoothGatt) {
        if (v2Failed || !v2Requested || v2GattWrites.isBusy || !isCurrentGatt(gatt)) return
        if (v2PendingFrames.isEmpty()) {
            val phase = v2Discovery?.phase
            val livePhase = v2Live?.phase
            if (phase in setOf(
                    WoonaV2Discovery.Phase.WAIT_HELLO,
                    WoonaV2Discovery.Phase.WAIT_STREAMS,
                    WoonaV2Discovery.Phase.WAIT_STATUS,
                ) || livePhase in setOf(
                    WoonaV2LiveSession.Phase.WAIT_START,
                    WoonaV2LiveSession.Phase.WAIT_STOP,
                )
            ) {
                scanHandler.removeCallbacks(v2ResponseTimeoutRunnable)
                scanHandler.postDelayed(v2ResponseTimeoutRunnable, V2_RESPONSE_TIMEOUT_MS)
            }
            return
        }
        scanHandler.removeCallbacks(v2ResponseTimeoutRunnable)
        val wire = v2PendingFrames.removeFirst()
        try {
            writeV2Chunk(gatt, v2GattWrites.begin(wire, negotiatedMtu ?: 23))
        } catch (exception: IllegalArgumentException) {
            failV2Discovery("Invalid V2 frame/MTU: ${exception.message}")
        }
    }

    @Suppress("DEPRECATION")
    @SuppressLint("MissingPermission")
    @Synchronized
    private fun writeV2Chunk(gatt: BluetoothGatt, chunk: ByteArray) {
        val characteristic = v2WriteCharacteristic
        if (characteristic == null || !hasConnectPermission() || !isCurrentGatt(gatt)) {
            failV2Discovery("FFF2 is unavailable while sending V2")
            return
        }
        val result = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gatt.writeCharacteristic(characteristic, chunk, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
            } else {
                characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                characteristic.value = chunk
                if (gatt.writeCharacteristic(characteristic)) BluetoothStatusCodes.SUCCESS
                else BluetoothStatusCodes.ERROR_UNKNOWN
            }
        } catch (_: SecurityException) {
            BluetoothStatusCodes.ERROR_MISSING_BLUETOOTH_CONNECT_PERMISSION
        }
        if (result != BluetoothStatusCodes.SUCCESS) {
            failV2Discovery("FFF2 rejected write (status=$result)")
        } else {
            scanHandler.removeCallbacks(v2ChunkTimeoutRunnable)
            scanHandler.postDelayed(v2ChunkTimeoutRunnable, V2_CHUNK_WRITE_TIMEOUT_MS)
        }
    }

    @Synchronized
    private fun failV2Discovery(reason: String) {
        if (v2Failed) return
        v2Failed = true
        v2PendingFrames.clear()
        v2GattWrites.reset()
        scanHandler.removeCallbacks(v2ResponseTimeoutRunnable)
        scanHandler.removeCallbacks(v2ChunkTimeoutRunnable)
        emitDiagnostic("V2 discovery failed: $reason; connection retained; disconnect may stop active SD recording", DiagnosticLevel.WARNING)
        listener.onError(appTextResolver.getString(R.string.v2_connection_failed) + ": " + reason + "\n" +
            appTextResolver.getString(R.string.v2_sd_disconnect_warning))
    }

    @Synchronized
    private fun resetV2OnDisconnect() {
        v2ConnectionIntent = false
        scanHandler.removeCallbacks(v2ResponseTimeoutRunnable)
        scanHandler.removeCallbacks(v2ChunkTimeoutRunnable)
        v2GattWrites.reset()
        v2PendingFrames.clear()
        v2Discovery?.resetForNewConnection()
        v2Discovery = null
        v2Live?.reset()
        v2Live = null
        v2LiveReceiver?.reset()
        v2LiveReceiver = null
        v2SupportsLive = false
        v2WriteCharacteristic = null
        v2Failed = false
        v2Requested = false
    }

    private fun isCurrentGatt(gatt: BluetoothGatt): Boolean {
        return bluetoothGatt === gatt && activeGattGeneration != null &&
            gattGenerations[gatt] == activeGattGeneration
    }

    private fun isCurrentGattConnected(): Boolean {
        val gatt = bluetoothGatt ?: return false
        return captureActive && sessionState == BleSessionState.CONNECTED && isCurrentGatt(gatt) && !recoveryInProgress
    }

    private fun handleGattSetupFailure(gatt: BluetoothGatt, message: String) {
        stopTransportSummaryLoop()
        stopNotificationWatchdog()
        scanHandler.removeCallbacks(gattConnectionTimeoutRunnable)
        val wasRecovering = recoveryInProgress
        clearGattReference(gatt)
        safeCloseGatt(gatt)
        if (manualDisconnectRequested) {
            transition(BleSessionEvent.Disconnected)
        } else if (wasRecovering) {
            emitDiagnostic(message = message, level = DiagnosticLevel.WARNING)
            scheduleNextRecoveryAttempt()
        } else {
            transition(BleSessionEvent.Failure)
            listener.onError(message)
        }
    }

    private fun startNotificationWatchdog() {
        notificationMonitoringStartedElapsedRealtimeMs = SystemClock.elapsedRealtime()
        scanHandler.removeCallbacks(notificationWatchdogRunnable)
        scanHandler.postDelayed(notificationWatchdogRunnable, NOTIFICATION_WATCHDOG_INTERVAL_MS)
    }

    private fun stopNotificationWatchdog() {
        scanHandler.removeCallbacks(notificationWatchdogRunnable)
        scanHandler.removeCallbacks(recoveryConfirmationRunnable)
        notificationMonitoringStartedElapsedRealtimeMs = null
    }

    private fun startRecoveryConfirmation() {
        scanHandler.removeCallbacks(recoveryConfirmationRunnable)
        scanHandler.postDelayed(recoveryConfirmationRunnable, RECOVERY_CONFIRMATION_TIMEOUT_MS)
    }

    private fun beginTransportRecovery(silenceMillis: Long, reason: String = "Notification silence: $silenceMillis ms") {
        if (manualDisconnectRequested || recoveryInProgress || activeDeviceAddress == null) return

        recoveryInProgress = true
        awaitingRecoveryNotification = false
        recoveryStartedElapsedRealtimeMs = SystemClock.elapsedRealtime()
        recoveryAttempt = 0
        stopTransportSummaryLoop()
        stopNotificationWatchdog()
        emitDiagnostic(
            message = "$reason; starting bounded BLE transport recovery",
            level = DiagnosticLevel.WARNING,
        )

        val gatt = bluetoothGatt
        if (gatt != null && isCurrentGatt(gatt)) {
            clearGattReference(gatt)
            safeCloseGatt(gatt)
        }
        scheduleNextRecoveryAttempt()
    }

    private fun scheduleNextRecoveryAttempt() {
        if (manualDisconnectRequested || !recoveryInProgress) return

        val now = SystemClock.elapsedRealtime()
        val started = recoveryStartedElapsedRealtimeMs ?: now.also { recoveryStartedElapsedRealtimeMs = it }
        if (recoveryAttempt >= MAX_RECOVERY_ATTEMPTS || now - started >= RECOVERY_BUDGET_MS) {
            recoveryInProgress = false
            awaitingRecoveryNotification = false
            transition(BleSessionEvent.Failure)
            listener.onError("BLE transport recovery exhausted")
            return
        }

        recoveryAttempt++
        val delayMillis = when (recoveryAttempt) {
            1 -> 1_000L
            2 -> 3_000L
            else -> 10_000L
        }
        emitDiagnostic(
            message = "BLE transport recovery attempt $recoveryAttempt/$MAX_RECOVERY_ATTEMPTS scheduled in ${delayMillis} ms",
            level = DiagnosticLevel.WARNING,
        )
        scanHandler.removeCallbacks(recoveryRunnable)
        scanHandler.postDelayed(recoveryRunnable, delayMillis)
    }

    private fun emitDiagnostic(
        message: String,
        level: DiagnosticLevel,
    ) {
        when (level) {
            DiagnosticLevel.INFO -> Log.i(TAG, message)
            DiagnosticLevel.WARNING -> Log.w(TAG, message)
        }
        listener.onDiagnosticMessage(message)
    }

    private fun resetTransportDiagnostics() {
        negotiatedMtu = null
        negotiatedTxPhy = null
        negotiatedRxPhy = null
        negotiatedConnectionIntervalUnits = null
        negotiatedConnectionLatency = null
        negotiatedSupervisionTimeoutUnits = null
        notificationCount = 0L
        notificationGapSampleCount = 0L
        notificationGapTotalMillis = 0L
        notificationGapMaxMillis = 0L
        longNotificationGapCount = 0L
        lastNotificationElapsedRealtimeMs = null
        notificationMonitoringStartedElapsedRealtimeMs = null
        lastLongGapLoggedElapsedRealtimeMs = 0L
    }

    private fun startTransportSummaryLoop() {
        scanHandler.removeCallbacks(transportSummaryRunnable)
        scanHandler.postDelayed(transportSummaryRunnable, TRANSPORT_SUMMARY_INTERVAL_MS)
    }

    private fun stopTransportSummaryLoop() {
        scanHandler.removeCallbacks(transportSummaryRunnable)
    }

    private fun buildTransportSnapshotMessage(): String {
        val interval = negotiatedConnectionIntervalUnits?.let(::formatConnectionIntervalMillis)
            ?: appTextResolver.getString(R.string.value_not_available)
        val latency = negotiatedConnectionLatency?.toString() ?: appTextResolver.getString(R.string.value_not_available)
        val timeout = negotiatedSupervisionTimeoutUnits?.let { "${it * 10}" }
            ?: appTextResolver.getString(R.string.value_not_available)
        val mtu = negotiatedMtu?.toString() ?: "?"
        val phy = when {
            negotiatedTxPhy == null || negotiatedRxPhy == null -> "?"
            else -> "${describePhy(negotiatedTxPhy)} / ${describePhy(negotiatedRxPhy)}"
        }
        return appTextResolver.getString(
            R.string.ble_transport_snapshot,
            appTextResolver.getString((activeTransportProfile ?: transportProfile).titleRes),
            mtu,
            phy,
            interval,
            latency,
            timeout,
        )
    }

    private fun buildTransportSummaryMessage(): String {
        val averageGapMillis = if (notificationGapSampleCount == 0L) {
            appTextResolver.getString(R.string.value_not_available)
        } else {
            formatMillis(notificationGapTotalMillis.toDouble() / notificationGapSampleCount.toDouble())
        }
        val maxGapMillis = if (notificationGapSampleCount == 0L) {
            appTextResolver.getString(R.string.value_not_available)
        } else {
            "${notificationGapMaxMillis}"
        }
        return appTextResolver.getString(
            R.string.ble_transport_summary,
            buildTransportSnapshotMessage(),
            notificationCount,
            averageGapMillis,
            maxGapMillis,
            longNotificationGapCount,
        )
    }

    private fun longNotificationGapThresholdMillis(): Long {
        val negotiatedIntervalMs = negotiatedConnectionIntervalUnits?.let { it * 1.25 } ?: return DEFAULT_LONG_NOTIFICATION_GAP_MS
        return maxOf(DEFAULT_LONG_NOTIFICATION_GAP_MS, (negotiatedIntervalMs * 4).toLong())
    }

    private fun formatConnectionIntervalMillis(intervalUnits: Int): String {
        return formatMillis(intervalUnits * 1.25)
    }

    private fun formatMillis(value: Double): String {
        return String.format(Locale.US, "%.2f", value)
    }

    private fun describePhy(phy: Int?): String {
        return when (phy) {
            BluetoothDevice.PHY_LE_1M -> "1M"
            BluetoothDevice.PHY_LE_2M -> "2M"
            BluetoothDevice.PHY_LE_CODED -> "CODED"
            null -> "?"
            else -> phy.toString()
        }
    }

    @Synchronized
    private fun forceCloseCurrentGatt() {
        val gatt = bluetoothGatt ?: return
        clearGattReference(gatt)
        safeCloseGatt(gatt)
        transition(BleSessionEvent.Disconnected)
    }

    @SuppressLint("MissingPermission")
    private fun safeCloseGatt(gatt: BluetoothGatt) {
        try {
            gatt.close()
        } catch (exception: SecurityException) {
            Log.w(TAG, "Failed to close GATT after permission loss", exception)
        } catch (exception: Exception) {
            Log.w(TAG, "Failed to close GATT", exception)
        }
    }

    private fun hasScanPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.BLUETOOTH_SCAN,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun hasConnectPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.BLUETOOTH_CONNECT,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun describeScanFailure(errorCode: Int): String {
        return when (errorCode) {
            ScanCallback.SCAN_FAILED_ALREADY_STARTED ->
                appTextResolver.getString(R.string.ble_scan_failure_already_started)
            ScanCallback.SCAN_FAILED_APPLICATION_REGISTRATION_FAILED ->
                appTextResolver.getString(R.string.ble_scan_failure_app_registration)
            ScanCallback.SCAN_FAILED_FEATURE_UNSUPPORTED ->
                appTextResolver.getString(R.string.ble_scan_failure_feature_unsupported)
            ScanCallback.SCAN_FAILED_INTERNAL_ERROR ->
                appTextResolver.getString(R.string.ble_scan_failure_internal_error)
            ScanCallback.SCAN_FAILED_OUT_OF_HARDWARE_RESOURCES ->
                appTextResolver.getString(R.string.ble_scan_failure_out_of_hw)
            ScanCallback.SCAN_FAILED_SCANNING_TOO_FREQUENTLY ->
                appTextResolver.getString(R.string.ble_scan_failure_too_frequent)
            else -> appTextResolver.getString(R.string.ble_scan_failure_code, errorCode)
        }
    }

    private companion object {
        const val TAG = "BLE_SESSION"
        const val V2_RESPONSE_TIMEOUT_MS = 3_000L
        const val V2_CHUNK_WRITE_TIMEOUT_MS = 3_000L
        const val SCAN_TIMEOUT_MS = 10_000L
        const val TRANSPORT_SUMMARY_INTERVAL_MS = 5_000L
        const val DEFAULT_LONG_NOTIFICATION_GAP_MS = 100L
        const val LONG_GAP_LOG_COOLDOWN_MS = 5_000L
        const val NOTIFICATION_WATCHDOG_INTERVAL_MS = 1_000L
        const val NOTIFICATION_SILENCE_TIMEOUT_MS = 12_000L
        const val RECOVERY_CONFIRMATION_TIMEOUT_MS = 5_000L
        const val GATT_CONNECTION_TIMEOUT_MS = 10_000L
        const val GATT_SETUP_TIMEOUT_MS = 10_000L
        const val MAX_RECOVERY_ATTEMPTS = 3
        const val RECOVERY_BUDGET_MS = 60_000L
    }
}

private enum class DiagnosticLevel {
    INFO,
    WARNING,
}
