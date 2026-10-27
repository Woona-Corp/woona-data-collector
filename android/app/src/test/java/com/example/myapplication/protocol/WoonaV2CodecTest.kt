package com.example.myapplication.protocol

import org.junit.Assert.*
import org.junit.Test
import kotlin.random.Random

class WoonaV2CodecTest {
    @Test fun helloRoundTripAcrossArbitraryBleBoundaries() {
        val hello = byteArrayOf(2, 2, 0, 0, 0x7d, 0x04, 0, 0, 0x7f, 0, 0, 0, 0, 8, 0, 0)
        val wire = WoonaV2Codec.encodeWire(WoonaV2Codec.HELLO_RESPONSE, 1, 77, hello)
        val decoder = WoonaV2StreamDecoder()
        val frames = wire.map { decoder.append(byteArrayOf(it)) }.flatten()
        assertEquals(1, frames.size)
        assertEquals(77L, frames.single().requestId)
        val parsed = WoonaV2Codec.hello(frames.single())!!
        assertEquals(2, parsed.versionMin)
        assertEquals(2048, parsed.maxPayload)
        assertEquals(0x7fL, parsed.streamMask)
        assertTrue(parsed.hasCapability(0))
        assertFalse(parsed.hasCapability(1))
    }

    @Test fun crcCorruptionIsRejectedAndNextFrameSurvives() {
        val valid = WoonaV2Codec.encodeWire(WoonaV2Codec.HELLO, 2, 3)
        val corrupt = WoonaV2Codec.encodeRaw(WoonaV2Codec.HELLO, 1, 3)
        corrupt[12] = (corrupt[12].toInt() xor 1).toByte()
        val stream = WoonaV2Codec.cobsEncode(corrupt) + byteArrayOf(0) + valid
        val frames = WoonaV2StreamDecoder().append(stream)
        assertEquals(1, frames.size)
        assertEquals(2L, frames.single().sequence)
    }

    @Test fun cobsRoundTripHandlesZerosAndLongNonzeroRuns() {
        val source = ByteArray(700) { if (it % 127 == 0) 0 else 0x55 }
        assertArrayEquals(source, WoonaV2Codec.cobsDecode(WoonaV2Codec.cobsEncode(source)))
        assertNull(WoonaV2Codec.cobsDecode(byteArrayOf(2)))
    }

    @Test fun malformedAndOversizedFramesResynchronize() {
        val decoder = WoonaV2StreamDecoder()
        val good = WoonaV2Codec.encodeWire(WoonaV2Codec.GET_STREAMS, 9, 11)
        val noise = ByteArray(4000) { 1 } + byteArrayOf(0, 0)
        assertEquals(1, decoder.append(noise + good).size)
        assertTrue(decoder.append(byteArrayOf(0, 0)).isEmpty())
    }

    @Test fun parsesStreamDescriptorsAndLiveHeader() {
        val descriptors = byteArrayOf(0, 1, 8, 0, 1, 0, 0, 0, 1, 1, 3, 0, 0xe8.toByte(), 3, 0, 0)
        val s = WoonaV2Codec.streams(WoonaV2Codec.decodeRaw(WoonaV2Codec.encodeRaw(WoonaV2Codec.STREAMS_RESPONSE, 1, 1, descriptors))!!)!!
        assertEquals(1000L, s.descriptors.single().nativeRateHz)
        val data = ByteArray(24 + 6)
        data[4] = 1; data[8] = 1; data[10] = 0xfa.toByte(); data[11] = 0
        val f = WoonaV2Codec.decodeRaw(WoonaV2Codec.encodeRaw(WoonaV2Codec.DATA, 2, 0, data))!!
        assertEquals(6, WoonaV2Codec.liveData(f)!!.samples.size)
    }

    @Test fun descriptorsRejectAliasedIdsInvalidLayoutsZeroRatesAndMaskDisagreement() {
        val valid = V2Streams(0, 1, listOf(V2Stream(1, 1, 3, 1000)))
        assertTrue(WoonaV2Codec.validStreams(valid))
        for (bad in listOf(V2Stream(0, 1, 3, 1000), V2Stream(33, 1, 3, 1000),
            V2Stream(1, 0, 3, 1000), V2Stream(1, 2, 3, 1000), V2Stream(1, 1, 0, 1000),
            V2Stream(1, 1, 1, 1000), V2Stream(1, 1, 17, 1000), V2Stream(1, 1, 3, 0))) {
            assertFalse(bad.toString(), WoonaV2Codec.validStreams(valid.copy(descriptors = listOf(bad))))
        }
        assertFalse(WoonaV2Codec.validStreams(valid.copy(descriptors = valid.descriptors + valid.descriptors)))
        assertFalse(WoonaV2Codec.validStreams(valid.copy(streamMask = 3)))
        assertFalse(WoonaV2Codec.validStreams(V2Streams(0, 0, emptyList())))
        assertTrue(WoonaV2Codec.validStreams(V2Streams(0, 0x8000_0000L, listOf(V2Stream(32, 1, 16, 8000)))))
        assertTrue(WoonaV2Codec.validStreams(V2Streams(0, 0x60, listOf(V2Stream(6, 1, 1, 1), V2Stream(7, 1, 1, 1)))))
    }

    @Test fun boundedFuzzAndMaximumFramesResynchronizeWithoutUnboundedAllocation() {
        val random = Random(27012026)
        repeat(1000) {
            val bytes = random.nextBytes(random.nextInt(WoonaV2Codec.MAX_RAW + 1))
            val encoded = WoonaV2Codec.cobsEncode(bytes)
            assertTrue(encoded.size <= WoonaV2Codec.MAX_ENCODED)
            assertArrayEquals(bytes, WoonaV2Codec.cobsDecode(encoded))
            WoonaV2Codec.cobsDecode(random.nextBytes(random.nextInt(WoonaV2Codec.MAX_ENCODED + 1)))
        }
        val wire = WoonaV2Codec.encodeWire(WoonaV2Codec.DATA, 0xffff_ffffL, 0,
            ByteArray(WoonaV2Codec.MAX_PAYLOAD) { 0x55 })
        assertTrue(wire.size <= WoonaV2Codec.MAX_ENCODED + 1)
        for (size in listOf(1, 2, 7, 20, 185)) {
            val decoder = WoonaV2StreamDecoder()
            val frames = wire.asList().chunked(size).flatMap { decoder.append(it.toByteArray()) }
            assertEquals(1, frames.size)
            assertEquals(WoonaV2Codec.MAX_PAYLOAD, frames.single().payload.size)
            assertEquals(0xffff_ffffL, frames.single().sequence)
        }
        assertNull(WoonaV2Codec.cobsDecode(ByteArray(WoonaV2Codec.MAX_ENCODED + 1) { 1 }))
        try { WoonaV2Codec.cobsEncode(ByteArray(WoonaV2Codec.MAX_RAW + 1)); fail("oversize raw") }
        catch (_: IllegalArgumentException) { }
        val decoder = WoonaV2StreamDecoder()
        assertTrue(decoder.append(ByteArray(1_000_000) { 1 }).isEmpty())
        assertEquals(1, decoder.append(byteArrayOf(0) + wire).size)
    }
}
