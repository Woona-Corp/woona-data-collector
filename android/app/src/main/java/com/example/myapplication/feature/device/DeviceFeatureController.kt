package com.example.myapplication.feature.device

import android.content.Context
import android.content.Intent
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import com.example.myapplication.R
import com.example.myapplication.ble.BleSessionState
import com.example.myapplication.ble.BleTransportProfile
import com.example.myapplication.ble.BleSessionController
import com.example.myapplication.ble.PolarConnectionState
import com.example.myapplication.ble.PolarSessionManager
import com.example.myapplication.ble.PolarStatus
import com.example.myapplication.data.ArtifactType
import com.example.myapplication.data.CaptureSyncMetadata
import com.example.myapplication.data.Recording
import com.example.myapplication.data.RecordingSource
import com.example.myapplication.data.RecordingStatus
import com.example.myapplication.data.SyncClockAnchor
import com.example.myapplication.data.VideoSyncMetadata
import com.example.myapplication.data.WoonaDatabase
import com.example.myapplication.data.absoluteInstantForMonotonic
import com.example.myapplication.data.monotonicOffsetNs
import com.example.myapplication.data.toJson
import com.example.myapplication.localization.EnglishTextResolver
import com.example.myapplication.localization.TextResolver
import com.example.myapplication.protocol.ConnectionQuality
import com.example.myapplication.protocol.ConnectionQualitySnapshot
import com.example.myapplication.protocol.ConnectionQualityTracker
import com.example.myapplication.protocol.PolarAccelerationFrame
import com.example.myapplication.protocol.PolarEcgFrame
import com.example.myapplication.protocol.PolarHeartRateFrame
import com.example.myapplication.storage.BleSessionCsvExporter
import com.example.myapplication.storage.FileShareIntentFactory
import com.example.myapplication.storage.SessionArchiveExporter
import com.example.myapplication.storage.SessionArchiveMetadata
import com.example.myapplication.storage.PolarCsvFileStore
import com.example.myapplication.video.AndroidVideoRecorder
import com.example.myapplication.video.AndroidVideoStartInfo
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.time.Instant

class DeviceFeatureController(
    private val bleSessionController: BleSessionController,
    private val packetCaptureController: PacketCaptureController,
    private val fileShareIntentFactory: FileShareIntentFactory,
    private val appTextResolver: TextResolver = EnglishTextResolver,
    private val packetReplayController: PacketReplayController? = null,
    private val uiStateHolder: DeviceUiStateHolder = DeviceUiStateHolder(),
    private val sessionCsvExporter: BleSessionCsvExporter = BleSessionCsvExporter(),
    private val sessionArchiveExporter: SessionArchiveExporter = SessionArchiveExporter(),
    private val wallClockMillisProvider: () -> Long = System::currentTimeMillis,
    private val runOnUiThread: (() -> Unit) -> Unit = { action -> action() },
    private val woonaDatabase: WoonaDatabase? = null,
    private val snapshotDirectory: File? = null,
    private val onRecordingChanged: () -> Unit = {},
    private val videoRecorder: AndroidVideoRecorder? = null,
    private val polarSessionManager: PolarSessionManager? = null,
    private val polarFileStore: PolarCsvFileStore? = null,
    private val monotonicNanosProvider: () -> Long = SystemClock::elapsedRealtimeNanos,
    private val schedule: (Runnable, Long) -> Unit = { _, _ -> },
    private val cancel: (Runnable) -> Unit = {},
    private val onConnectionAlarm: (ConnectionQuality) -> Unit = {},
    private val onCaptureLifecycleChanged: (Boolean) -> Unit = {},
) : AutoCloseable {
    @Volatile
    private var recordingChangedListener: () -> Unit = onRecordingChanged
    private val exportLock = Any()
    private var pendingTransportDiagnostics = mutableListOf<String>()
    private var awaitingCaptureReady = false
    private var exportSnapshot: SessionExportSnapshot? = null
    private var exportSessionStartMillis: Long? = null
    private var exportEpoch = 0L
    private var currentRecordingId: String? = null
    private var currentRecording: Recording? = null
    private var currentRecordingDirectory: File? = null
    private var captureSyncMetadata: CaptureSyncMetadata? = null
    private var synchronizedCaptureStarted = false
    private var firstSensorFragmentRecorded = false
    private val connectionQualityTracker = ConnectionQualityTracker()
    private var linkMonitorRunning = false
    private var weakSinceMillis: Long? = null
    private var lastAlarmQuality: ConnectionQuality? = null
    private var manualDisconnectPending = false
    private var pendingFinalizationStatus: RecordingStatus? = null
    private val finalizationRetryRunnable = Runnable {
        val status = pendingFinalizationStatus
        pendingFinalizationStatus = null
        if (status != null) finalizeRecording(status)
    }
    private val linkMonitorRunnable: Runnable = object : Runnable {
        override fun run() {
            if (linkMonitorRunning) {
                updateConnectionQuality(connectionQualityTracker.snapshot(monotonicMillis()))
                schedule(this, LINK_MONITOR_INTERVAL_MILLIS)
            }
        }
    }
    @Volatile
    private var recordingFinalized = true
    @Volatile
    private var recordingFinalizing = false

    val uiState: DeviceUiState
        get() = uiStateHolder.uiState

    fun isVideoRequested(): Boolean = currentRecording?.videoRequested == true

    fun isCaptureActive(): Boolean = !recordingFinalized || recordingFinalizing

    fun setOnRecordingChanged(listener: () -> Unit) {
        recordingChangedListener = listener
    }

    fun onStartScanRequested(
        hasPermissions: () -> Boolean,
        requestPermissions: () -> Unit,
    ) {
        uiStateHolder.prepareForScan()
        if (hasPermissions()) {
            bleSessionController.startScanning()
        } else {
            requestPermissions()
        }
    }

    fun onPermissionsResult(allGranted: Boolean) {
        if (allGranted) {
            bleSessionController.startScanning()
        } else {
            uiStateHolder.showError(appTextResolver.getString(R.string.permissions_required))
        }
    }

    fun onConnectRequested(address: String) {
        manualDisconnectPending = false
        packetReplayController?.stop()
        pendingTransportDiagnostics.clear()
        awaitingCaptureReady = true
        val staleSnapshot = synchronized(exportLock) {
            invalidateExportSnapshotLocked()
        }
        deleteSnapshotFiles(staleSnapshot)
        packetCaptureController.stopCapture()
        bleSessionController.stopScanning()
        bleSessionController.connect(address)
    }

    /** V2 is opt-in because HELLO permanently ends Legacy streaming for this BLE connection. */
    fun onV2DiscoveryRequested() {
        if (synchronizedCaptureStarted) {
            uiStateHolder.showError("Stop the current Legacy recording before switching to V2")
            return
        }
        if (bleSessionController.beginV2Discovery()) {
            uiStateHolder.onV2DiscoveryRequested()
        } else {
            uiStateHolder.showError("V2 discovery is unavailable. Check BLE connection and reconnect if necessary.")
        }
    }

    fun onV2StreamToggled(streamId: Int) = uiStateHolder.toggleV2Stream(streamId)

    fun onV2RecordingTargetSelected(target: V2RecordingTarget) =
        uiStateHolder.selectV2RecordingTarget(target)

    /** Starts a validated V2 LIVE preview via the normal Start session UI. */
    fun onV2LiveStartRequested() {
        if (!uiState.v2Ready || uiState.v2LiveRunning) return
        if (uiState.v2RecordingTarget == V2RecordingTarget.STORAGE) {
            uiStateHolder.showError(
                "V2 storage acquisition and upload are not connected yet; select LIVE for this build"
            )
            return
        }
        val selectedMask = uiState.v2SelectedStreamMask and uiState.v2StreamMask
        if (selectedMask == 0L || !bleSessionController.startV2Live(selectedMask)) {
            uiStateHolder.showError("Cannot start V2 LIVE: check selected streams and BLE state")
        }
    }

    fun onV2LiveStopRequested() {
        if (!bleSessionController.stopV2Live()) {
            uiStateHolder.showError("Cannot stop V2 preview: session is not running")
        }
    }

    fun beginRecordingSession(recording: Recording) {
        cancel(finalizationRetryRunnable)
        pendingFinalizationStatus = null
        finalizeRecording(RecordingStatus.INTERRUPTED)
        val staleSnapshot = synchronized(this) {
            currentRecordingId = recording.id
            currentRecording = recording
            recordingFinalized = false
            synchronizedCaptureStarted = false
            firstSensorFragmentRecorded = false
            packetCaptureController.stopCapture()
            currentRecordingDirectory =
                requireNotNull(woonaDatabase).recordingDirectory(recording.relativeDirectory)
            packetCaptureController.useSessionDirectory(requireNotNull(currentRecordingDirectory))
            polarFileStore?.useSessionDirectory(requireNotNull(currentRecordingDirectory))
            captureSyncMetadata = CaptureSyncMetadata(
                recordingId = recording.id,
                profileId = recording.profileId,
                source = recording.source.value,
                timezone = recording.timezone,
                selectedSessionStartUtc = recording.startedAtUtc,
            )
            persistSyncMetadata()
            if (recording.source == RecordingSource.LIVE) {
                uiStateHolder.prepareVideo()
                onCaptureLifecycleChanged(true)
            }
            synchronized(exportLock) {
                val snapshot = invalidateExportSnapshotLocked()
                exportSessionStartMillis = Instant.parse(recording.startedAtUtc).toEpochMilli()
                snapshot
            }
        }
        deleteSnapshotFiles(staleSnapshot)
        notifyRecordingChanged()
    }

    fun onDisconnectRequested() {
        manualDisconnectPending = true
        stopLinkMonitor()
        packetReplayController?.stop()
        pendingTransportDiagnostics.clear()
        awaitingCaptureReady = false
        // Preview-only V2 is not a persisted session; do not mark it COMPLETED.
        finalizeRecording(if (uiState.v2DiscoveryRequested) {
            RecordingStatus.INTERRUPTED
        } else {
            RecordingStatus.COMPLETED
        })
        packetCaptureController.stopCapture()
        val staleSnapshot = synchronized(exportLock) {
            invalidateExportSnapshotLocked()
        }
        deleteSnapshotFiles(staleSnapshot)
        uiStateHolder.stopCaptureSession()
        bleSessionController.disconnect()
        polarSessionManager?.disconnect()
    }

    fun onPolarScanRequested() {
        uiStateHolder.prepareForPolarScan()
        polarSessionManager?.startScanning()
    }

    fun onPolarConnectRequested(address: String, name: String) {
        polarSessionManager?.connect(address, name)
    }

    fun onPolarDisconnectRequested() {
        polarSessionManager?.disconnect()
    }

    fun onPolarStatusChanged(status: PolarStatus) {
        uiStateHolder.updatePolarStatus(status)
        if (status.state == PolarConnectionState.READY && synchronizedCaptureStarted && !recordingFinalized) {
            startPolarRecording()
        }
        if (status.state in setOf(PolarConnectionState.LOST, PolarConnectionState.FAILED) &&
            synchronizedCaptureStarted && !recordingFinalized
        ) {
            onConnectionAlarm(ConnectionQuality.LOST)
        }
    }

    fun onPolarHeartRate(frame: PolarHeartRateFrame, nowMillis: Long) = polarFileStore?.append(frame, nowMillis)

    fun onPolarEcg(frame: PolarEcgFrame, nowMillis: Long) = polarFileStore?.append(frame, nowMillis)

    fun onPolarAcceleration(frame: PolarAccelerationFrame, nowMillis: Long) = polarFileStore?.append(frame, nowMillis)

    fun finishCaptureForExport(): Boolean {
        stopVideo()
        packetReplayController?.stop()
        val finished = packetCaptureController.finishCapture(CAPTURE_FINISH_TIMEOUT_MILLIS)
        if (!finished) {
            Log.w("BLE_SHARE", "Timed out waiting for capture queue before export")
        }
        return finished
    }

    fun onSensorSelected(sensorType: Int) {
        uiStateHolder.onSensorTypeSelected(sensorType)
        syncProcessorSelection()
    }

    fun onTransportProfileSelected(profile: BleTransportProfile) {
        uiStateHolder.onTransportProfileSelected(profile)
        bleSessionController.updateTransportProfile(profile)

        if (uiState.showCaptureUi || awaitingCaptureReady) {
            packetCaptureController.recordDiagnosticEvent(
                type = PacketDiagnosticType.INFO,
                message = appTextResolver.getString(
                    R.string.transport_profile_selected_next_connection,
                    appTextResolver.getString(profile.titleRes),
                ),
            )
        }
    }

    fun onChannelSelected(channel: Int) {
        uiStateHolder.onChannelSelected(channel)
        syncProcessorSelection()
    }

    fun onTabSelected(tab: DeviceCaptureTab) {
        uiStateHolder.onTabSelected(tab)
    }

    fun onChartWindowSelected(windowPreset: ChartWindowPreset) {
        uiStateHolder.onChartWindowSelected(windowPreset)
    }

    fun onFollowLiveChanged(enabled: Boolean) {
        uiStateHolder.onFollowLiveChanged(enabled)
    }

    fun onChartPanLeftRequested() {
        uiStateHolder.panChartLeft()
    }

    fun onChartPanRightRequested() {
        uiStateHolder.panChartRight()
    }

    fun onChartJumpToLiveRequested() {
        uiStateHolder.jumpToLive()
    }

    fun onChartZoomInRequested() {
        uiStateHolder.zoomInChart()
    }

    fun onChartZoomOutRequested() {
        uiStateHolder.zoomOutChart()
    }

    fun onChartZoomResetRequested() {
        uiStateHolder.resetChartZoom()
    }

    fun onChartPanned(deltaFraction: Float) {
        uiStateHolder.panChartByFraction(deltaFraction)
    }

    fun onChartZoomChanged(
        scaleFactor: Float,
        anchorFractionY: Float = 0.5f,
    ) {
        uiStateHolder.zoomChart(scaleFactor, anchorFractionY)
    }

    fun onPause() {
        // Screen/background lifecycle does not own an active capture. The
        // foreground capture service and the explicit Stop action own it.
    }

    fun onBleStateChanged(state: BleSessionState) {
        val unexpectedDisconnect =
            state in setOf(BleSessionState.FAILED, BleSessionState.DISCONNECTED) &&
                synchronizedCaptureStarted &&
                !manualDisconnectPending
        val disconnectedQuality = if (unexpectedDisconnect) {
            connectionQualityTracker.disconnect(monotonicMillis())
        } else {
            null
        }
        when (state) {
            BleSessionState.FAILED -> finalizeRecording(RecordingStatus.FAILED)
            BleSessionState.DISCONNECTED -> finalizeRecording(RecordingStatus.INTERRUPTED)
            else -> Unit
        }
        uiStateHolder.onSessionStateChanged(state)
        if (disconnectedQuality != null) {
            stopLinkMonitor()
            updateConnectionQuality(disconnectedQuality)
        }
    }

    fun onPacketUpdate(update: PacketProcessingUpdate) {
        uiStateHolder.applyPacketUpdate(update)
        if (!synchronizedCaptureStarted || recordingFinalized) return
        updateConnectionQuality(
            connectionQualityTracker.record(
                nowMillis = monotonicMillis(),
                packetsReceived = update.packetsReceived,
                packetsLost = update.packetsLost,
                packetsRejected = update.packetsRejected,
            ),
        )
    }

    fun onLinkMonitorTick() {
        if (linkMonitorRunning) {
            updateConnectionQuality(connectionQualityTracker.snapshot(monotonicMillis()))
        }
    }

    fun createPacketShareIntent(context: Context): Intent? = createShareIntent(
        context = context,
        file = packetCaptureController.currentPacketFile(),
    )

    fun createRawShareIntent(context: Context): Intent? = createShareIntent(
        context = context,
        file = packetCaptureController.currentRawFile(),
    )

    fun createLogShareIntent(context: Context): Intent? = createShareIntent(
        context = context,
        file = packetCaptureController.currentLogFile(),
    )

    fun createCsvShareIntent(context: Context): Intent? {
        return try {
            showExportPhaseOnMainThread(ExportPhase.PREPARING_SNAPSHOTS)
            val snapshot = ensureExportSnapshot() ?: return null
            val csvSnapshot = ensureCsvSnapshot(snapshot) ?: return null
            showExportPhaseOnMainThread(ExportPhase.OPENING_SHARE_SHEET)
            fileShareIntentFactory.createChooserIntent(context, csvSnapshot)
        } catch (exception: Exception) {
            showErrorOnMainThread(appTextResolver.getString(R.string.share_file_failed), exception)
            Log.e("BLE_SHARE", "Failed to share file", exception)
            null
        }
    }

    fun createAllFilesShareIntent(context: Context): Intent? {
        return try {
            val targetDirectory = snapshotDirectory
                ?: packetCaptureController.currentPacketFile()?.parentFile
                ?: return null
            val archive = createSessionArchive(targetDirectory) ?: return null
            showExportPhaseOnMainThread(ExportPhase.OPENING_SHARE_SHEET)
            fileShareIntentFactory.createChooserIntent(context, archive)
        } catch (exception: Exception) {
            showErrorOnMainThread(appTextResolver.getString(R.string.share_file_failed), exception)
            Log.e("BLE_SHARE", "Failed to share file", exception)
            null
        }
    }

    fun createRecordingShareIntent(context: Context, recordingId: String): Intent? {
        val files = woonaDatabase?.artifactFiles(recordingId).orEmpty()
        val summary = woonaDatabase?.recordingSummary(recordingId) ?: return null
        if (files.isEmpty()) return null
        return runCatching {
            val syncJson = files.firstOrNull { it.name == "sync.json" }?.readText(Charsets.UTF_8)
            val archive = sessionArchiveExporter.export(
                files = files,
                targetDirectory = snapshotDirectory ?: File(context.cacheDir, "woona_recording_exports"),
                sessionStartMillis = Instant.parse(summary.recording.startedAtUtc).toEpochMilli(),
                createdAtMillis = wallClockMillisProvider(),
                metadata = archiveMetadata(summary, syncJson),
            )
            fileShareIntentFactory.createChooserIntent(context, archive)
        }.getOrElse { exception ->
            showErrorOnMainThread(appTextResolver.getString(R.string.share_file_failed), exception)
            Log.e("BLE_SHARE", "Failed to share recording archive", exception)
            null
        }
    }

    fun createSessionArchive(targetDirectory: File): File? {
        if (!canCreateSessionArchiveNow()) {
            showErrorOnMainThread(appTextResolver.getString(R.string.export_finish_capture_first))
            return null
        }
        return try {
            // Export never owns capture/video shutdown. Finalization must have
            // completed before this point, including when invoked without UI.
            showExportPhaseOnMainThread(ExportPhase.PREPARING_SNAPSHOTS)
            val snapshot = ensureExportSnapshot() ?: return null
            val files = buildAvailableExportFiles(snapshot)
            if (files.isEmpty()) return null

            showExportPhaseOnMainThread(ExportPhase.PACKAGING_ARCHIVE)
            sessionArchiveExporter.export(
                files = files,
                targetDirectory = targetDirectory,
                sessionStartMillis = snapshot.sessionStartMillis,
                createdAtMillis = wallClockMillisProvider(),
                metadata = currentRecordingId
                    ?.let { recordingId -> woonaDatabase?.recordingSummary(recordingId) }
                    ?.let { summary ->
                        archiveMetadata(
                            summary,
                            currentSessionFile("sync.json")?.takeIf(File::exists)?.readText(Charsets.UTF_8),
                        )
                    },
            )
        } catch (exception: Exception) {
            showErrorOnMainThread(appTextResolver.getString(R.string.export_prepare_failed), exception)
            Log.e("BLE_SHARE", "Failed to prepare session archive", exception)
            null
        }
    }

    fun canSharePacketFile(): Boolean = packetCaptureController.currentPacketFile()?.exists() == true

    fun canShareRawFile(): Boolean = packetCaptureController.currentRawFile()?.exists() == true

    fun canShareLogFile(): Boolean = packetCaptureController.currentLogFile()?.exists() == true

    fun canShareCsvFile(): Boolean = packetCaptureController.currentPacketFile()?.exists() == true

    private fun canCreateSessionArchiveNow(): Boolean = !isCaptureActive() && videoRecorder?.isActive() != true &&
        uiState.videoState !in setOf(VideoCaptureState.STARTING, VideoCaptureState.RECORDING, VideoCaptureState.STOPPING)

    fun canShareAllFiles(): Boolean = canCreateSessionArchiveNow() && (
        canSharePacketFile() || canShareCsvFile() || canShareRawFile() || canShareLogFile() ||
            currentSessionFile("video.mp4")?.exists() == true ||
            currentSessionFile("sync.json")?.exists() == true ||
            PolarCsvFileStore.FILE_NAMES.any { currentSessionFile(it)?.exists() == true })

    fun clearExportProgress() {
        runOnUiThread {
            uiStateHolder.clearExportProgress()
        }
    }

    override fun close() {
        manualDisconnectPending = true
        stopLinkMonitor()
        packetReplayController?.close()
        finalizeRecording(RecordingStatus.INTERRUPTED)
        if (isCaptureActive()) return
        val staleSnapshot = synchronized(exportLock) {
            val snapshot = invalidateExportSnapshotLocked()
            exportSessionStartMillis = null
            snapshot
        }
        deleteSnapshotFiles(staleSnapshot)
        bleSessionController.close()
        polarSessionManager?.close()
        polarFileStore?.close()
        packetCaptureController.close()
        videoRecorder?.close()
    }

    fun onCaptureReady() {
        if (woonaDatabase != null && recordingFinalized) {
            awaitingCaptureReady = false
            return
        }
        if (!recordingFinalized) {
            if (synchronizedCaptureStarted) {
                packetCaptureController.recordDiagnosticEvent(
                    type = PacketDiagnosticType.INFO,
                    message = "BLE notifications re-enabled after transport recovery",
                )
            } else if (currentRecording?.source == RecordingSource.LIVE) {
                uiStateHolder.videoReady()
            } else {
                resetCaptureSession()
                currentRecordingId?.let { woonaDatabase?.markRecording(it) }
            }
        } else {
            resetCaptureSession()
        }
        notifyRecordingChanged()
        flushPendingTransportDiagnostics()
        awaitingCaptureReady = false
    }

    @Synchronized
    fun startSynchronizedSession() {
        if (uiState.v2DiscoveryRequested) {
            // A queued permission/capture callback can still arrive after V2 opt-in.
            // Do not start Legacy on a V2 connection and do not report a false error.
            return
        }
        val recording = currentRecording ?: return
        if (
            recordingFinalized ||
            recordingFinalizing ||
            synchronizedCaptureStarted ||
            uiState.videoState !in setOf(VideoCaptureState.READY, VideoCaptureState.FAILED)
        ) return
        synchronizedCaptureStarted = true
        bleSessionController.setCaptureActive(true)
        startLinkMonitor()
        captureSyncMetadata = captureSyncMetadata?.copy(
            sensor = captureClockAnchor("capture_start"),
        )
        resetCaptureSession()
        currentRecordingId?.let { woonaDatabase?.markRecording(it) }
        persistSyncMetadata()
        if (recording.videoRequested) {
            startVideo()
        } else {
            uiStateHolder.videoStarted(0.0)
        }
        startPolarRecording()
        notifyRecordingChanged()
    }

    @Synchronized
    fun onSensorFragmentReceived(
        receivedAtMillis: Long,
        receivedAtMonotonicNs: Long,
        deviceTimerMillis: Long,
    ) {
        if (!synchronizedCaptureStarted || recordingFinalized) return
        captureSyncMetadata = captureSyncMetadata?.copy(
            lastSensorPacketMonotonicNs = receivedAtMonotonicNs,
        )
        if (firstSensorFragmentRecorded) return
        firstSensorFragmentRecorded = true
        val current = captureSyncMetadata ?: return
        val sensor = SyncClockAnchor(
            event = "first_accepted_sensor_packet",
            absoluteUtc = Instant.ofEpochMilli(receivedAtMillis).toString(),
            wallClockEpochMillis = receivedAtMillis,
            monotonicTimeNs = receivedAtMonotonicNs,
            monotonicClock = "android.elapsedRealtimeNanos",
            samplingUncertaintyNs = 0L,
        )
        val video = current.video?.let { existing ->
            existing.firstFrameMonotonicNs?.let { firstFrame ->
                existing.copy(
                    firstFrameAtUtc = absoluteInstantForMonotonic(sensor, firstFrame).toString(),
                    firstFrameEpochMillis = receivedAtMillis +
                        monotonicOffsetNs(sensor, firstFrame) / 1_000_000.0,
                    offsetFromSensorNs = monotonicOffsetNs(sensor, firstFrame),
                )
            } ?: existing
        }
        captureSyncMetadata = current.copy(
            sensor = sensor,
            firstSensorDeviceTimerMillis = deviceTimerMillis,
            lastSensorPacketMonotonicNs = receivedAtMonotonicNs,
            video = video,
        )
        persistSyncMetadata()
    }

    fun setVideoPreviewSurface(surface: Surface?) {
        videoRecorder?.setPreviewSurface(surface)
    }

    fun onTransportDiagnostic(message: String) {
        if (awaitingCaptureReady) {
            pendingTransportDiagnostics += message
            return
        }

        packetCaptureController.recordDiagnosticEvent(
            type = PacketDiagnosticType.INFO,
            message = message,
        )
    }

    fun onSessionError(message: String, throwable: Throwable? = null) {
        val details = if (throwable == null) message else "$message: $throwable"
        val disconnectedQuality = if (synchronizedCaptureStarted && !manualDisconnectPending) {
            connectionQualityTracker.disconnect(monotonicMillis())
        } else {
            null
        }
        flushPendingTransportDiagnostics()
        awaitingCaptureReady = false
        uiStateHolder.showError(details)
        currentRecordingId?.let { recordingId ->
            woonaDatabase?.markCaptureError(
                recordingId = recordingId,
                code = captureErrorCode(message),
                message = details,
            )
        }
        finalizeRecording(RecordingStatus.FAILED)
        if (disconnectedQuality != null) updateConnectionQuality(disconnectedQuality)
    }

    fun startReplay(fileBytes: ByteArray) {
        startReplay { fileBytes.inputStream() }
    }

    fun startReplay(source: ReplayInputSource) {
        if (packetReplayController == null) {
            uiStateHolder.showError(appTextResolver.getString(R.string.replay_unavailable))
            return
        }

        packetReplayController.startReplay(source)
    }

    fun onReplayPreparing() {
        bleSessionController.stopScanning()
        uiStateHolder.startReplayPreparation()
    }

    fun cancelReplayPreparation() {
        packetReplayController?.stop()
    }

    fun onReplayStarted() {
        if (woonaDatabase != null && recordingFinalized) return
        bleSessionController.close()
        pendingTransportDiagnostics.clear()
        awaitingCaptureReady = false
        packetCaptureController.resetSession()
        val staleSnapshot = synchronized(exportLock) {
            val snapshot = invalidateExportSnapshotLocked()
            exportSessionStartMillis = wallClockMillisProvider()
            snapshot
        }
        deleteSnapshotFiles(staleSnapshot)
        uiStateHolder.startReplaySession()
        if (!recordingFinalized) {
            currentRecordingId?.let { woonaDatabase?.markRecording(it) }
            captureSyncMetadata = captureSyncMetadata?.copy(
                sensor = captureClockAnchor("replay_started"),
            )
            persistSyncMetadata()
        }
        notifyRecordingChanged()
    }

    fun onReplayCompleted() {
        finalizeRecording(RecordingStatus.COMPLETED)
        uiStateHolder.finishReplaySession()
    }

    fun onReplayStopped() {
        if (uiStateHolder.uiState.isReplayPreparing) {
            finalizeRecording(RecordingStatus.INTERRUPTED)
            uiStateHolder.cancelReplayPreparation()
        } else {
            finalizeRecording(RecordingStatus.COMPLETED)
            uiStateHolder.stopCaptureSession()
        }
    }

    fun onReplayError(message: String, throwable: Throwable? = null) {
        showErrorOnMainThread(message, throwable)
        finalizeRecording(RecordingStatus.FAILED)
    }

    private fun resetCaptureSession() {
        packetCaptureController.resetSession()
        val staleSnapshot = synchronized(exportLock) {
            val snapshot = invalidateExportSnapshotLocked()
            exportSessionStartMillis = wallClockMillisProvider()
            snapshot
        }
        deleteSnapshotFiles(staleSnapshot)
        uiStateHolder.resetCaptureSession()
    }

    private fun flushPendingTransportDiagnostics() {
        pendingTransportDiagnostics.forEach { message ->
            packetCaptureController.recordDiagnosticEvent(
                type = PacketDiagnosticType.INFO,
                message = message,
            )
        }
        pendingTransportDiagnostics.clear()
    }

    private fun createShareIntent(
        context: Context,
        file: File?,
    ): Intent? {
        if (file == null || !file.exists()) return null

        return try {
            showExportPhaseOnMainThread(ExportPhase.PREPARING_SNAPSHOTS)
            val snapshot = ensureExportSnapshot() ?: return null
            val snapshotFile = when (file.absolutePath) {
                snapshot.packetSourcePath -> snapshot.packetSnapshot
                snapshot.rawSourcePath -> snapshot.rawSnapshot
                snapshot.logSourcePath -> snapshot.logSnapshot
                else -> null
            } ?: return null

            showExportPhaseOnMainThread(ExportPhase.OPENING_SHARE_SHEET)
            fileShareIntentFactory.createChooserIntent(context, snapshotFile)
        } catch (exception: Exception) {
            showErrorOnMainThread(appTextResolver.getString(R.string.share_file_failed), exception)
            Log.e("BLE_SHARE", "Failed to share file", exception)
            null
        }
    }

    fun showErrorOnMainThread(message: String, throwable: Throwable? = null) {
        runOnUiThread {
            uiStateHolder.showError(if (throwable == null) message else "$message: $throwable")
        }
    }

    private fun showExportPhaseOnMainThread(phase: ExportPhase) {
        runOnUiThread {
            uiStateHolder.showExportProgress(phase)
        }
    }

    private fun ensureExportSnapshot(): SessionExportSnapshot? {
        val buildPlan = synchronized(exportLock) {
            val currentPacketFile = packetCaptureController.currentPacketFile()?.takeIf(File::exists)
            val currentTimelineFile = packetCaptureController.currentPacketTimelineFile()?.takeIf(File::exists)
            val currentRawFile = packetCaptureController.currentRawFile()?.takeIf(File::exists)
            val currentLogFile = packetCaptureController.currentLogFile()?.takeIf(File::exists)
            val sessionStartMillis = exportSessionStartMillis
            val existingSnapshot = exportSnapshot

            existingSnapshot?.takeIf {
                it.matches(currentPacketFile, currentTimelineFile, currentRawFile, currentLogFile, sessionStartMillis)
            }?.let { return it }

            if (
                currentPacketFile == null &&
                currentRawFile == null &&
                currentLogFile == null &&
                currentSessionFile("video.mp4")?.exists() != true &&
                currentSessionFile("sync.json")?.exists() != true &&
                PolarCsvFileStore.FILE_NAMES.none { currentSessionFile(it)?.exists() == true }
            ) {
                return null
            }

            val snapshotToDelete = exportSnapshot
            exportSnapshot = null
            ExportSnapshotBuildPlan(
                epoch = exportEpoch,
                sessionStartMillis = sessionStartMillis,
                packetFile = currentPacketFile,
                timelineFile = currentTimelineFile,
                rawFile = currentRawFile,
                logFile = currentLogFile,
                staleSnapshot = snapshotToDelete,
            )
        }

        deleteSnapshotFiles(buildPlan.staleSnapshot)
        packetCaptureController.flush()
        val snapshot = SessionExportSnapshot(
            packetSourcePath = buildPlan.packetFile?.absolutePath,
            timelineSourcePath = buildPlan.timelineFile?.absolutePath,
            rawSourcePath = buildPlan.rawFile?.absolutePath,
            logSourcePath = buildPlan.logFile?.absolutePath,
            sessionStartMillis = buildPlan.sessionStartMillis,
            packetSnapshot = buildPlan.packetFile?.let { createSnapshotCopy(it, "packet") },
            timelineSnapshot = buildPlan.timelineFile?.let { createSnapshotCopy(it, "timeline") },
            rawSnapshot = buildPlan.rawFile?.let { createSnapshotCopy(it, "raw") },
            logSnapshot = buildPlan.logFile?.let { createSnapshotCopy(it, "log") },
            csvSnapshot = null,
        )

        return synchronized(exportLock) {
            if (exportEpoch != buildPlan.epoch) {
                deleteSnapshotFiles(snapshot)
                null
            } else {
                exportSnapshot = snapshot
                snapshot
            }
        }
    }

    private fun buildAvailableExportFiles(snapshot: SessionExportSnapshot): List<File> {
        polarFileStore?.flush()
        val csvSnapshot = ensureCsvSnapshot(snapshot)
        return listOfNotNull(
            snapshot.packetSnapshot,
            snapshot.timelineSnapshot,
            csvSnapshot,
            snapshot.rawSnapshot,
            snapshot.logSnapshot,
            currentSessionFile("video.mp4")?.takeIf(File::exists),
            currentSessionFile("sync.json")?.takeIf(File::exists),
            *PolarCsvFileStore.FILE_NAMES.mapNotNull { currentSessionFile(it)?.takeIf(File::exists) }.toTypedArray(),
        )
    }

    private fun ensureCsvSnapshot(snapshot: SessionExportSnapshot): File? {
        val buildEpoch = synchronized(exportLock) {
            val currentSnapshot = exportSnapshot
            if (currentSnapshot == null || !currentSnapshot.hasSameBase(snapshot)) {
                return null
            }

            currentSnapshot.csvSnapshot?.let { return it }
            exportEpoch
        }

        val packetSnapshot = snapshot.packetSnapshot ?: return null
        showExportPhaseOnMainThread(ExportPhase.GENERATING_CSV)
        val generatedCsv = createCsvSnapshot(
            source = packetSnapshot,
            timeline = snapshot.timelineSnapshot,
            sessionStartMillis = snapshot.sessionStartMillis ?: wallClockMillisProvider(),
        )

        return synchronized(exportLock) {
            val currentSnapshot = exportSnapshot
            if (exportEpoch != buildEpoch || currentSnapshot == null || !currentSnapshot.hasSameBase(snapshot)) {
                deleteSnapshotFiles(snapshot.copy(csvSnapshot = generatedCsv))
                currentSnapshot?.takeIf { it.hasSameBase(snapshot) }?.csvSnapshot
            } else {
                val updatedSnapshot = currentSnapshot.copy(csvSnapshot = generatedCsv)
                exportSnapshot = updatedSnapshot
                generatedCsv
            }
        }
    }

    private fun invalidateExportSnapshotLocked(): SessionExportSnapshot? {
        val snapshot = exportSnapshot
        exportSnapshot = null
        exportEpoch++
        return snapshot
    }

    private fun createSnapshotCopy(
        source: File,
        suffix: String,
    ): File {
        val targetDirectory = snapshotDirectory ?: source.parentFile
        targetDirectory.mkdirs()
        val target = File(
            targetDirectory,
            "${source.nameWithoutExtension}_snapshot_$suffix.${source.extension.ifBlank { "bin" }}",
        )
        Files.copy(
            source.toPath(),
            target.toPath(),
            StandardCopyOption.REPLACE_EXISTING,
            StandardCopyOption.COPY_ATTRIBUTES,
        )
        return target
    }

    private fun createCsvSnapshot(
        source: File,
        timeline: File?,
        sessionStartMillis: Long,
    ): File {
        val canonicalTarget = currentSessionFile("channel.csv") ?: File(source.parentFile, "channel.csv")
        sessionCsvExporter.export(
            packetFile = source,
            sessionStartMillis = sessionStartMillis,
            targetFile = canonicalTarget,
            packetTimelineFile = timeline,
        )
        currentRecordingId?.let { woonaDatabase?.registerCsv(it, canonicalTarget) }
        notifyRecordingChanged()
        val targetDirectory = snapshotDirectory ?: source.parentFile
        targetDirectory.mkdirs()
        val sessionBaseName = source.nameWithoutExtension.removeSuffix("_snapshot_packet")
        val snapshot = File(targetDirectory, "${sessionBaseName}_snapshot_csv.csv")
        Files.copy(
            canonicalTarget.toPath(),
            snapshot.toPath(),
            StandardCopyOption.REPLACE_EXISTING,
            StandardCopyOption.COPY_ATTRIBUTES,
        )
        return snapshot
    }

    private fun finalizeRecording(status: RecordingStatus) {
        val recordingId = synchronized(this) {
            val id = currentRecordingId ?: return
            if (recordingFinalized || recordingFinalizing) return
            recordingFinalizing = true
            id
        }
        try {
            stopLinkMonitor()
            stopVideo()
            polarFileStore?.close()
            polarSessionManager?.setRecordingActive(false)
            bleSessionController.setCaptureActive(false)
            val captureDrained = packetCaptureController.finishCapture(CAPTURE_FINISH_TIMEOUT_MILLIS)
            if (!captureDrained) {
                packetCaptureController.recordDiagnosticEvent(
                    type = PacketDiagnosticType.REJECTED,
                    message = "Capture finalization timed out: drain_timeout",
                )
                Log.e("BLE_PROCESSOR", "Capture finalization timed out for recording $recordingId")
                pendingFinalizationStatus = status
                schedule(finalizationRetryRunnable, FINALIZATION_RETRY_DELAY_MILLIS)
                return
            }
            persistSyncMetadata()
            try {
                woonaDatabase?.finishRecording(recordingId, status)
                synchronized(this) {
                    recordingFinalized = true
                    synchronizedCaptureStarted = false
                }
                pendingFinalizationStatus = null
                onCaptureLifecycleChanged(false)
            } catch (exception: Exception) {
                Log.e("WOONA_DATABASE", "Failed to finalize recording $recordingId", exception)
                showErrorOnMainThread("Failed to finalize recording", exception)
            }
            notifyRecordingChanged()
        } finally {
            recordingFinalizing = false
        }
    }

    @Synchronized
    fun startVideo() {
        val recorder = videoRecorder
        val recording = currentRecording
        val metadata = captureSyncMetadata
        if (
            recorder == null ||
            recording == null ||
            recording.source != RecordingSource.LIVE ||
            recordingFinalized ||
            recordingFinalizing ||
            metadata?.sensor == null ||
            uiState.videoState !in setOf(VideoCaptureState.READY, VideoCaptureState.FAILED)
        ) {
            return
        }

        val requestedAt = captureClockAnchor("video_requested")
        captureSyncMetadata = metadata.copy(
            video = VideoSyncMetadata(
                requestedAtUtc = requestedAt.absoluteUtc,
                requestedMonotonicNs = requestedAt.monotonicTimeNs,
            ),
        )
        persistSyncMetadata()
        uiStateHolder.videoStarting()
        val started = recorder.start(
            file = File(requireNotNull(currentRecordingDirectory), "video.mp4"),
            onStarted = { info ->
                runOnUiThread {
                    handleVideoStarted(info)
                }
            },
            onError = { message, throwable ->
                Log.e("WOONA_VIDEO", message, throwable)
                runOnUiThread {
                    handleVideoFailure("$message${throwable?.let { ": $it" }.orEmpty()}")
                }
            },
        )
        if (!started) handleVideoFailure()
    }

    @Synchronized
    fun stopVideo() {
        val recorder = videoRecorder ?: return
        if (!recorder.isActive()) return
        runOnUiThread { uiStateHolder.videoStopping() }
        val result = recorder.stop()
        val metadata = captureSyncMetadata
        val video = metadata?.video
        if (metadata != null && video != null) {
            val stoppedAt = result?.stoppedMonotonicNs ?: monotonicNanosProvider()
            captureSyncMetadata = metadata.copy(
                video = video.copy(
                    stoppedAtUtc = instantForMonotonic(stoppedAt).toString(),
                    stoppedMonotonicNs = stoppedAt,
                    durationNs = result?.durationNs,
                    firstVideoSamplePtsUs = result?.firstVideoSamplePtsUs,
                ),
            )
            persistSyncMetadata()
        }
        currentSessionFile("video.mp4")
            ?.takeIf { it.exists() && it.length() > 0L }
            ?.let { file ->
                currentRecordingId?.let { recordingId ->
                    woonaDatabase?.registerArtifact(recordingId, ArtifactType.VIDEO, file)
                }
            }
        if (result == null) {
            runOnUiThread { handleVideoFailure() }
            return
        }
        runOnUiThread { uiStateHolder.videoFinished() }
        notifyRecordingChanged()
    }

    fun onVideoPermissionDenied() {
        uiStateHolder.videoFailed(appTextResolver.getString(R.string.video_camera_permission_required))
    }

    @Synchronized
    private fun handleVideoStarted(info: AndroidVideoStartInfo) {
        if (recordingFinalized) {
            stopVideo()
            return
        }
        val metadata = captureSyncMetadata ?: return
        val sensor = metadata.sensor ?: return
        val video = metadata.video ?: return
        val offsetNs = monotonicOffsetNs(sensor, info.firstFrameMonotonicNs)
        captureSyncMetadata = metadata.copy(
            video = video.copy(
                mediaRecorderStartedMonotonicNs = info.mediaRecorderStartedMonotonicNs,
                firstFrameAtUtc = instantForMonotonic(info.firstFrameMonotonicNs).toString(),
                firstFrameEpochMillis = sensor.wallClockEpochMillis + offsetNs / 1_000_000.0,
                firstFrameMonotonicNs = info.firstFrameMonotonicNs,
                firstFrameCameraTimestampNs = info.firstFrameCameraTimestampNs,
                firstFrameCallbackMonotonicNs = info.firstFrameCallbackMonotonicNs,
                offsetFromSensorNs = offsetNs,
                cameraTimestampSource = info.cameraTimestampSource,
                synchronizationQuality = info.synchronizationQuality,
                cameraId = info.cameraId,
                lensFacing = info.lensFacing,
                width = info.width,
                height = info.height,
                frameRate = info.frameRate,
                rotationDegrees = info.rotationDegrees,
            ),
        )
        persistSyncMetadata()
        uiStateHolder.videoStarted(offsetNs / 1_000_000.0)
        notifyRecordingChanged()
    }

    @Synchronized
    private fun handleVideoFailure(message: String = appTextResolver.getString(R.string.video_recording_failed)) {
        if (recordingFinalized) return
        if (synchronizedCaptureStarted) {
            currentRecordingId?.let { woonaDatabase?.markCaptureError(it, "camera_failed", message) }
            uiStateHolder.videoDegraded(message)
        } else {
            uiStateHolder.videoFailed(message)
        }
        persistSyncMetadata()
        notifyRecordingChanged()
    }

    private fun captureClockAnchor(event: String): SyncClockAnchor {
        val before = monotonicNanosProvider()
        val wallClock = wallClockMillisProvider()
        val after = monotonicNanosProvider()
        return SyncClockAnchor(
            event = event,
            absoluteUtc = Instant.ofEpochMilli(wallClock).toString(),
            wallClockEpochMillis = wallClock,
            monotonicTimeNs = before + (after - before) / 2,
            monotonicClock = "android.elapsedRealtimeNanos",
            samplingUncertaintyNs = (after - before).coerceAtLeast(0L) / 2,
        )
    }

    private fun instantForMonotonic(monotonicNs: Long): Instant {
        val sensor = requireNotNull(captureSyncMetadata?.sensor)
        return absoluteInstantForMonotonic(sensor, monotonicNs)
    }

    private fun persistSyncMetadata() {
        val recordingId = currentRecordingId ?: return
        val metadata = captureSyncMetadata ?: return
        try {
            woonaDatabase?.writeSyncMetadata(recordingId, metadata)
        } catch (exception: Exception) {
            Log.e("WOONA_DATABASE", "Failed to write synchronization metadata", exception)
            showErrorOnMainThread("Failed to write synchronization metadata", exception)
        }
    }

    private fun currentSessionFile(name: String): File? {
        return currentRecordingDirectory?.let { File(it, name) }
    }

    private fun archiveMetadata(
        summary: com.example.myapplication.data.RecordingSummary,
        synchronizationJson: String?,
    ) = SessionArchiveMetadata(
        profileId = summary.recording.profileId,
        profileName = summary.profileName,
        recordingId = summary.recording.id,
        source = summary.recording.source.value,
        status = summary.recording.status.value,
        timezone = summary.recording.timezone,
        profileQuestionnaireJson = summary.profileQuestionnaire.toJson(),
        questionnaireJson = summary.recording.questionnaire?.toJson(),
        synchronizationJson = synchronizationJson,
        sessionLabel = summary.recording.sessionLabel,
    )

    private fun syncProcessorSelection() {
        packetCaptureController.updateSelection(
            sensorType = uiStateHolder.uiState.selectedSensorType,
            channel = uiStateHolder.uiState.selectedChannel,
        )
    }

    private fun notifyRecordingChanged() {
        recordingChangedListener()
    }

    private fun captureErrorCode(message: String): String {
        val normalized = message.lowercase()
        return when {
            "notification silence" in normalized || "recovery exhausted" in normalized -> "notification_timeout"
            ("queue" in normalized && "overflow" in normalized) ||
                ("очеред" in normalized && "переполн" in normalized) -> "queue_overflow"
            "persist" in normalized || "flush" in normalized || "storage" in normalized ||
                "сохран" in normalized || "буфер" in normalized -> "storage_error"
            "gatt" in normalized || "ble" in normalized -> "gatt_error"
            else -> "capture_error"
        }
    }

    private fun startLinkMonitor() {
        weakSinceMillis = null
        lastAlarmQuality = null
        linkMonitorRunning = true
        updateConnectionQuality(connectionQualityTracker.connect(monotonicMillis()))
        cancel(linkMonitorRunnable)
        schedule(linkMonitorRunnable, LINK_MONITOR_INTERVAL_MILLIS)
    }

    private fun startPolarRecording() {
        if (uiState.polarStatus.state != PolarConnectionState.READY) return
        if (polarFileStore?.start() == true) polarSessionManager?.setRecordingActive(true)
    }

    private fun stopLinkMonitor() {
        linkMonitorRunning = false
        cancel(linkMonitorRunnable)
    }

    private fun updateConnectionQuality(snapshot: ConnectionQualitySnapshot) {
        uiStateHolder.updateConnectionQuality(snapshot)
        val now = monotonicMillis()
        when (snapshot.quality) {
            ConnectionQuality.WEAK -> {
                val weakSince = weakSinceMillis ?: now.also { weakSinceMillis = it }
                if (now - weakSince >= WEAK_ALARM_DELAY_MILLIS && lastAlarmQuality != ConnectionQuality.WEAK) {
                    lastAlarmQuality = ConnectionQuality.WEAK
                    onConnectionAlarm(ConnectionQuality.WEAK)
                }
            }

            ConnectionQuality.LOST -> {
                weakSinceMillis = null
                if (lastAlarmQuality != ConnectionQuality.LOST) {
                    lastAlarmQuality = ConnectionQuality.LOST
                    onConnectionAlarm(ConnectionQuality.LOST)
                }
            }

            ConnectionQuality.GOOD -> {
                weakSinceMillis = null
                if (lastAlarmQuality != null) onConnectionAlarm(ConnectionQuality.GOOD)
                lastAlarmQuality = null
            }

            else -> weakSinceMillis = null
        }
    }

    private fun monotonicMillis(): Long = monotonicNanosProvider() / 1_000_000L

    companion object {
        const val PERMISSION_REQUIRED_MESSAGE = "Permissions are required!"
        private const val CAPTURE_FINISH_TIMEOUT_MILLIS = 2_000L
        private const val FINALIZATION_RETRY_DELAY_MILLIS = 1_000L
        private const val LINK_MONITOR_INTERVAL_MILLIS = 1_000L
        private const val WEAK_ALARM_DELAY_MILLIS = 5_000L
    }
}

private data class SessionExportSnapshot(
    val packetSourcePath: String?,
    val timelineSourcePath: String?,
    val rawSourcePath: String?,
    val logSourcePath: String?,
    val sessionStartMillis: Long?,
    val packetSnapshot: File?,
    val timelineSnapshot: File?,
    val rawSnapshot: File?,
    val logSnapshot: File?,
    val csvSnapshot: File?,
) {
    fun matches(
        packetFile: File?,
        timelineFile: File?,
        rawFile: File?,
        logFile: File?,
        sessionStartMillis: Long?,
    ): Boolean {
        return packetSourcePath == packetFile?.absolutePath &&
            timelineSourcePath == timelineFile?.absolutePath &&
            rawSourcePath == rawFile?.absolutePath &&
            logSourcePath == logFile?.absolutePath &&
            this.sessionStartMillis == sessionStartMillis
    }

    fun hasSameBase(other: SessionExportSnapshot): Boolean {
        return packetSourcePath == other.packetSourcePath &&
            timelineSourcePath == other.timelineSourcePath &&
            rawSourcePath == other.rawSourcePath &&
            logSourcePath == other.logSourcePath &&
            sessionStartMillis == other.sessionStartMillis &&
            packetSnapshot?.absolutePath == other.packetSnapshot?.absolutePath &&
            timelineSnapshot?.absolutePath == other.timelineSnapshot?.absolutePath &&
            rawSnapshot?.absolutePath == other.rawSnapshot?.absolutePath &&
            logSnapshot?.absolutePath == other.logSnapshot?.absolutePath
    }
}

private data class ExportSnapshotBuildPlan(
    val epoch: Long,
    val sessionStartMillis: Long?,
    val packetFile: File?,
    val timelineFile: File?,
    val rawFile: File?,
    val logFile: File?,
    val staleSnapshot: SessionExportSnapshot?,
)

private fun deleteSnapshotFiles(snapshot: SessionExportSnapshot?) {
    listOfNotNull(
        snapshot?.packetSnapshot,
        snapshot?.timelineSnapshot,
        snapshot?.rawSnapshot,
        snapshot?.logSnapshot,
        snapshot?.csvSnapshot,
    )
        .forEach { file ->
            try {
                if (file.exists()) {
                    file.delete()
                }
            } catch (exception: Exception) {
                Log.w("BLE_SHARE", "Failed to delete snapshot file ${file.absolutePath}", exception)
            }
        }
}
