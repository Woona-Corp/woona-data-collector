package com.example.myapplication.feature.device

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.example.myapplication.ble.BleTransportProfile
import com.example.myapplication.ble.BleDevice
import com.example.myapplication.ble.BleSessionState
import com.example.myapplication.ble.PolarStatus
import com.example.myapplication.R
import com.example.myapplication.protocol.ConnectionQuality
import com.example.myapplication.protocol.ConnectionQualitySnapshot
import kotlin.math.ceil

data class DeviceListItem(
    val name: String,
    val address: String,
)

data class ChartPoint(
    val timeMillis: Long,
    val value: Float,
    val startsNewSegment: Boolean = false,
)

data class ChartStreamKey(
    val sensorType: Int,
    val channel: Int,
)

enum class ChartWindowPreset(
    val label: String,
    val durationMillis: Long,
) {
    // These labels intentionally avoid wall-clock units because the chart presents raw device timer spans.
    THIRTY_SECONDS(label = "30k", durationMillis = 30_000L),
    SIXTY_SECONDS(label = "60k", durationMillis = 60_000L),
    FIVE_MINUTES(label = "300k", durationMillis = 5 * 60_000L),
    FIFTEEN_MINUTES(label = "900k", durationMillis = 15 * 60_000L),
}

data class ChartUiState(
    val points: List<ChartPoint> = emptyList(),
    val windowPreset: ChartWindowPreset = DEFAULT_CHART_WINDOW_PRESET,
    val isFollowingLive: Boolean = true,
    val canPanLeft: Boolean = false,
    val canPanRight: Boolean = false,
    val canZoomIn: Boolean = false,
    val canZoomOut: Boolean = false,
    val yAxisAbsRange: Float = DEFAULT_CHART_Y_AXIS_ABS_RANGE,
    val yAxisCenter: Float = 0f,
    val viewportStartMillis: Long? = null,
    val viewportEndMillis: Long? = null,
    val sessionStartMillis: Long? = null,
    val latestPointMillis: Long? = null,
)

enum class DeviceCaptureTab(
    val label: String,
) {
    OVERVIEW("Overview"),
    CHART("Chart"),
}

enum class ExportPhase(
    val labelRes: Int,
) {
    PREPARING_SNAPSHOTS(R.string.export_phase_preparing_snapshots),
    GENERATING_CSV(R.string.export_phase_generating_csv),
    OPENING_SHARE_SHEET(R.string.export_phase_opening_share_sheet),
    PACKAGING_ARCHIVE(R.string.export_phase_packaging_archive),
}

enum class V2PreviewStage { NONE, CONNECTING, CHECKING, READY, STARTING, RUNNING, STOPPING, STOPPED, FAILED }

enum class VideoCaptureState {
    IDLE,
    WAITING_FOR_SENSOR,
    READY,
    STARTING,
    RECORDING,
    DEGRADED,
    STOPPING,
    FINISHED,
    FAILED,
}

data class DeviceUiState(
    val chart: ChartUiState = ChartUiState(),
    val selectedTab: DeviceCaptureTab = DeviceCaptureTab.OVERVIEW,
    val foundDevices: List<DeviceListItem> = emptyList(),
    val transportProfile: BleTransportProfile = BleTransportProfile.COMPATIBILITY,
    val selectedSensorType: Int = DEFAULT_SENSOR_TYPE_VALUE,
    val selectedChannel: Int = DEFAULT_CHANNEL_VALUE,
    val showCaptureUi: Boolean = false,
    val isReplayPreparing: Boolean = false,
    val isReplayRunning: Boolean = false,
    val isScanning: Boolean = false,
    val isConnected: Boolean = false,
    val v2DiscoveryRequested: Boolean = false,
    val v2DiscoveryError: String? = null,
    val v2Ready: Boolean = false,
    val v2StreamMask: Long = 0,
    val v2Capabilities: Long = 0L,
    val v2DeviceSessionMode: Int = 0,
    val v2SelectedStreamMask: Long = 0L,
    val v2LiveRunning: Boolean = false,
    val v2PreviewStage: V2PreviewStage = V2PreviewStage.NONE,
    val v2PreviewBlocks: Long = 0,
    val v2SequenceGaps: Long = 0,
    val v2ChartSkippedBlocks: Long = 0,
    val packetsReceived: Long = 0L,
    val packetsLost: Long = 0L,
    val packetsRejected: Long = 0L,
    val timerRegressionRejects: Long = 0L,
    val fragmentsReceived: Long = 0L,
    val rawBytesReceived: Long = 0L,
    val lastPacketIssue: String? = null,
    val rejectionBreakdown: String? = null,
    val diagnosticEvents: List<PacketDiagnosticEvent> = emptyList(),
    val errorMessage: String? = null,
    val exportPhase: ExportPhase? = null,
    val videoState: VideoCaptureState = VideoCaptureState.IDLE,
    val videoOffsetMillis: Double? = null,
    val connectionQuality: ConnectionQuality = ConnectionQuality.IDLE,
    val recentLossPercent: Double = 0.0,
    val recentRejectedPercent: Double = 0.0,
    val packetSilenceMillis: Long = 0L,
    val polarDevices: List<DeviceListItem> = emptyList(),
    val polarStatus: PolarStatus = PolarStatus(),
)

class DeviceUiStateHolder {
    var uiState by mutableStateOf(DeviceUiState())
        private set

    private val chartHistory = linkedMapOf<ChartStreamKey, MutableList<ChartPoint>>()
    private var sessionStartMillis: Long? = null
    private var latestChartTimeMillis: Long? = null
    private var chartWindowPreset = DEFAULT_CHART_WINDOW_PRESET
    private var isFollowingLive = true
    private var manualViewportEndMillis: Long? = null
    private var chartVerticalZoomFactor = 1f
    private var chartVerticalCenterOverride: Float? = null

    fun prepareForScan() {
        uiState = uiState.copy(
            foundDevices = emptyList(),
            errorMessage = null,
        )
    }

    fun addFoundDevice(device: BleDevice) {
        if (uiState.foundDevices.any { it.address == device.address }) return

        uiState = uiState.copy(
            foundDevices = uiState.foundDevices + DeviceListItem(
                name = device.name,
                address = device.address,
            ),
        )
    }

    fun prepareForPolarScan() {
        uiState = uiState.copy(polarDevices = emptyList())
    }

    fun addFoundPolarDevice(device: BleDevice) {
        if (uiState.polarDevices.any { it.address == device.address }) return
        uiState = uiState.copy(
            polarDevices = uiState.polarDevices + DeviceListItem(device.name, device.address),
        )
    }

    fun updatePolarStatus(status: PolarStatus) {
        uiState = uiState.copy(polarStatus = status)
    }

    fun onTransportProfileSelected(profile: BleTransportProfile) {
        uiState = uiState.copy(transportProfile = profile)
    }

    fun onV2PreviewConnecting() {
        clearChartHistory()
        uiState = uiState.copy(
            v2DiscoveryRequested = true, v2DiscoveryError = null, v2Ready = false,
            v2PreviewStage = V2PreviewStage.CONNECTING, v2LiveRunning = false,
            v2PreviewBlocks = 0, v2SequenceGaps = 0, v2ChartSkippedBlocks = 0,
            v2StreamMask = 0, v2SelectedStreamMask = 0, v2Capabilities = 0, v2DeviceSessionMode = 0,
            packetsReceived = 0, packetsLost = 0, packetsRejected = 0, fragmentsReceived = 0, rawBytesReceived = 0,
            diagnosticEvents = emptyList(), connectionQuality = ConnectionQuality.IDLE, lastPacketIssue = null,
            rejectionBreakdown = null, packetSilenceMillis = 0, recentLossPercent = 0.0, recentRejectedPercent = 0.0,
            selectedSensorType = 2, selectedChannel = 1,
            showCaptureUi = true, isReplayRunning = false, videoState = VideoCaptureState.IDLE,
            chart = ChartUiState(), errorMessage = null,
        )
    }

    fun onV2DiscoveryRequested() {
        uiState = uiState.copy(
            v2DiscoveryRequested = true,
            v2DiscoveryError = null,
            v2Ready = false,
            v2StreamMask = 0L,
            v2PreviewStage = V2PreviewStage.CHECKING,
            errorMessage = null,
        )
    }

    fun onV2DiscoveryReady(streamMask: Long, capabilities: Long, sessionMode: Int = 0) {
        val defaultMask = (streamMask and 0x03L).takeIf { it != 0L }
            ?: java.lang.Long.lowestOneBit(streamMask)
        uiState = uiState.copy(
            v2DiscoveryRequested = true,
            v2DiscoveryError = null,
            v2Ready = true,
            v2StreamMask = streamMask,
            v2Capabilities = capabilities,
            v2DeviceSessionMode = sessionMode,
            v2SelectedStreamMask = defaultMask,
            v2PreviewStage = V2PreviewStage.READY,
            errorMessage = null,
        )
    }

    fun onV2DeviceBusy(mode: Int) { uiState = uiState.copy(v2DeviceSessionMode = mode) }

    fun onV2DiscoveryFailed(reason: String) {
        // HELLO may already have switched the firmware; never offer automatic
        // fallback to Legacy on this connection.
        uiState = uiState.copy(
            v2DiscoveryRequested = true,
            v2DiscoveryError = reason,
            v2Ready = false,
            v2LiveRunning = false,
            v2PreviewStage = V2PreviewStage.FAILED,
        )
    }

    fun toggleV2Stream(streamId: Int) {
        if (uiState.v2PreviewStage !in setOf(V2PreviewStage.READY, V2PreviewStage.STOPPED) || streamId !in 1..7) return
        val bit = 1L shl (streamId - 1)
        if (uiState.v2StreamMask and bit == 0L) return
        val next = uiState.v2SelectedStreamMask xor bit
        if (next == 0L) return // A session requires at least one data stream.
        uiState = uiState.copy(v2SelectedStreamMask = next)
    }

    fun onV2LiveStarted() {
        clearChartHistory()
        uiState = uiState.copy(
            v2LiveRunning = true,
            v2PreviewStage = V2PreviewStage.RUNNING,
            v2PreviewBlocks = 0L,
            v2SequenceGaps = 0L,
            v2ChartSkippedBlocks = 0L,
            chart = buildChartUiState(uiState.selectedSensorType, uiState.selectedChannel),
        )
    }

    fun onV2LiveStopped() {
        uiState = uiState.copy(v2LiveRunning = false, v2PreviewStage = V2PreviewStage.STOPPED)
    }

    fun onV2StartRequested() { uiState = uiState.copy(v2PreviewStage = V2PreviewStage.STARTING) }
    fun onV2StopRequested() { uiState = uiState.copy(v2PreviewStage = V2PreviewStage.STOPPING) }

    /** Visual preview only. Persistent V2 recording will use a separate file format. */
    fun onV2LivePreview(
        samplesByStream: Map<ChartStreamKey, List<ChartPoint>>,
        receivedBlocks: Int,
        sequenceGaps: Int,
        chartSkippedBlocks: Int = 0,
    ) {
        if (!uiState.v2DiscoveryRequested || uiState.v2PreviewStage !in setOf(V2PreviewStage.RUNNING, V2PreviewStage.STOPPING, V2PreviewStage.STOPPED)) return
        appendChartSamples(samplesByStream)
        uiState = uiState.copy(
            v2PreviewBlocks = uiState.v2PreviewBlocks + receivedBlocks,
            v2SequenceGaps = uiState.v2SequenceGaps + sequenceGaps,
            v2ChartSkippedBlocks = uiState.v2ChartSkippedBlocks + chartSkippedBlocks,
            chart = buildChartUiState(uiState.selectedSensorType, uiState.selectedChannel),
        )
    }

    fun onSessionStateChanged(state: BleSessionState) {
        if (uiState.isReplayPreparing || uiState.isReplayRunning) return

        val updatedState = uiState.copy(
            showCaptureUi = uiState.showCaptureUi || state == BleSessionState.CONNECTED,
            isScanning = state == BleSessionState.SCANNING,
            isConnected = state == BleSessionState.CONNECTED,
            errorMessage = when (state) {
                BleSessionState.SCANNING,
                BleSessionState.CONNECTED,
                -> null

                else -> uiState.errorMessage
            },
        )

        uiState = if (state == BleSessionState.DISCONNECTED) {
            updatedState.copy(
                showCaptureUi = false,
                isReplayRunning = false,
                exportPhase = null,
                v2DiscoveryRequested = false,
                v2DiscoveryError = null,
                v2Ready = false,
                v2StreamMask = 0L,
                v2Capabilities = 0L,
                v2DeviceSessionMode = 0,
                v2SelectedStreamMask = 0L,
                v2LiveRunning = false,
                v2PreviewStage = V2PreviewStage.NONE,
            )
        } else {
            updatedState
        }
    }

    fun applyPacketUpdate(update: PacketProcessingUpdate) {
        appendChartSamples(update.chartSamplesByStream)
        uiState = uiState.copy(
            packetsReceived = update.packetsReceived,
            packetsLost = update.packetsLost,
            packetsRejected = update.packetsRejected,
            timerRegressionRejects = update.timerRegressionRejects,
            fragmentsReceived = update.fragmentsReceived,
            rawBytesReceived = update.rawBytesReceived,
            chart = buildChartUiState(
                selectedSensorType = uiState.selectedSensorType,
                selectedChannel = uiState.selectedChannel,
            ),
            lastPacketIssue = update.lastPacketIssue ?: uiState.lastPacketIssue,
            rejectionBreakdown = update.rejectionBreakdown ?: uiState.rejectionBreakdown,
            diagnosticEvents = (update.diagnosticEvents + uiState.diagnosticEvents).take(MAX_DIAGNOSTIC_EVENTS),
        )
    }

    fun updateConnectionQuality(snapshot: ConnectionQualitySnapshot) {
        uiState = uiState.copy(
            connectionQuality = snapshot.quality,
            recentLossPercent = snapshot.lossPercent,
            recentRejectedPercent = snapshot.rejectedPercent,
            packetSilenceMillis = snapshot.silenceMillis,
        )
    }

    fun startReplayPreparation() {
        uiState = uiState.copy(
            isReplayPreparing = true,
            isScanning = false,
            errorMessage = null,
        )
    }

    fun cancelReplayPreparation() {
        uiState = uiState.copy(isReplayPreparing = false)
    }

    fun startReplaySession() {
        clearChartHistory()
        uiState = uiState.copy(
            showCaptureUi = true,
            isReplayPreparing = false,
            isReplayRunning = true,
            isConnected = false,
            isScanning = false,
            selectedTab = DeviceCaptureTab.OVERVIEW,
            chart = buildChartUiState(
                selectedSensorType = uiState.selectedSensorType,
                selectedChannel = uiState.selectedChannel,
            ),
            packetsReceived = 0L,
            packetsLost = 0L,
            packetsRejected = 0L,
            timerRegressionRejects = 0L,
            fragmentsReceived = 0L,
            rawBytesReceived = 0L,
            lastPacketIssue = null,
            rejectionBreakdown = null,
            diagnosticEvents = emptyList(),
            errorMessage = null,
            exportPhase = null,
            videoState = VideoCaptureState.IDLE,
            videoOffsetMillis = null,
            connectionQuality = ConnectionQuality.IDLE,
            recentLossPercent = 0.0,
            recentRejectedPercent = 0.0,
            packetSilenceMillis = 0L,
        )
    }

    fun finishReplaySession() {
        uiState = uiState.copy(
            isReplayPreparing = false,
            isReplayRunning = false,
        )
    }

    fun stopCaptureSession() {
        clearChartHistory()
        uiState = uiState.copy(
            v2DiscoveryRequested = false, v2DiscoveryError = null, v2Ready = false,
            v2LiveRunning = false, v2PreviewStage = V2PreviewStage.NONE,
            v2StreamMask = 0, v2SelectedStreamMask = 0, v2Capabilities = 0, v2DeviceSessionMode = 0,
            v2PreviewBlocks = 0, v2SequenceGaps = 0, v2ChartSkippedBlocks = 0,
            showCaptureUi = false,
            isReplayPreparing = false,
            isReplayRunning = false,
            isConnected = false,
            isScanning = false,
            selectedTab = DeviceCaptureTab.OVERVIEW,
            chart = buildChartUiState(
                selectedSensorType = uiState.selectedSensorType,
                selectedChannel = uiState.selectedChannel,
            ),
            packetsReceived = 0L,
            packetsLost = 0L,
            packetsRejected = 0L,
            timerRegressionRejects = 0L,
            fragmentsReceived = 0L,
            rawBytesReceived = 0L,
            lastPacketIssue = null,
            rejectionBreakdown = null,
            diagnosticEvents = emptyList(),
            exportPhase = null,
            connectionQuality = ConnectionQuality.IDLE,
            recentLossPercent = 0.0,
            recentRejectedPercent = 0.0,
            packetSilenceMillis = 0L,
        )
    }

    fun onSensorTypeSelected(sensorType: Int) {
        chartVerticalCenterOverride = null
        uiState = uiState.copy(
            selectedSensorType = sensorType,
            selectedChannel = DEFAULT_CHANNEL_VALUE,
            chart = buildChartUiState(
                selectedSensorType = sensorType,
                selectedChannel = DEFAULT_CHANNEL_VALUE,
            ),
        )
    }

    fun onChannelSelected(channel: Int) {
        chartVerticalCenterOverride = null
        uiState = uiState.copy(
            selectedChannel = channel,
            chart = buildChartUiState(
                selectedSensorType = uiState.selectedSensorType,
                selectedChannel = channel,
            ),
        )
    }

    fun onChartWindowSelected(windowPreset: ChartWindowPreset) {
        chartWindowPreset = windowPreset
        chartVerticalCenterOverride = null
        uiState = uiState.copy(
            chart = buildChartUiState(
                selectedSensorType = uiState.selectedSensorType,
                selectedChannel = uiState.selectedChannel,
            ),
        )
    }

    fun onTabSelected(tab: DeviceCaptureTab) {
        uiState = uiState.copy(selectedTab = tab)
    }

    fun onFollowLiveChanged(enabled: Boolean) {
        isFollowingLive = enabled
        manualViewportEndMillis = if (enabled) null else latestChartTimeMillis
        chartVerticalCenterOverride = null
        uiState = uiState.copy(
            chart = buildChartUiState(
                selectedSensorType = uiState.selectedSensorType,
                selectedChannel = uiState.selectedChannel,
            ),
        )
    }

    fun jumpToLive() {
        onFollowLiveChanged(enabled = true)
    }

    fun panChartLeft() {
        val latest = latestChartTimeMillis ?: return
        val currentEnd = resolveViewportEnd(latest) ?: return
        val shiftedEnd = (currentEnd - chartPanStepMillis(currentEnd))
            .coerceAtLeast(sessionStartMillis ?: currentEnd)
        chartVerticalCenterOverride = null
        isFollowingLive = false
        manualViewportEndMillis = shiftedEnd
        uiState = uiState.copy(
            chart = buildChartUiState(
                selectedSensorType = uiState.selectedSensorType,
                selectedChannel = uiState.selectedChannel,
            ),
        )
    }

    fun panChartRight() {
        val latest = latestChartTimeMillis ?: return
        val currentEnd = resolveViewportEnd(latest) ?: return
        val shiftedEnd = (currentEnd + chartPanStepMillis(currentEnd)).coerceAtMost(latest)
        chartVerticalCenterOverride = null
        isFollowingLive = shiftedEnd >= latest
        manualViewportEndMillis = if (isFollowingLive) null else shiftedEnd
        uiState = uiState.copy(
            chart = buildChartUiState(
                selectedSensorType = uiState.selectedSensorType,
                selectedChannel = uiState.selectedChannel,
            ),
        )
    }

    fun zoomInChart() {
        zoomChart(scaleFactor = 2f)
    }

    fun zoomOutChart() {
        zoomChart(scaleFactor = 0.5f)
    }

    fun zoomChart(
        scaleFactor: Float,
        anchorFractionY: Float = 0.5f,
    ) {
        if (scaleFactor <= 0f) return
        val currentRange = uiState.chart.yAxisAbsRange
        val currentCenter = uiState.chart.yAxisCenter
        val nextZoomFactor = (chartVerticalZoomFactor * scaleFactor)
            .coerceIn(MIN_CHART_VERTICAL_ZOOM_FACTOR, MAX_CHART_VERTICAL_ZOOM_FACTOR)
        if (nextZoomFactor == chartVerticalZoomFactor) return
        val nextRange = chartYAxisAbsRange(nextZoomFactor)

        chartVerticalZoomFactor = nextZoomFactor
        chartVerticalCenterOverride = if (nextZoomFactor == MIN_CHART_VERTICAL_ZOOM_FACTOR) {
            null
        } else {
            val clampedAnchorFraction = anchorFractionY.coerceIn(0f, 1f)
            val anchorCoefficient = 1f - (2f * clampedAnchorFraction)
            currentCenter + ((currentRange - nextRange) * anchorCoefficient)
        }

        uiState = uiState.copy(
            chart = buildChartUiState(
                selectedSensorType = uiState.selectedSensorType,
                selectedChannel = uiState.selectedChannel,
            ),
        )
    }

    fun panChartByFraction(deltaFraction: Float) {
        val latest = latestChartTimeMillis ?: return
        val viewportEnd = resolveViewportEnd(latest) ?: return
        val duration = effectiveViewportDurationMillis(viewportEnd)
        if (duration <= 0L) return
        val deltaMillis = (duration * deltaFraction).toLong()
        if (deltaMillis == 0L) return

        chartVerticalCenterOverride = null
        val sessionStart = sessionStartMillis ?: return
        val minViewportEnd = (sessionStart + duration).coerceAtMost(latest)
        val shiftedEnd = (viewportEnd + deltaMillis).coerceIn(minViewportEnd, latest)
        isFollowingLive = shiftedEnd >= latest
        manualViewportEndMillis = if (isFollowingLive) null else shiftedEnd

        uiState = uiState.copy(
            chart = buildChartUiState(
                selectedSensorType = uiState.selectedSensorType,
                selectedChannel = uiState.selectedChannel,
            ),
        )
    }

    fun resetChartZoom() {
        chartVerticalZoomFactor = MIN_CHART_VERTICAL_ZOOM_FACTOR
        chartVerticalCenterOverride = null
        uiState = uiState.copy(
            chart = buildChartUiState(
                selectedSensorType = uiState.selectedSensorType,
                selectedChannel = uiState.selectedChannel,
            ),
        )
    }

    fun resetCaptureSession() {
        clearChartHistory()
        uiState = uiState.copy(
            showCaptureUi = true,
            selectedTab = DeviceCaptureTab.OVERVIEW,
            chart = buildChartUiState(
                selectedSensorType = uiState.selectedSensorType,
                selectedChannel = uiState.selectedChannel,
            ),
            packetsReceived = 0L,
            packetsLost = 0L,
            packetsRejected = 0L,
            timerRegressionRejects = 0L,
            fragmentsReceived = 0L,
            rawBytesReceived = 0L,
            lastPacketIssue = null,
            rejectionBreakdown = null,
            diagnosticEvents = emptyList(),
            exportPhase = null,
            connectionQuality = ConnectionQuality.WAITING,
            recentLossPercent = 0.0,
            recentRejectedPercent = 0.0,
            packetSilenceMillis = 0L,
        )
    }

    fun prepareVideo() {
        uiState = uiState.copy(
            videoState = VideoCaptureState.WAITING_FOR_SENSOR,
            videoOffsetMillis = null,
        )
    }

    fun videoReady() {
        uiState = uiState.copy(videoState = VideoCaptureState.READY)
    }

    fun videoStarting() {
        uiState = uiState.copy(videoState = VideoCaptureState.STARTING)
    }

    fun videoStarted(offsetMillis: Double) {
        uiState = uiState.copy(
            videoState = VideoCaptureState.RECORDING,
            videoOffsetMillis = offsetMillis,
        )
    }

    fun videoDegraded(message: String) {
        uiState = uiState.copy(
            videoState = VideoCaptureState.DEGRADED,
            errorMessage = message,
        )
    }

    fun videoStopping() {
        uiState = uiState.copy(videoState = VideoCaptureState.STOPPING)
    }

    fun videoFinished() {
        uiState = uiState.copy(videoState = VideoCaptureState.FINISHED)
    }

    fun videoFailed(message: String) {
        uiState = uiState.copy(
            videoState = VideoCaptureState.FAILED,
            errorMessage = message,
        )
    }

    fun showError(message: String) {
        uiState = uiState.copy(errorMessage = message)
    }

    fun showExportProgress(phase: ExportPhase) {
        uiState = uiState.copy(exportPhase = phase)
    }

    fun clearExportProgress() {
        uiState = uiState.copy(exportPhase = null)
    }

    private fun appendChartSamples(samplesByStream: Map<ChartStreamKey, List<ChartPoint>>) {
        if (samplesByStream.isEmpty()) return

        samplesByStream.forEach { (streamKey, points) ->
            if (points.isEmpty()) return@forEach

            val history = chartHistory.getOrPut(streamKey) { mutableListOf() }
            history += points
            if (uiState.v2DiscoveryRequested && history.size > MAX_V2_PREVIEW_POINTS_PER_STREAM) {
                val reduced = downsampleVisiblePoints(history, MAX_V2_PREVIEW_POINTS_PER_STREAM / 2)
                history.clear()
                history.addAll(reduced)
            }

            val earliestPoint = points.first().timeMillis
            val latestPoint = points.last().timeMillis
            sessionStartMillis = minOf(sessionStartMillis ?: earliestPoint, earliestPoint)
            latestChartTimeMillis = maxOf(latestChartTimeMillis ?: latestPoint, latestPoint)
        }

        trimChartHistory()
    }

    private fun clearChartHistory() {
        chartHistory.clear()
        sessionStartMillis = null
        latestChartTimeMillis = null
        chartWindowPreset = DEFAULT_CHART_WINDOW_PRESET
        isFollowingLive = true
        manualViewportEndMillis = null
        chartVerticalZoomFactor = MIN_CHART_VERTICAL_ZOOM_FACTOR
        chartVerticalCenterOverride = null
    }

    private fun trimChartHistory() {
        val latest = latestChartTimeMillis ?: return
        val cutoff = latest - MAX_RETAINED_HISTORY_MILLIS

        val iterator = chartHistory.entries.iterator()
        while (iterator.hasNext()) {
            val history = iterator.next().value
            var trimmedPointCount = 0
            while (trimmedPointCount < history.size && history[trimmedPointCount].timeMillis < cutoff) {
                trimmedPointCount++
            }

            if (trimmedPointCount >= history.size) {
                iterator.remove()
                continue
            }

            if (trimmedPointCount > 0) {
                history.subList(0, trimmedPointCount).clear()
            }
        }

        sessionStartMillis = chartHistory.values
            .mapNotNull { it.firstOrNull()?.timeMillis }
            .minOrNull()
        latestChartTimeMillis = chartHistory.values
            .mapNotNull { it.lastOrNull()?.timeMillis }
            .maxOrNull()

        if (!isFollowingLive) {
            manualViewportEndMillis = manualViewportEndMillis?.coerceAtLeast(sessionStartMillis ?: latest)
        }
    }

    private fun buildChartUiState(
        selectedSensorType: Int,
        selectedChannel: Int,
    ): ChartUiState {
        val sessionStart = sessionStartMillis
        val latest = latestChartTimeMillis
        val viewportEnd = resolveViewportEnd(latest)
        val viewportDuration = viewportEnd?.let(::effectiveViewportDurationMillis) ?: currentViewportDurationMillis()
        val viewportStart = when {
            latest == null || viewportEnd == null -> null
            else -> maxOf(sessionStart ?: viewportEnd, viewportEnd - viewportDuration)
        }
        val streamPoints = chartHistory[ChartStreamKey(selectedSensorType, selectedChannel)].orEmpty()
        val visiblePoints = if (viewportStart == null || viewportEnd == null) {
            emptyList()
        } else {
            downsampleVisiblePoints(
                points = slicePoints(streamPoints, viewportStart, viewportEnd),
                maxPoints = MAX_RENDER_CHART_POINTS,
            )
        }

        return ChartUiState(
            points = visiblePoints,
            windowPreset = chartWindowPreset,
            isFollowingLive = isFollowingLive,
            canPanLeft = viewportStart != null && sessionStart != null && viewportStart > sessionStart,
            canPanRight = !isFollowingLive && viewportEnd != null && latest != null && viewportEnd < latest,
            canZoomIn = chartVerticalZoomFactor < MAX_CHART_VERTICAL_ZOOM_FACTOR,
            canZoomOut = chartVerticalZoomFactor > MIN_CHART_VERTICAL_ZOOM_FACTOR,
            yAxisAbsRange = chartYAxisAbsRange(),
            yAxisCenter = chartYAxisCenter(visiblePoints),
            viewportStartMillis = viewportStart,
            viewportEndMillis = viewportEnd,
            sessionStartMillis = sessionStart,
            latestPointMillis = latest,
        )
    }

    private fun resolveViewportEnd(latest: Long?): Long? {
        if (latest == null) return null
        return if (isFollowingLive) {
            latest
        } else {
            (manualViewportEndMillis ?: latest).coerceAtMost(latest)
        }
    }

    private fun chartPanStepMillis(viewportEnd: Long): Long {
        return maxOf(effectiveViewportDurationMillis(viewportEnd) / 4L, MIN_CHART_PAN_STEP_MILLIS)
    }

    private fun currentViewportDurationMillis(): Long {
        return chartWindowPreset.durationMillis
    }

    private fun effectiveViewportDurationMillis(viewportEnd: Long): Long {
        return currentViewportDurationMillis().coerceAtMost(maxViewportDurationMillis(viewportEnd))
    }

    private fun maxViewportDurationMillis(viewportEnd: Long): Long {
        val sessionStart = sessionStartMillis ?: return chartWindowPreset.durationMillis
        val availableDuration = (viewportEnd - sessionStart).coerceAtLeast(0L)
        return minOf(chartWindowPreset.durationMillis, availableDuration)
    }

    private fun chartYAxisAbsRange(zoomFactor: Float = chartVerticalZoomFactor): Float {
        return (DEFAULT_CHART_Y_AXIS_ABS_RANGE / zoomFactor)
            .coerceAtLeast(MIN_CHART_Y_AXIS_ABS_RANGE)
    }

    private fun chartYAxisCenter(points: List<ChartPoint>): Float {
        chartVerticalCenterOverride?.let { return it }
        if (points.isEmpty()) return 0f
        val minValue = points.minOf { it.value }
        val maxValue = points.maxOf { it.value }
        return (minValue + maxValue) / 2f
    }

    private fun slicePoints(
        points: List<ChartPoint>,
        startMillis: Long,
        endMillis: Long,
    ): List<ChartPoint> {
        if (points.isEmpty()) return emptyList()

        val startIndex = points.indexOfFirst { it.timeMillis >= startMillis }.let { index ->
            if (index == -1) return emptyList()
            maxOf(0, index - 1)
        }
        val endIndex = points.indexOfLast { it.timeMillis <= endMillis }.let { index ->
            if (index == -1 || index < startIndex) return emptyList()
            index
        }
        return points.subList(startIndex, endIndex + 1).toList()
    }

    private fun downsampleVisiblePoints(
        points: List<ChartPoint>,
        maxPoints: Int,
    ): List<ChartPoint> {
        if (points.size <= maxPoints) return points

        val step = ceil(points.size / maxPoints.toDouble()).toInt().coerceAtLeast(1)
        return buildList {
            var pendingSegmentBreak = false
            points.forEachIndexed { index, point ->
                pendingSegmentBreak = pendingSegmentBreak || point.startsNewSegment
                if (index == 0 || index == points.lastIndex || index % step == 0) {
                    add(
                        if (isEmpty()) {
                            point.copy(startsNewSegment = false)
                        } else {
                            point.copy(startsNewSegment = pendingSegmentBreak)
                        },
                    )
                    pendingSegmentBreak = false
                }
            }
        }
    }

    private companion object {
        const val MAX_V2_PREVIEW_POINTS_PER_STREAM = 6_000
        const val MAX_DIAGNOSTIC_EVENTS = 40
        const val MAX_RENDER_CHART_POINTS = 1_200
        const val MIN_CHART_PAN_STEP_MILLIS = 1_000L
        const val MAX_RETAINED_HISTORY_MILLIS = 15 * 60_000L
        const val MIN_CHART_VERTICAL_ZOOM_FACTOR = 1f
        const val MAX_CHART_VERTICAL_ZOOM_FACTOR = 64f
    }
}

private val DEFAULT_CHART_WINDOW_PRESET = ChartWindowPreset.THIRTY_SECONDS
private const val DEFAULT_SENSOR_TYPE_VALUE = 2
private const val DEFAULT_CHANNEL_VALUE = 1
private const val DEFAULT_CHART_Y_AXIS_ABS_RANGE = 32768f
private const val MIN_CHART_Y_AXIS_ABS_RANGE = 256f
