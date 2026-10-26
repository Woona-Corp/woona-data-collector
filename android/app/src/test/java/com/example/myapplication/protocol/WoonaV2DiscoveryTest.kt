package com.example.myapplication.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WoonaV2DiscoveryTest {
    private fun inbound(type: Int, id: Long, payload: ByteArray): ByteArray =
        WoonaV2Codec.encodeWire(type, id, id, payload)

    private val helloPayload = byteArrayOf(2, 2, 0, 0, 0x7d, 0x04, 0, 0, 0x7f, 0, 0, 0, 0, 8, 0, 0)
    private val streamsPayload = byteArrayOf(0, 1, 8, 0, 1, 0, 0, 0, 1, 1, 3, 0, 0xe8.toByte(), 3, 0, 0)
    private val statusPayload = ByteArray(36).apply { this[1] = 1; this[32] = 80 }

    @Test fun negotiatesHelloStreamsAndStatusAcrossBleFragments() {
        val d = WoonaV2Discovery()
        val request = d.begin().bytes
        assertEquals(WoonaV2Codec.HELLO, WoonaV2Codec.decodeRaw(WoonaV2Codec.cobsDecode(request.dropLast(1).toByteArray())!!)!!.type)
        val response = inbound(WoonaV2Codec.HELLO_RESPONSE, 1, helloPayload)
        assertTrue(d.receive(response.copyOfRange(0, 10)).isEmpty())
        val events = d.receive(response.copyOfRange(10, response.size))
        assertEquals(1, events.size)
        assertEquals(WoonaV2Discovery.Phase.WAIT_STREAMS, d.phase)
        assertTrue(events.single() is WoonaV2Discovery.Event.Transmit)
        assertEquals(1, d.receive(inbound(WoonaV2Codec.STREAMS_RESPONSE, 2, streamsPayload)).size)
        val complete = d.receive(inbound(0x83, 3, statusPayload)).single() as WoonaV2Discovery.Event.Complete
        assertEquals(0x7fL, complete.device.hello.streamMask)
        assertEquals(1000L, complete.device.streams.descriptors.single().nativeRateHz)
        assertEquals(80, complete.device.status.batteryPercent)
        assertEquals(WoonaV2Discovery.Phase.READY, d.phase)
    }

    @Test fun ignoresWrongRequestIdsAndCorruptCrc() {
        val d = WoonaV2Discovery()
        d.begin()
        assertTrue(d.receive(inbound(WoonaV2Codec.HELLO_RESPONSE, 5, helloPayload)).isEmpty())
        val raw = WoonaV2Codec.encodeRaw(WoonaV2Codec.HELLO_RESPONSE, 1, 1, helloPayload)
        raw[5] = 0.toByte()
        assertTrue(d.receive(WoonaV2Codec.cobsEncode(raw) + byteArrayOf(0)).isEmpty())
        assertEquals(WoonaV2Discovery.Phase.WAIT_HELLO, d.phase)
    }

    @Test fun timeoutRetryPreservesExactlySameRequestBytesAndLimitsRetries() {
        val d = WoonaV2Discovery()
        val original = d.begin().bytes
        repeat(2) {
            val retry = d.onResponseTimeout() as WoonaV2Discovery.Event.Transmit
            assertTrue(original.contentEquals(retry.bytes))
        }
        assertTrue(d.onResponseTimeout() is WoonaV2Discovery.Event.Failure)
        assertEquals(WoonaV2Discovery.Phase.FAILED, d.phase)
        assertTrue(d.receive(inbound(WoonaV2Codec.HELLO_RESPONSE, 1, helloPayload)).isEmpty())
        d.resetForNewConnection()
        assertEquals(WoonaV2Discovery.Phase.IDLE, d.phase)
    }

    @Test fun unsupportedVersionFailsWithoutSilentLegacyFallback() {
        val d = WoonaV2Discovery()
        d.begin()
        val payload = helloPayload.clone().apply { this[0] = 3; this[1] = 3 }
        assertTrue(d.receive(inbound(WoonaV2Codec.HELLO_RESPONSE, 1, payload)).single() is WoonaV2Discovery.Event.Failure)
        assertEquals(WoonaV2Discovery.Phase.FAILED, d.phase)
    }
}
