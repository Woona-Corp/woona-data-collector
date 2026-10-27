package com.example.myapplication.ble

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WoonaV2GattWriteQueueTest {
    @Test fun oversizedFrameIsRejectedBeforeRetainingAnyBytes() {
        val queue = WoonaV2GattWriteQueue()
        try {
            queue.begin(ByteArray(WoonaV2GattWriteQueue.MAX_FRAME_BYTES + 1), 23)
            org.junit.Assert.fail("Unbounded command accepted")
        } catch (_: IllegalArgumentException) { }
        assertFalse(queue.isBusy)
        assertArrayEquals(byteArrayOf(7), queue.begin(byteArrayOf(7), 23))
    }
    @Test fun mtu23SplitsAndAcknowledgesWithoutSkippingBytes() {
        val queue = WoonaV2GattWriteQueue()
        val wire = ByteArray(47) { it.toByte() }
        val chunks = mutableListOf<ByteArray>()
        chunks += queue.begin(wire, 23)
        assertTrue(queue.isBusy)
        chunks += requireNotNull(queue.acknowledgeChunk())
        assertEquals(20, chunks[0].size)
        assertEquals(20, chunks[1].size)
        chunks += requireNotNull(queue.acknowledgeChunk())
        assertEquals(7, chunks[2].size)
        assertEquals(null, queue.acknowledgeChunk())
        assertFalse(queue.isBusy)
        assertArrayEquals(wire, chunks.fold(ByteArray(0)) { result, chunk -> result + chunk })
    }

    @Test fun mtu247WritesShortFrameInOneTransaction() {
        val queue = WoonaV2GattWriteQueue()
        val wire = ByteArray(26) { it.toByte() }
        assertArrayEquals(wire, queue.begin(wire, 247))
        assertEquals(null, queue.acknowledgeChunk())
        assertFalse(queue.isBusy)
    }

    @Test fun resetDiscardsPartiallyWrittenFrame() {
        val queue = WoonaV2GattWriteQueue()
        queue.begin(ByteArray(42), 23)
        queue.reset()
        assertFalse(queue.isBusy)
        assertArrayEquals(byteArrayOf(7), queue.begin(byteArrayOf(7), 23))
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsInvalidMtu() {
        WoonaV2GattWriteQueue().begin(byteArrayOf(1), 22)
    }

    @Test(expected = IllegalArgumentException::class)
    fun doesNotAllowConcurrentFrameWrites() {
        WoonaV2GattWriteQueue().apply {
            begin(byteArrayOf(1), 23)
            begin(byteArrayOf(2), 23)
        }
    }
}
