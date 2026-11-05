package com.example.myapplication.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.nio.file.Files
import java.io.ByteArrayInputStream

class RecordedPacketFileParserTest {
    private val parser = RecordedPacketFileParser()

    @Test
    fun splitIntoPackets_returnsSequentialPacketsFromDump() {
        val first = testPacket(length = 16, counter = 1)
        val second = testPacket(length = 18, counter = 2)

        val packets = parser.splitIntoPackets(first + second)

        assertEquals(2, packets.size)
        assertArrayEquals(first, packets[0])
        assertArrayEquals(second, packets[1])
    }

    @Test(expected = IllegalArgumentException::class)
    fun splitIntoPackets_rejectsTruncatedPacket() {
        parser.splitIntoPackets(testPacket(length = 18, counter = 1).copyOf(17))
    }

    @Test
    fun forEachPacket_streamsSequentialPacketsFromFile() {
        val first = testPacket(length = 16, counter = 1)
        val second = testPacket(length = 18, counter = 2)
        val packetFile = Files.createTempFile("packet-dump", ".bin").toFile().apply {
            writeBytes(first + second)
        }
        val packets = mutableListOf<ByteArray>()

        parser.forEachPacket(packetFile) { packetBytes ->
            packets += packetBytes
        }

        assertEquals(2, packets.size)
        assertArrayEquals(first, packets[0])
        assertArrayEquals(second, packets[1])
    }

    @Test
    fun arrayAndStreamReportTheSameMalformedPacketAndOffset() {
        val prefix = testPacket(length = 16, counter = 1)
        val malformed = listOf(
            testPacket(length = 18, counter = 2).copyOf(10) to "Truncated packet header at offset 16",
            testPacket(length = 18, counter = 2).copyOf(17) to "Truncated packet body at offset 16: expected 18 bytes",
            testPacket(length = 16, counter = 2).apply { this[0] = 0 } to "Invalid packet start marker at offset 16",
            testPacket(length = 16, counter = 2).apply { this[4] = 1 } to "Invalid packet length 1 at offset 16",
        )
        for ((tail, expected) in malformed) {
            val bytes = prefix + tail
            val arrayFailure = assertThrows(IllegalArgumentException::class.java) {
                parser.forEachPacket(bytes) {}
            }
            val streamFailure = assertThrows(IllegalArgumentException::class.java) {
                parser.forEachPacket(ByteArrayInputStream(bytes)) {}
            }
            assertEquals(expected, arrayFailure.message)
            assertEquals(expected, streamFailure.message)
        }
    }

    @Test
    fun streamingAcceptsShortReadsWithoutLoadingTheWholeSource() {
        val first = testPacket(length = 16, counter = 1)
        val second = testPacket(length = 128, counter = 2)
        val input = object : ByteArrayInputStream(first + second) {
            override fun read(bytes: ByteArray, offset: Int, length: Int): Int =
                super.read(bytes, offset, minOf(length, 3))
        }
        val packets = mutableListOf<ByteArray>()
        parser.forEachPacket(input) { packets += it }
        assertEquals(2, packets.size)
        assertArrayEquals(first, packets[0])
        assertArrayEquals(second, packets[1])
    }

    private fun testPacket(
        length: Int,
        counter: Int,
    ): ByteArray {
        return ByteArray(length).apply {
            this[0] = 0x33
            this[1] = 0x99.toByte()
            this[2] = 0xAA.toByte()
            this[3] = 0x55
            this[4] = (length and 0xFF).toByte()
            this[5] = ((length shr 8) and 0xFF).toByte()
            this[6] = 1
            this[7] = (counter and 0xFF).toByte()
            this[8] = ((counter shr 8) and 0xFF).toByte()
            this[9] = ((counter shr 16) and 0xFF).toByte()
            this[10] = ((counter shr 24) and 0xFF).toByte()
        }
    }
}
