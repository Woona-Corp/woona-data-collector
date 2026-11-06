package com.example.myapplication.protocol

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PacketAssemblerTest {
    @Test
    fun completedPacket_isFramingOnlyWithoutDiscardedDecodedSamples() {
        assertTrue("Only validation owns decoded samples",
            CompletedPacket::class.java.declaredFields.none { it.name == "sensorBlocks" })
    }

    @Test
    fun append_emitsPacketWhenWholePacketArrives() {
        val assembler = PacketAssembler()
        val packet = testPacket(counter = 7)

        val packets = assembler.append(packet)

        assertEquals(1, packets.size)
        val completed = packets.single() as PacketAssemblyResult.Completed
        assertArrayEquals(packet, completed.packet.bytes)
        assertEquals(7L, completed.packet.counter)
    }

    @Test
    fun append_reassemblesFragmentsAcrossChunks() {
        val assembler = PacketAssembler()
        val packet = testPacket(counter = 42, payloadSize = 8)

        val firstHalf = assembler.append(packet.copyOfRange(0, 10))
        val secondHalf = assembler.append(packet.copyOfRange(10, packet.size))

        assertTrue(firstHalf.isEmpty())
        assertEquals(1, secondHalf.size)
        val completed = secondHalf.single() as PacketAssemblyResult.Completed
        assertArrayEquals(packet, completed.packet.bytes)
        assertEquals(42L, completed.packet.counter)
    }

    @Test
    fun append_discardsLeadingGarbageBeforeHeader() {
        val assembler = PacketAssembler()
        val packet = testPacket(counter = 99)
        val chunk = byteArrayOf(0x00, 0x11, 0x22) + packet

        val packets = assembler.append(chunk)

        assertEquals(1, packets.size)
        assertArrayEquals(packet, (packets.single() as PacketAssemblyResult.Completed).packet.bytes)
    }

    @Test
    fun append_emitsMultiplePacketsFromSingleChunk() {
        val assembler = PacketAssembler()
        val first = testPacket(counter = 1)
        val second = testPacket(counter = 2, payloadSize = 4)

        val packets = assembler.append(first + second)

        assertEquals(
            listOf(1L, 2L),
            packets.map { (it as PacketAssemblyResult.Completed).packet.counter },
        )
    }

    @Test
    fun append_skipsMalformedLengthAndResynchronizes() {
        val assembler = PacketAssembler()
        val malformed = byteArrayOf(
            0x33,
            0x99.toByte(),
            0xAA.toByte(),
            0x55,
            0x01,
            0x00,
        ) + ByteArray(10)
        val valid = testPacket(counter = 5)

        val packets = assembler.append(malformed + valid)

        assertEquals(1, packets.size)
        val completed = packets.single() as PacketAssemblyResult.Completed
        assertEquals(5L, completed.packet.counter)
        assertArrayEquals(valid, completed.packet.bytes)
    }

    @Test
    fun append_preservesSensorBlockBytesForValidation() {
        val assembler = PacketAssembler()
        val packet = testPacket(
            counter = 12,
            measurementCount = 1,
            blocks = listOf(
                sensorBlock(
                    sensorType = 2,
                    channelSamples = listOf(
                        listOf(10, 20),
                        listOf(30, 40),
                    ),
                ),
            ),
        )

        val completedPacket = (assembler.append(packet).single() as PacketAssemblyResult.Completed).packet

        assertArrayEquals(packet, completedPacket.bytes)
        val validated = PacketValidator().validate(completedPacket.bytes) as PacketValidationResult.Accepted
        assertEquals(listOf(30f, 40f), validated.packet.channelSamples(sensorType = 2, channel = 2))
    }

    @Test
    fun reset_discardsBufferedFragmentsFromPreviousSession() {
        val assembler = PacketAssembler()
        val packet = testPacket(counter = 42, payloadSize = 8)

        val firstHalf = assembler.append(packet.copyOfRange(0, 10))
        assembler.reset()
        val secondHalf = assembler.append(packet.copyOfRange(10, packet.size))

        assertTrue(firstHalf.isEmpty())
        assertTrue(secondHalf.isEmpty())
    }

    @Test
    fun append_rejectsOverlappingPacketStartAtChunkBoundary() {
        val assembler = PacketAssembler()
        val first = testPacket(
            counter = 1,
            measurementCount = 1,
            blocks = listOf(sensorBlock(sensorType = 2, channelSamples = listOf(listOf(10, 20)))),
        )
        val second = testPacket(
            counter = 2,
            measurementCount = 1,
            blocks = listOf(sensorBlock(sensorType = 2, channelSamples = listOf(listOf(30, 40)))),
        )

        val firstChunk = assembler.append(first.copyOfRange(0, 20))
        val secondChunk = assembler.append(second)

        assertTrue(firstChunk.isEmpty())
        assertEquals(2, secondChunk.size)
        assertEquals(
            PacketAssemblyFailureReason.OVERLAPPING_PACKET_START,
            (secondChunk.first() as PacketAssemblyResult.Rejected).reason,
        )
        assertNotNull((secondChunk.first() as PacketAssemblyResult.Rejected).diagnostic)
        val completed = secondChunk.last() as PacketAssemblyResult.Completed
        assertEquals(2L, completed.packet.counter)
        assertArrayEquals(second, completed.packet.bytes)
    }

    @Test
    fun append_rejectsOverlappingPacketAfterShortBoundaryFragment() {
        val assembler = PacketAssembler()
        val first = testPacket(
            counter = 1,
            measurementCount = 1,
            blocks = listOf(sensorBlock(sensorType = 2, channelSamples = listOf(listOf(10, 20)))),
        )
        val second = testPacket(
            counter = 2,
            measurementCount = 1,
            blocks = listOf(sensorBlock(sensorType = 2, channelSamples = listOf(listOf(30, 40)))),
        )

        val firstChunk = assembler.append(first.copyOfRange(0, 20))
        val overlapPrefix = assembler.append(second.copyOfRange(0, 8))
        val overlapRemainder = assembler.append(second.copyOfRange(8, second.size))

        assertTrue(firstChunk.isEmpty())
        assertTrue(overlapPrefix.isEmpty())
        assertEquals(2, overlapRemainder.size)
        assertEquals(
            PacketAssemblyFailureReason.OVERLAPPING_PACKET_START,
            (overlapRemainder.first() as PacketAssemblyResult.Rejected).reason,
        )
        val completed = overlapRemainder.last() as PacketAssemblyResult.Completed
        assertEquals(2L, completed.packet.counter)
        assertArrayEquals(second, completed.packet.bytes)
    }

    @Test
    fun append_recoversWhenNextHeaderAppearsInsideIncompleteNotificationStream() {
        val assembler = PacketAssembler()
        val first = testPacket(
            counter = 10,
            measurementCount = 1,
            blocks = listOf(sensorBlock(sensorType = 2, channelSamples = listOf(listOf(1, 2, 3, 4, 5, 6, 7, 8)))),
        )
        val second = testPacket(
            counter = 12,
            measurementCount = 1,
            blocks = listOf(sensorBlock(sensorType = 2, channelSamples = listOf(listOf(9, 10)))),
        )
        val firstPrefix = first.copyOfRange(0, first.size - 16)

        assertTrue(assembler.append(firstPrefix + second.copyOfRange(0, 16)).isEmpty())

        val results = assembler.append(second.copyOfRange(16, second.size))

        assertEquals(2, results.size)
        val rejection = results.first() as PacketAssemblyResult.Rejected
        assertEquals(PacketAssemblyFailureReason.OVERLAPPING_PACKET_START, rejection.reason)
        assertEquals(16, requireNotNull(rejection.diagnostic).missingBytes)
        assertEquals(12L, (results.last() as PacketAssemblyResult.Completed).packet.counter)
    }

    @Test
    fun append_keepsIncompletePacketWhenBoundaryHeaderPrefixTurnsOutInvalid() {
        val assembler = PacketAssembler()
        val packet = testPacket(
            counter = 3,
            measurementCount = 1,
            payloadBytes = byteArrayOf(
                0x33,
                0x99.toByte(),
                0x10,
                0x20,
                0x30,
                0x40,
                0x50,
                0x60,
            ),
        )

        val firstChunk = assembler.append(packet.copyOfRange(0, 16))
        val ambiguousPrefix = assembler.append(packet.copyOfRange(16, 18))
        val completedChunk = assembler.append(packet.copyOfRange(18, packet.size))

        assertTrue(firstChunk.isEmpty())
        assertTrue(ambiguousPrefix.isEmpty())
        assertEquals(1, completedChunk.size)
        val completed = completedChunk.single() as PacketAssemblyResult.Completed
        assertEquals(3L, completed.packet.counter)
        assertArrayEquals(packet, completed.packet.bytes)
    }

    @Test
    fun append_keepsIncompletePacketWhenBoundaryHeaderLacksValidSensorBlocks() {
        val assembler = PacketAssembler()
        val packet = testPacket(
            counter = 4,
            measurementCount = 1,
            payloadBytes = byteArrayOf(
                0x33,
                0x99.toByte(),
                0xAA.toByte(),
                0x55,
                0x10,
                0x00,
                0x01,
                0x01,
                0x00,
                0x00,
                0x00,
                0x00,
                0x00,
                0x00,
                0x00,
                0x00,
            ),
        )

        val firstChunk = assembler.append(packet.copyOfRange(0, 16))
        val candidateChunk = assembler.append(packet.copyOfRange(16, packet.size))

        assertTrue(firstChunk.isEmpty())
        assertEquals(1, candidateChunk.size)
        val completed = candidateChunk.single() as PacketAssemblyResult.Completed
        assertEquals(4L, completed.packet.counter)
        assertArrayEquals(packet, completed.packet.bytes)
    }

    @Test
    fun append_keepsIncompletePacketWhenBoundaryHeaderDoesNotAdvanceCounterOrTimer() {
        val assembler = PacketAssembler()
        val nestedPacket = testPacket(
            counter = 5,
            timerMillis = 100,
            measurementCount = 1,
            blocks = listOf(sensorBlock(sensorType = 2, channelSamples = listOf(listOf(10, 20)))),
        )
        val packet = testPacket(
            counter = 5,
            timerMillis = 100,
            measurementCount = 1,
            payloadBytes = nestedPacket,
        )

        val firstChunk = assembler.append(packet.copyOfRange(0, 16))
        val boundaryCandidate = assembler.append(packet.copyOfRange(16, packet.size))

        assertTrue(firstChunk.isEmpty())
        assertEquals(1, boundaryCandidate.size)
        val completed = boundaryCandidate.single() as PacketAssemblyResult.Completed
        assertEquals(5L, completed.packet.counter)
        assertArrayEquals(packet, completed.packet.bytes)
    }

    private fun testPacket(
        counter: Int,
        timerMillis: Int = counter,
        payloadSize: Int = 0,
        measurementCount: Int = 0,
        blocks: List<ByteArray> = emptyList(),
        payloadBytes: ByteArray? = null,
    ): ByteArray {
        val blockPayload = blocks.fold(ByteArray(0)) { acc, block -> acc + block }
        val resolvedPayload = when {
            payloadBytes != null -> payloadBytes
            blocks.isNotEmpty() -> blockPayload
            else -> ByteArray(payloadSize) { index -> (index + 16).toByte() }
        }
        val resolvedPayloadSize = resolvedPayload.size
        val length = 16 + resolvedPayloadSize
        return ByteArray(length).apply {
            this[0] = 0x33
            this[1] = 0x99.toByte()
            this[2] = 0xAA.toByte()
            this[3] = 0x55
            this[4] = (length and 0xFF).toByte()
            this[5] = ((length shr 8) and 0xFF).toByte()
            this[6] = measurementCount.toByte()
            this[7] = (counter and 0xFF).toByte()
            this[8] = ((counter shr 8) and 0xFF).toByte()
            this[9] = ((counter shr 16) and 0xFF).toByte()
            this[10] = ((counter shr 24) and 0xFF).toByte()
            this[11] = (timerMillis and 0xFF).toByte()
            this[12] = ((timerMillis shr 8) and 0xFF).toByte()
            this[13] = ((timerMillis shr 16) and 0xFF).toByte()
            this[14] = ((timerMillis shr 24) and 0xFF).toByte()
            System.arraycopy(resolvedPayload, 0, this, 16, resolvedPayload.size)
        }
    }

    private fun sensorBlock(
        sensorType: Int,
        channelSamples: List<List<Int>>,
    ): ByteArray {
        val channelCount = channelSamples.size
        val samplesPerChannel = channelSamples.firstOrNull()?.size ?: 0
        val payloadSize = channelCount * samplesPerChannel * 2

        return ByteArray(6 + payloadSize).apply {
            this[0] = sensorType.toByte()
            this[1] = channelCount.toByte()
            this[2] = (samplesPerChannel and 0xFF).toByte()
            this[3] = ((samplesPerChannel shr 8) and 0xFF).toByte()

            var offset = 6
            channelSamples.forEach { samples ->
                samples.forEach { sample ->
                    this[offset] = (sample and 0xFF).toByte()
                    this[offset + 1] = ((sample shr 8) and 0xFF).toByte()
                    offset += 2
                }
            }
        }
    }
}
