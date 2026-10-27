package com.example.myapplication.feature.device

import com.example.myapplication.protocol.V2LiveData
import com.example.myapplication.protocol.V2Stream
import com.example.myapplication.protocol.WoonaV2LiveSession
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WoonaV2ChartMapperTest {
    private fun samples(
        id: Int = 1,
        channels: Int = 3,
        format: Int = 1,
        sampleCount: Int = 2,
        rateHz: Int = 1000,
        timestampUs: Long = 1_000_000L,
        flags: Int = 1,
        sequenceGap: Boolean = false,
        values: IntArray = intArrayOf(-1, 2, -3, 4, -5, 6),
    ): WoonaV2LiveSession.Event.Samples {
        val bytes = ByteArray(values.size * 2)
        values.forEachIndexed { index, value ->
            bytes[index * 2] = value.toByte()
            bytes[index * 2 + 1] = (value ushr 8).toByte()
        }
        return WoonaV2LiveSession.Event.Samples(
            frameSequence = 8,
            block = V2LiveData(99, id, flags, sampleCount, rateHz, 1, timestampUs, bytes),
            descriptor = V2Stream(id, format, channels, 1000),
            sequenceGap = sequenceGap,
        )
    }

    @Test fun interleavedSignedAxesAndTimestamps() {
        val result = WoonaV2ChartMapper.map(samples())
        assertEquals(listOf(-1f, 4f), result[ChartStreamKey(2, 1)]?.map { it.value })
        assertEquals(listOf(2f, -5f), result[ChartStreamKey(2, 2)]?.map { it.value })
        assertEquals(listOf(-3f, 6f), result[ChartStreamKey(2, 3)]?.map { it.value })
        assertEquals(listOf(1000L, 1001L), result[ChartStreamKey(2, 1)]?.map { it.timeMillis })
    }

    @Test fun unsignedPiezoAndGap() {
        val result = WoonaV2ChartMapper.map(samples(id = 5, channels = 1, format = 2,
            values = intArrayOf(65535, 40000), sequenceGap = true))
        val points = requireNotNull(result[ChartStreamKey(6, 1)])
        assertEquals(listOf(65535f, 40000f), points.map { it.value })
        assertTrue(points[0].startsNewSegment)
        assertFalse(points[1].startsNewSegment)
    }

    @Test fun invalidTimestampFlagProducesNoPreview() {
        assertTrue(WoonaV2ChartMapper.map(samples(flags = 0)).isEmpty())
    }

    @Test fun bothTemperaturesStaySignedRawCountsWithoutInventedCelsiusConversion() {
        for ((stream, sensor) in listOf(6 to 7, 7 to 8)) {
            val result = WoonaV2ChartMapper.map(samples(id = stream, channels = 1, rateHz = 1,
                values = intArrayOf(-128, 3200), flags = 3))
            val points = requireNotNull(result[ChartStreamKey(sensor, 1)])
            assertEquals(listOf(-128f, 3200f), points.map { it.value })
            assertEquals(listOf(1000L, 2000L), points.map { it.timeMillis })
            assertTrue(points.first().startsNewSegment)
            assertFalse(points.last().startsNewSegment)
            assertTrue(WoonaV2ChartMapper.map(samples(id = stream, channels = 1, format = 2,
                values = intArrayOf(65535, 3000))).isEmpty())
        }
    }

    @Test fun decimatesLargeBlocks() {
        val count = 400
        val result = WoonaV2ChartMapper.map(samples(id = 3, channels = 1, sampleCount = count,
            values = IntArray(count) { it }))
        val points = requireNotNull(result[ChartStreamKey(4, 1)])
        assertTrue(points.size <= WoonaV2ChartMapper.MAX_PREVIEW_INSTANTS_PER_BLOCK)
        assertEquals(0f, points.first().value)
    }

    @Test fun rejectsInvalidLengthAndLeavesLegacyUnchanged() {
        assertTrue(WoonaV2ChartMapper.map(samples(values = intArrayOf(1, 2))).isEmpty())
    }
}
