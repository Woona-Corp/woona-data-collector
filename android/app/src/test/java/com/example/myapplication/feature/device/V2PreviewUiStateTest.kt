package com.example.myapplication.feature.device

import com.example.myapplication.ble.BleSessionState
import org.junit.Assert.*
import org.junit.Test

class V2PreviewUiStateTest {
    @Test fun clockBackstepSkipsOnlyPlottingAndTheNextValidBlockStartsANewSegment() {
        val timeline = V2PreviewTimeline()
        val descriptor = com.example.myapplication.protocol.V2Stream(1, 1, 3, 1000)
        fun event(time: Long) = com.example.myapplication.protocol.WoonaV2LiveSession.Event.Samples(
            1, com.example.myapplication.protocol.V2LiveData(77, 1, 1, 2, 1000, 0, time, ByteArray(12)), descriptor, false)
        assertFalse(timeline.map(event(10_000)).isEmpty())
        assertTrue(timeline.map(event(9_000)).isEmpty())
        assertTrue(timeline.map(event(11_000)).isEmpty()) // Overlaps the previous block's end.
        val next = timeline.map(event(12_000))
        assertTrue(next.values.all { it.first().startsNewSegment })
        timeline.reset()
        assertFalse(timeline.map(event(1_000)).isEmpty())
    }

    @Test fun highRatePreviewHasBoundedHistoryAndDoesNotClaimChartSkipsAreWireLoss() {
        val state = DeviceUiStateHolder()
        state.onV2PreviewConnecting()
        state.onV2DiscoveryReady(127, 2047)
        state.onV2LiveStarted()
        for (batch in 0 until 100) {
            val points = List(1_024) { index -> ChartPoint(batch * 1_024L + index, index.toFloat()) }
            state.onV2LivePreview(mapOf(ChartStreamKey(2, 1) to points), 4, 1, 2)
        }
        val field = DeviceUiStateHolder::class.java.getDeclaredField("chartHistory").apply { isAccessible = true }
        @Suppress("UNCHECKED_CAST")
        val history = field.get(state) as Map<ChartStreamKey, List<ChartPoint>>
        assertTrue(history.getValue(ChartStreamKey(2, 1)).size <= 6_000)
        assertEquals(400L, state.uiState.v2PreviewBlocks)
        assertEquals(100L, state.uiState.v2SequenceGaps)
        assertEquals(200L, state.uiState.v2ChartSkippedBlocks)
        assertEquals(0L, state.uiState.packetsLost) // Legacy capture statistics are separate.
    }

    @Test fun lateUiBatchAfterDisconnectCannotRevivePreviewOrChangeGraph() {
        val state = DeviceUiStateHolder()
        state.onV2PreviewConnecting()
        state.onV2DiscoveryReady(3, 2047)
        state.onV2LiveStarted()
        state.onSessionStateChanged(BleSessionState.DISCONNECTED)
        val before = state.uiState
        state.onV2LivePreview(mapOf(ChartStreamKey(2, 1) to listOf(ChartPoint(123, 42f))), 1, 1)
        assertEquals(before, state.uiState)
        assertEquals(V2PreviewStage.NONE, state.uiState.v2PreviewStage)
    }

    @Test fun explicitDisconnectClearsPreviewBeforeAnyGattCallbackSoOrdinaryRecordingCanStart() {
        val state = DeviceUiStateHolder()
        state.onV2PreviewConnecting()
        state.onV2DiscoveryReady(3, 2047)
        state.onV2LiveStarted()
        state.stopCaptureSession()
        state.prepareVideo()
        state.videoReady()
        state.onSessionStateChanged(BleSessionState.CONNECTED)
        assertFalse(state.uiState.v2DiscoveryRequested)
        assertFalse(state.uiState.v2LiveRunning)
        assertEquals(V2PreviewStage.NONE, state.uiState.v2PreviewStage)
        assertEquals(VideoCaptureState.READY, state.uiState.videoState)
    }

    @Test fun streamSelectionCannotChangeWhileStartOrStopAcknowledgementIsPending() {
        val state = DeviceUiStateHolder()
        state.onV2PreviewConnecting()
        state.onV2DiscoveryReady(127, 2047)
        val mask = state.uiState.v2SelectedStreamMask
        state.onV2StartRequested()
        state.toggleV2Stream(3)
        assertEquals(mask, state.uiState.v2SelectedStreamMask)
        state.onV2LiveStarted()
        state.onV2StopRequested()
        state.toggleV2Stream(3)
        assertEquals(mask, state.uiState.v2SelectedStreamMask)
        state.onV2LiveStopped()
        state.toggleV2Stream(3)
        assertEquals(mask or 4L, state.uiState.v2SelectedStreamMask)
    }
}
