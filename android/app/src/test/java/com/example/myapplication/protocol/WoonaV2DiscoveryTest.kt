package com.example.myapplication.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WoonaV2DiscoveryTest {
    private fun inbound(type: Int, id: Long, payload: ByteArray): ByteArray =
        WoonaV2Codec.encodeWire(type, id, id, payload)

    private val helloPayload = byteArrayOf(2, 2, 0, 0, 0x7d, 0x04, 0, 0, 1, 0, 0, 0, 0, 8, 0, 0)
    private val streamsPayload = byteArrayOf(0, 1, 8, 0, 1, 0, 0, 0, 1, 1, 3, 0, 0xe8.toByte(), 3, 0, 0)
    private val statusPayload = ByteArray(36).apply { this[1] = 1; this[3] = 1; this[12] = 1; this[32] = 80 }

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
        assertEquals(1L, complete.device.hello.streamMask)
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

    @Test fun matchingGenericErrorFailsImmediatelyAtEveryDiscoveryStage() {
        for (stage in 1..3) {
            val d = WoonaV2Discovery(); d.begin()
            if (stage >= 2) d.receive(inbound(WoonaV2Codec.HELLO_RESPONSE, 1, helloPayload))
            if (stage >= 3) d.receive(inbound(WoonaV2Codec.STREAMS_RESPONSE, 2, streamsPayload))
            // A request ID alone cannot correlate an error for another command.
            assertTrue(d.receive(inbound(0xff, stage.toLong(), byteArrayOf(4, 9, 0, 0))).isEmpty())
            val events = d.receive(inbound(0xff, stage.toLong(), byteArrayOf(4, stage.toByte(), 0, 0)))
            assertTrue(events.single() is WoonaV2Discovery.Event.Failure)
            assertTrue((events.single() as WoonaV2Discovery.Event.Failure).reason.contains("device busy"))
            assertEquals(WoonaV2Discovery.Phase.FAILED, d.phase)
        }
    }

    @Test fun requiredCapabilitiesAndDescriptorMaskAreValidatedBeforeReady() {
        for (bit in listOf(0, 2, 3, 4, 5)) {
            val d = WoonaV2Discovery(); d.begin()
            val payload = helloPayload.clone()
            payload[4] = (payload[4].toInt() and (1 shl bit).inv()).toByte()
            assertTrue(d.receive(inbound(0x81, 1, payload)).single() is WoonaV2Discovery.Event.Failure)
        }
        val d = WoonaV2Discovery(); d.begin(); d.receive(inbound(0x81, 1, helloPayload))
        val bad = streamsPayload.clone().apply { this[4] = 3 }
        assertTrue(d.receive(inbound(0x82, 2, bad)).single() is WoonaV2Discovery.Event.Failure)
    }

    @Test fun busyStorageStatusAndStatusErrorsNeverPretendLiveReady() {
        for ((mode, size) in listOf(1 to 36, 2 to 36, 1 to 48, 2 to 48)) {
            val d = WoonaV2Discovery(); d.begin(); d.receive(inbound(0x81, 1, helloPayload))
            d.receive(inbound(0x82, 2, streamsPayload))
            val busy = statusPayload.copyOf(size).apply {
                this[2] = mode.toByte(); this[4] = 77; this[8] = 1
                if (size == 48) this[36] = 2
            }
            val failure = d.receive(inbound(0x83, 3, busy)).single() as WoonaV2Discovery.Event.Failure
            assertTrue(failure.reason.contains("busy"))
            assertEquals(WoonaV2Discovery.Phase.FAILED, d.phase)
        }
        val d = WoonaV2Discovery(); d.begin(); d.receive(inbound(0x81, 1, helloPayload))
        d.receive(inbound(0x82, 2, streamsPayload))
        val failed = statusPayload.clone().apply { this[0] = 8 }
        assertTrue(d.receive(inbound(0x83, 3, failed)).single() is WoonaV2Discovery.Event.Failure)
    }
}
