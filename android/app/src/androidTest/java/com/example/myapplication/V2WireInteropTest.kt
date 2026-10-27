package com.example.myapplication

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.example.myapplication.protocol.WoonaV2Codec
import com.example.myapplication.protocol.WoonaV2StreamDecoder
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** The shared vectors were byte-checked against the actual firmware C encoder/decoder. */
@RunWith(AndroidJUnit4::class)
class V2WireInteropTest {
    private fun fixture() = JSONObject(
        InstrumentationRegistry.getInstrumentation().context.assets
            .open("woona-v2-wire-vectors.json").bufferedReader().use { it.readText() },
    )

    private fun String.hex(): ByteArray = chunked(2).map { it.toInt(16).toByte() }.toByteArray()

    @Test fun firmwareFramesMatchNativeCodecAndEveryBleFragmentSize() {
        val vectors = fixture()
        val frames = vectors.getJSONArray("frames")
        val fragmentSizes = vectors.getJSONArray("fragmentSizes")
        assertEquals(17, frames.length())
        for (index in 0 until frames.length()) {
            val row = frames.getJSONObject(index)
            val raw = row.getString("rawHex").hex()
            val wire = row.getString("wireHex").hex()
            val frame = requireNotNull(WoonaV2Codec.decodeRaw(raw)) { row.getString("name") }
            assertEquals(row.getInt("type"), frame.type)
            assertEquals(row.getLong("sequence"), frame.sequence)
            assertEquals(row.getLong("requestId"), frame.requestId)
            assertArrayEquals(row.getString("payloadHex").hex(), frame.payload)
            assertArrayEquals(raw, WoonaV2Codec.encodeRaw(frame.type, frame.sequence, frame.requestId, frame.payload, frame.flags))
            assertArrayEquals(wire, WoonaV2Codec.encodeWire(frame.type, frame.sequence, frame.requestId, frame.payload))
            for (fragmentIndex in 0 until fragmentSizes.length()) {
                val decoder = WoonaV2StreamDecoder()
                val decoded = wire.toList().chunked(fragmentSizes.getInt(fragmentIndex))
                    .flatMap { decoder.append(it.toByteArray()) }
                assertEquals(row.getString("name"), 1, decoded.size)
                assertArrayEquals(frame.payload, decoded.single().payload)
            }
        }
    }

    @Test fun corruptAndOversizedSegmentsDoNotPoisonTheNextFirmwareFrame() {
        val vectors = fixture()
        val invalid = vectors.getJSONArray("invalidFrames")
        val good = vectors.getJSONArray("frames").getJSONObject(1).getString("wireHex").hex()
        for (index in 0 until invalid.length()) {
            val row = invalid.getJSONObject(index)
            assertNull(row.getString("name"), WoonaV2Codec.decodeRaw(row.getString("rawHex").hex()))
            val decoder = WoonaV2StreamDecoder()
            assertTrue(decoder.append(row.getString("wireHex").hex()).isEmpty())
            assertEquals(1L, decoder.rejectedFrames)
            assertEquals(1, decoder.append(good).size)
            assertEquals(1L, decoder.rejectedFrames)
        }
        val decoder = WoonaV2StreamDecoder()
        assertTrue(decoder.append(ByteArray(WoonaV2Codec.MAX_RAW * 5) { 1 }).isEmpty())
        assertEquals(1L, decoder.rejectedFrames) // One corrupt segment, not one error per discarded byte.
        assertEquals(1, decoder.append(byteArrayOf(0) + good).size)
    }

    @Test fun deviceTimestampAboveDoublePrecisionRemainsExact() {
        val rows = fixture().getJSONArray("frames")
        val row = (0 until rows.length()).map(rows::getJSONObject)
            .first { it.getString("name") == "accel_data" }
        val frame = requireNotNull(WoonaV2Codec.decodeRaw(row.getString("rawHex").hex()))
        val data = requireNotNull(WoonaV2Codec.liveData(frame))
        assertEquals(9_007_199_254_740_993L, data.timestampUs)
        assertEquals(2, data.count)
        assertEquals(1000, data.rateHz)
        assertEquals(12, data.samples.size)
    }
}
