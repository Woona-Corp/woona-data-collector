package com.example.myapplication.ble

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import com.example.myapplication.protocol.parsePolarAcceleration
import com.example.myapplication.protocol.parsePolarEcg
import com.example.myapplication.protocol.parsePolarHeartRate
import com.example.myapplication.protocol.PolarAccelerationFrame
import com.example.myapplication.protocol.PolarEcgFrame
import com.example.myapplication.protocol.PolarHeartRateFrame
import java.util.UUID

enum class PolarConnectionState {
    IDLE,
    SCANNING,
    CONNECTING,
    READY,
    RECORDING,
    LOST,
    FAILED,
}

data class PolarStatus(
    val state: PolarConnectionState = PolarConnectionState.IDLE,
    val deviceName: String? = null,
    val batteryPercent: Int? = null,
    val heartRateBpm: Int? = null,
    val ecgFrames: Long = 0L,
    val accFrames: Long = 0L,
    val lastDataAtMillis: Long? = null,
    val message: String? = null,
)

/**
 * One GATT connection at a time. Every callback, setup transition and GATT
 * operation initiation happens under [stateLock] together with the ownership
 * and generation check, so a callback from a replaced connection can neither
 * mutate the new connection's setup nor publish its status. External callbacks
 * are always delivered after the lock is released.
 */
class PolarSessionManager(
    context: Context,
    private val onDeviceFound: (BleDevice) -> Unit,
    private val onStatus: (PolarStatus, Long) -> Unit,
    private val onHeartRate: (PolarHeartRateFrame, Long, String?) -> Unit,
    private val onEcg: (PolarEcgFrame, Long, String?) -> Unit,
    private val onAcceleration: (PolarAccelerationFrame, Long, String?) -> Unit,
    private val onError: (String, Throwable?, Long) -> Unit,
) : AutoCloseable {
    private val appContext = context.applicationContext
    private val handler = Handler(Looper.getMainLooper())
    private val bluetoothAdapter by lazy {
        appContext.getSystemService(BluetoothManager::class.java).adapter
    }
    private val foundAddresses = linkedSetOf<String>()
    private val stopScanRunnable = Runnable { stopScanning() }
    private val stateLock = Any()
    private val captureGate = PolarCaptureGate<BluetoothGatt>()

    // Guarded by stateLock. Bumped whenever the owner is replaced or cleared.
    @Volatile
    private var generation = 0L
    private var setupStep = PolarSetupStep.NONE
    private var status = PolarStatus()

    /** A status or error may only be applied while this generation is current. */
    fun isGenerationCurrent(candidate: Long): Boolean = generation == candidate

    private sealed class PolarEvent {
        class Status(val generation: Long, val status: PolarStatus) : PolarEvent()
        class Error(val generation: Long, val message: String, val throwable: Throwable?) : PolarEvent()
        class Close(val gatt: BluetoothGatt) : PolarEvent()
    }

    private val scanCallback = object : ScanCallback() {
        @SuppressLint("MissingPermission")
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            if (!hasPermission(Manifest.permission.BLUETOOTH_CONNECT)) return
            val name = result.device.name ?: return
            if (!name.startsWith("Polar", ignoreCase = true) || !foundAddresses.add(result.device.address)) return
            onDeviceFound(BleDevice(name, result.device.address))
        }

        override fun onScanFailed(errorCode: Int) {
            fail("Polar scan failed: $errorCode")
        }
    }

    private val gattCallback = object : BluetoothGattCallback() {
        @SuppressLint("MissingPermission")
        override fun onConnectionStateChange(gatt: BluetoothGatt, result: Int, newState: Int) {
            val events = synchronized(stateLock) {
                if (captureGate.owner() !== gatt) {
                    return@synchronized listOf(PolarEvent.Close(gatt))
                }
                when {
                    result != BluetoothGatt.GATT_SUCCESS -> failureLocked("Polar GATT error: $result", null, gatt)
                    newState == BluetoothProfile.STATE_CONNECTED -> {
                        if (!hasPermission(Manifest.permission.BLUETOOTH_CONNECT)) {
                            failureLocked("Bluetooth permission is required", null, gatt)
                        } else {
                            gatt.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH)
                            if (!gatt.discoverServices()) {
                                failureLocked("Polar service discovery did not start", null, gatt)
                            } else {
                                emptyList()
                            }
                        }
                    }
                    newState == BluetoothProfile.STATE_DISCONNECTED -> disconnectedLocked(gatt)
                    else -> emptyList()
                }
            }
            emit(events)
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, result: Int) {
            val events = synchronized(stateLock) {
                if (captureGate.owner() !== gatt) return@synchronized emptyList()
                if (result != BluetoothGatt.GATT_SUCCESS ||
                    characteristic(gatt, PolarUuids.HR_SERVICE, PolarUuids.HR_CHARACTERISTIC) == null ||
                    characteristic(gatt, PolarUuids.PMD_SERVICE, PolarUuids.PMD_DATA) == null ||
                    characteristic(gatt, PolarUuids.PMD_SERVICE, PolarUuids.PMD_CONTROL) == null
                ) {
                    failureLocked("Polar HR/PMD services are unavailable", null, gatt)
                } else {
                    applySetupLocked(PolarSetup.start, gatt)
                }
            }
            emit(events)
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, result: Int) {
            val characteristicUuid = runCatching { descriptor.characteristic.uuid }.getOrNull()
            val events = synchronized(stateLock) {
                if (captureGate.owner() !== gatt) return@synchronized emptyList()
                if (result != BluetoothGatt.GATT_SUCCESS) {
                    failureLocked("Polar notification setup failed: $result", null, gatt)
                } else {
                    val transition = characteristicUuid?.let { PolarSetup.onDescriptorWritten(setupStep, it) }
                    if (transition == null) emptyList() else applySetupLocked(transition, gatt)
                }
            }
            emit(events)
        }

        @Suppress("DEPRECATION")
        override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, result: Int) {
            handleBatteryRead(gatt, characteristic.uuid, characteristic.value, result)
        }

        override fun onCharacteristicRead(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
            result: Int,
        ) {
            handleBatteryRead(gatt, characteristic.uuid, value, result)
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, result: Int) {
            val value = characteristic.value
            val events = synchronized(stateLock) {
                if (captureGate.owner() !== gatt) return@synchronized emptyList()
                if (result != BluetoothGatt.GATT_SUCCESS) {
                    failureLocked("Polar PMD command failed: $result", null, gatt)
                } else {
                    val transition = PolarSetup.onControlWritten(setupStep, characteristic.uuid, value)
                    if (transition == null) emptyList() else applySetupLocked(transition, gatt)
                }
            }
            emit(events)
        }

        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            val snapshot = captureGate.snapshot(gatt) ?: return
            handleNotification(characteristic.uuid, characteristic.value, snapshot)
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            val snapshot = captureGate.snapshot(gatt) ?: return
            handleNotification(characteristic.uuid, value, snapshot)
        }
    }

    @SuppressLint("MissingPermission")
    fun startScanning() {
        if (!hasPermission(Manifest.permission.BLUETOOTH_SCAN) || !hasPermission(Manifest.permission.BLUETOOTH_CONNECT)) {
            fail("Bluetooth permission is required")
            return
        }
        stopScanning()
        foundAddresses.clear()
        val events = synchronized(stateLock) {
            status = PolarStatus(state = PolarConnectionState.SCANNING)
            listOf(PolarEvent.Status(generation, status))
        }
        emit(events)
        bluetoothAdapter.bluetoothLeScanner?.startScan(scanCallback) ?: fail("Bluetooth scanner is unavailable")
        handler.postDelayed(stopScanRunnable, SCAN_TIMEOUT_MILLIS)
    }

    @SuppressLint("MissingPermission")
    fun stopScanning() {
        handler.removeCallbacks(stopScanRunnable)
        if (hasPermission(Manifest.permission.BLUETOOTH_SCAN)) {
            runCatching { bluetoothAdapter.bluetoothLeScanner?.stopScan(scanCallback) }
        }
        val events = synchronized(stateLock) {
            if (status.state != PolarConnectionState.SCANNING) {
                emptyList()
            } else {
                status = status.copy(state = PolarConnectionState.IDLE, message = null)
                listOf(PolarEvent.Status(generation, status))
            }
        }
        emit(events)
    }

    @SuppressLint("MissingPermission")
    fun connect(address: String, name: String? = null) {
        if (!hasPermission(Manifest.permission.BLUETOOTH_CONNECT)) {
            fail("Bluetooth permission is required")
            return
        }
        stopScanning()
        val events = synchronized(stateLock) {
            val previous = captureGate.owner()
            val nextGeneration = ++generation
            captureGate.replaceOwner(null, nextGeneration)
            setupStep = PolarSetupStep.NONE
            val events = mutableListOf<PolarEvent>()
            if (previous != null) events += PolarEvent.Close(previous)
            status = PolarStatus(state = PolarConnectionState.CONNECTING, deviceName = name ?: "Polar H10")
            events += PolarEvent.Status(nextGeneration, status)
            runCatching {
                bluetoothAdapter.getRemoteDevice(address)
                    .connectGatt(appContext, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
            }.onSuccess { connected ->
                // Installed under the same lock that owns every callback check,
                // so a connecting callback cannot observe a half-published owner.
                captureGate.replaceOwner(connected, nextGeneration)
            }.onFailure { error ->
                events += failureLocked("Unable to connect Polar", error, null)
            }
            events
        }
        emit(events)
    }

    fun setRecordingActive(active: Boolean, recordingId: String?): Boolean {
        if (recordingId == null) return false
        var events: List<PolarEvent> = emptyList()
        val result = synchronized(stateLock) {
            if (active) {
                if (status.state != PolarConnectionState.READY || !captureGate.beginRecording(recordingId)) {
                    false
                } else {
                    status = status.copy(state = PolarConnectionState.RECORDING, message = null)
                    events = listOf(PolarEvent.Status(generation, status))
                    true
                }
            } else {
                if (!captureGate.endRecording(recordingId)) {
                    false
                } else {
                    if (status.state == PolarConnectionState.RECORDING) {
                        status = status.copy(state = PolarConnectionState.READY, message = null)
                        events = listOf(PolarEvent.Status(generation, status))
                    }
                    true
                }
            }
        }
        emit(events)
        return result
    }

    @SuppressLint("MissingPermission")
    fun disconnect() {
        stopScanning()
        val events = synchronized(stateLock) {
            val current = captureGate.owner()
            val nextGeneration = ++generation
            captureGate.replaceOwner(null, nextGeneration)
            setupStep = PolarSetupStep.NONE
            val events = mutableListOf<PolarEvent>()
            if (current != null) events += PolarEvent.Close(current)
            status = PolarStatus()
            events += PolarEvent.Status(nextGeneration, status)
            events
        }
        emit(events)
    }

    override fun close() = disconnect()

    @SuppressLint("MissingPermission")
    private fun emit(events: List<PolarEvent>) {
        for (event in events) {
            when (event) {
                is PolarEvent.Status -> onStatus(event.status, event.generation)
                is PolarEvent.Error -> onError(event.message, event.throwable, event.generation)
                is PolarEvent.Close -> {
                    runCatching { event.gatt.disconnect() }
                    runCatching { event.gatt.close() }
                }
            }
        }
    }

    /** Must be called under [stateLock]. */
    private fun applySetupLocked(transition: PolarSetup.Transition, gatt: BluetoothGatt): List<PolarEvent> {
        setupStep = transition.step
        if (transition.ready) {
            status = status.copy(state = PolarConnectionState.READY, message = null)
            return listOf(PolarEvent.Status(generation, status))
        }
        val operation = transition.operation ?: return emptyList()
        if (operation is PolarSetupOperation.WriteControl && operation.delayMillis > 0L) {
            val expectedGeneration = generation
            val expectedStep = transition.step
            handler.postDelayed(
                {
                    val events = synchronized(stateLock) {
                        if (captureGate.owner() !== gatt || generation != expectedGeneration || setupStep != expectedStep) {
                            emptyList()
                        } else {
                            performLocked(operation, gatt)
                        }
                    }
                    emit(events)
                },
                operation.delayMillis,
            )
            return emptyList()
        }
        return performLocked(operation, gatt)
    }

    /** Must be called under [stateLock]; the GATT call itself must not emit. */
    @SuppressLint("MissingPermission")
    private fun performLocked(operation: PolarSetupOperation, gatt: BluetoothGatt): List<PolarEvent> = when (operation) {
        is PolarSetupOperation.EnableNotifications -> enableNotificationsLocked(gatt, operation.service, operation.characteristic)
        is PolarSetupOperation.ReadBattery -> {
            val battery = characteristic(gatt, operation.service, operation.characteristic)
            if (battery == null || !gatt.readCharacteristic(battery)) {
                val transition = PolarSetup.onBatteryRead(setupStep, operation.characteristic)
                if (transition == null) emptyList() else applySetupLocked(transition, gatt)
            } else {
                emptyList()
            }
        }
        is PolarSetupOperation.WriteControl -> writeControlLocked(gatt, operation.value)
    }

    @SuppressLint("MissingPermission")
    private fun enableNotificationsLocked(gatt: BluetoothGatt, serviceUuid: UUID, characteristicUuid: UUID): List<PolarEvent> {
        val characteristic = characteristic(gatt, serviceUuid, characteristicUuid)
            ?: return failureLocked("Polar characteristic is unavailable", null, gatt)
        val descriptor = characteristic.getDescriptor(PolarUuids.CLIENT_CONFIG)
            ?: return failureLocked("Polar notification descriptor is unavailable", null, gatt)
        if (!gatt.setCharacteristicNotification(characteristic, true)) {
            return failureLocked("Polar notification callback could not be enabled", null, gatt)
        }
        @Suppress("DEPRECATION")
        descriptor.value = if (characteristic.properties and BluetoothGattCharacteristic.PROPERTY_INDICATE != 0) {
            BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
        } else {
            BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        }
        @Suppress("DEPRECATION")
        return if (!gatt.writeDescriptor(descriptor)) {
            failureLocked("Polar notification setup did not start", null, gatt)
        } else {
            emptyList()
        }
    }

    private fun handleBatteryRead(gatt: BluetoothGatt, uuid: UUID, value: ByteArray, result: Int) {
        val events = synchronized(stateLock) {
            if (captureGate.owner() !== gatt) return@synchronized emptyList()
            val transition = PolarSetup.onBatteryRead(setupStep, uuid) ?: return@synchronized emptyList()
            val events = mutableListOf<PolarEvent>()
            if (result == BluetoothGatt.GATT_SUCCESS && value.isNotEmpty()) {
                status = status.copy(batteryPercent = value[0].toInt() and 0xFF)
                events += PolarEvent.Status(generation, status)
            }
            events += applySetupLocked(transition, gatt)
            events
        }
        emit(events)
    }

    @SuppressLint("MissingPermission")
    @Suppress("DEPRECATION")
    private fun writeControlLocked(gatt: BluetoothGatt, value: ByteArray): List<PolarEvent> {
        val control = characteristic(gatt, PolarUuids.PMD_SERVICE, PolarUuids.PMD_CONTROL)
            ?: return failureLocked("Polar PMD control is unavailable", null, gatt)
        control.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        control.value = value
        return if (!gatt.writeCharacteristic(control)) {
            failureLocked("Polar PMD command did not start", null, gatt)
        } else {
            emptyList()
        }
    }

    /** Must be called under [stateLock]. */
    private fun disconnectedLocked(gatt: BluetoothGatt): List<PolarEvent> {
        val nextGeneration = ++generation
        captureGate.replaceOwner(null, nextGeneration)
        setupStep = PolarSetupStep.NONE
        status = status.copy(state = PolarConnectionState.LOST, message = "Polar disconnected")
        return listOf(PolarEvent.Close(gatt), PolarEvent.Status(nextGeneration, status))
    }

    /** Must be called under [stateLock]. */
    private fun failureLocked(
        message: String,
        throwable: Throwable?,
        closeGatt: BluetoothGatt?,
    ): List<PolarEvent> {
        val events = mutableListOf<PolarEvent>()
        if (closeGatt != null) {
            // A stale failure for a replaced GATT must change nothing at all.
            if (captureGate.owner() !== closeGatt) return emptyList()
            captureGate.replaceOwner(null, ++generation)
            setupStep = PolarSetupStep.NONE
            events += PolarEvent.Close(closeGatt)
        }
        status = status.copy(state = PolarConnectionState.FAILED, message = message)
        events += PolarEvent.Status(generation, status)
        events += PolarEvent.Error(generation, message, throwable)
        return events
    }

    private fun fail(message: String, throwable: Throwable? = null) {
        val events = synchronized(stateLock) { failureLocked(message, throwable, null) }
        emit(events)
    }

    private fun handleNotification(
        uuid: UUID,
        value: ByteArray,
        snapshot: PolarCaptureSnapshot<BluetoothGatt>,
    ) {
        when (uuid) {
            PolarUuids.HR_CHARACTERISTIC -> recordHeartRate(value, snapshot)
            PolarUuids.PMD_DATA -> when (value.firstOrNull()?.toInt()) {
                0 -> recordEcg(value, snapshot)
                2 -> recordAcc(value, snapshot)
            }
        }
    }

    private fun recordHeartRate(value: ByteArray, snapshot: PolarCaptureSnapshot<BluetoothGatt>) {
        val frame = parsePolarHeartRate(value) ?: return
        val now = System.currentTimeMillis()
        // The frame keeps the recording it was delivered for, even if that
        // recording was finalized meanwhile.
        onHeartRate(frame, now, snapshot.recordingId)
        publishSampleStatus(snapshot.generation) {
            it.copy(heartRateBpm = frame.beatsPerMinute, lastDataAtMillis = now)
        }
    }

    private fun recordEcg(value: ByteArray, snapshot: PolarCaptureSnapshot<BluetoothGatt>) {
        val frame = parsePolarEcg(value) ?: return
        val now = System.currentTimeMillis()
        onEcg(frame, now, snapshot.recordingId)
        publishSampleStatus(snapshot.generation) {
            it.copy(ecgFrames = it.ecgFrames + 1, lastDataAtMillis = now)
        }
    }

    private fun recordAcc(value: ByteArray, snapshot: PolarCaptureSnapshot<BluetoothGatt>) {
        val frame = parsePolarAcceleration(value) ?: return
        val now = System.currentTimeMillis()
        onAcceleration(frame, now, snapshot.recordingId)
        publishSampleStatus(snapshot.generation) {
            it.copy(accFrames = it.accFrames + 1, lastDataAtMillis = now)
        }
    }

    private fun publishSampleStatus(sampleGeneration: Long, update: (PolarStatus) -> PolarStatus) {
        val events = synchronized(stateLock) {
            // A sample from a connection that has been replaced or cleared must
            // not modify the current connection's counters or last-data time.
            if (generation != sampleGeneration) return@synchronized emptyList()
            status = update(status)
            listOf(PolarEvent.Status(sampleGeneration, status))
        }
        emit(events)
    }

    private fun characteristic(gatt: BluetoothGatt, service: UUID, characteristic: UUID): BluetoothGattCharacteristic? =
        gatt.getService(service)?.getCharacteristic(characteristic)

    private fun hasPermission(permission: String): Boolean =
        ContextCompat.checkSelfPermission(appContext, permission) == PackageManager.PERMISSION_GRANTED

    companion object {
        private const val SCAN_TIMEOUT_MILLIS = 10_000L
    }
}
