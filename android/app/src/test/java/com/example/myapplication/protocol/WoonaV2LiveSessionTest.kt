package com.example.myapplication.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WoonaV2LiveSessionTest {
    private val streams = V2Streams(
        status = 0,
        streamMask = 0x03L,
        descriptors = listOf(V2Stream(1, 1, 3, 1000), V2Stream(2, 1, 3, 1000)),
    )

    private fun startResponse(id: Long = 42, mask: Long = 3, status: Int = 0): V2Frame {
        val p = ByteBuffer.allocate(24).order(ByteOrder.LITTLE_ENDIAN)
            .put(status.toByte()).put(1).putShort(0).putInt(id.toInt())
            .putInt(mask.toInt()).putInt(0).putLong(0).array()
        return V2Frame(0x84, 0, 100, 4, p)
    }

    private fun stopResponse(id: Long = 42): V2Frame = V2Frame(0x85, 0, 105, 5,
        ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN)
            .put(0).put(0).putShort(0).putInt(id.toInt()).array())

    private fun data(streamSequence: Long, sessionId: Long = 42, sampleCount: Int = 2,
                     sampleBytes: ByteArray = ByteArray(sampleCount * 6)): V2Frame {
        val p = ByteBuffer.allocate(24 + sampleBytes.size).order(ByteOrder.LITTLE_ENDIAN)
            .putInt(sessionId.toInt()).put(1).put(0).putShort(1)
            .putShort(sampleCount.toShort()).putShort(250)
            .putInt(streamSequence.toInt()).putLong(1200000)
            .put(sampleBytes).array()
        return V2Frame(WoonaV2Codec.DATA, 0, 107 + streamSequence, 0, p)
    }

    @Test fun startStopAndDataFlow() {
        val session = WoonaV2LiveSession(streams)
        val request = session.start(3)
        val frame = WoonaV2Codec.decodeRaw(requireNotNull(WoonaV2Codec.cobsDecode(request.bytes.dropLast(1).toByteArray())))!!
        assertEquals(WoonaV2Codec.START_SESSION, frame.type)
        assertEquals(12, frame.payload.size)
        assertEquals(4L, frame.requestId)
        assertEquals(3L, ByteBuffer.wrap(frame.payload).order(ByteOrder.LITTLE_ENDIAN).getInt(4).toLong())
        assertEquals(WoonaV2LiveSession.Phase.WAIT_START, session.phase)
        assertEquals(WoonaV2LiveSession.Event.Started(42, 3), session.receive(startResponse()).single())
        assertEquals(WoonaV2LiveSession.Phase.RUNNING, session.phase)
        val first = session.receive(data(1)).single() as WoonaV2LiveSession.Event.Samples
        assertFalse(first.sequenceGap)
        assertEquals(2, first.block.count)
        assertFalse((session.receive(data(2)).single() as WoonaV2LiveSession.Event.Samples).sequenceGap)
        assertTrue((session.receive(data(4)).single() as WoonaV2LiveSession.Event.Samples).sequenceGap)
        val stop = session.stop()
        val stopRaw = WoonaV2Codec.decodeRaw(requireNotNull(WoonaV2Codec.cobsDecode(stop.bytes.dropLast(1).toByteArray())))!!
        assertEquals(WoonaV2Codec.STOP_SESSION, stopRaw.type)
        assertEquals(5L, stopRaw.requestId)
        assertEquals(42L, ByteBuffer.wrap(stopRaw.payload).order(ByteOrder.LITTLE_ENDIAN).int.toLong())
        assertEquals(WoonaV2LiveSession.Event.Stopped(42), session.receive(stopResponse()).single())
        assertEquals(WoonaV2LiveSession.Phase.STOPPED, session.phase)
        // A late DATA frame belonging to the stopped session must not be dropped.
        assertEquals(1, session.receive(data(5)).size)
        assertTrue(session.receive(data(6, sessionId = 777)).isEmpty())
    }

    @Test fun rejectMalformedOrDifferentSessionData() {
        val session = WoonaV2LiveSession(streams)
        session.start(1)
        session.receive(startResponse(mask = 1))
        assertTrue(session.receive(data(1, sessionId = 200)).isEmpty())
        assertTrue(session.receive(data(1, sampleBytes = ByteArray(8))).isEmpty())
        assertTrue(session.receive(data(1, sampleCount = 0)).isEmpty())
        assertFalse((session.receive(data(1)).single() as WoonaV2LiveSession.Event.Samples).sequenceGap)
    }

    @Test fun exactByteRetryAndTimeoutFailure() {
        val session = WoonaV2LiveSession(streams)
        val first = session.start(1)
        repeat(2) {
            val retry = session.onResponseTimeout() as WoonaV2LiveSession.Event.Transmit
            assertArrayEquals(first.bytes, retry.bytes)
        }
        assertTrue(session.onResponseTimeout() is WoonaV2LiveSession.Event.Failure)
        assertEquals(WoonaV2LiveSession.Phase.FAILED, session.phase)
    }

    @Test fun rejectsUnsupportedMaskAndFailedStartResponse() {
        val session = WoonaV2LiveSession(streams)
        try { session.start(8); throw AssertionError("expected exception") }
        catch (_: IllegalArgumentException) { }
        session.start(3)
        assertTrue(session.receive(startResponse(status = 4)).single() is WoonaV2LiveSession.Event.Failure)
        assertEquals(WoonaV2LiveSession.Phase.FAILED, session.phase)
    }

    @Test fun retryDoesNotConfuseUnrelatedResponseIds() {
        val session = WoonaV2LiveSession(streams)
        session.start(3)
        assertTrue(session.receive(startResponse().copy(requestId = 1)).isEmpty())
        assertEquals(WoonaV2LiveSession.Phase.WAIT_START, session.phase)
        assertEquals(WoonaV2LiveSession.Event.Started(42, 3), session.receive(startResponse()).single())
    }
}
