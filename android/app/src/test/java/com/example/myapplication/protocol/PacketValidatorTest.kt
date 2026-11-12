package com.example.myapplication.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PacketValidatorTest {
    private val validator = PacketValidator()

    @Test
    fun validate_acceptsPacketWithKnownTopLevelFields() {
        val result = validator.validate(
            packetBytes = testPacket(
                counter = 7,
                timerMillis = 99,
                measurementCount = 1,
                blocks = listOf(sensorBlock(sensorType = 2, channelSamples = listOf(listOf(10, 20)))),
            ),
        )

        assertTrue(result is PacketValidationResult.Accepted)
        val packet = (result as PacketValidationResult.Accepted).packet
        assertEquals(7L, packet.counter)
        assertEquals(99L, packet.timerMillis)
        assertEquals(1, packet.measurementCount)
    }

    @Test
    fun validate_rejectsPacketWithZeroMeasurementCount() {
        val result = validator.validate(
            packetBytes = testPacket(
                counter = 7,
                timerMillis = 99,
                measurementCount = 0,
            ),
        )

        assertEquals(
            PacketValidationFailureReason.INVALID_MEASUREMENT_COUNT,
            (result as PacketValidationResult.Rejected).reason,
        )
    }

    @Test
    fun validate_rejectsPacketWithLengthMismatch() {
        val packet = testPacket(
            counter = 1,
            timerMillis = 10,
            measurementCount = 1,
            blocks = listOf(sensorBlock(sensorType = 2, channelSamples = listOf(listOf(10, 20)))),
        ).copyOf(17)

        val result = validator.validate(packet)

        assertEquals(
            PacketValidationFailureReason.INVALID_LENGTH,
            (result as PacketValidationResult.Rejected).reason,
        )
    }

    @Test
    fun validate_rejectsPacketWithoutParsedSensorBlocks() {
        val result = validator.validate(
            packetBytes = testPacket(
                counter = 7,
                timerMillis = 99,
                measurementCount = 1,
            ),
        )

        assertEquals(
            PacketValidationFailureReason.INVALID_SENSOR_BLOCKS,
            (result as PacketValidationResult.Rejected).reason,
        )
    }

    @Test
    fun validate_rejectsIncompleteSecondBlockWithFactualMetadata() {
        val result = validator.validate(
            packetBytes = testPacket(
                counter = 7,
                timerMillis = 99,
                measurementCount = 3,
                blocks = listOf(
                    sensorBlock(sensorType = 2, channelSamples = listOf(listOf(10, 20))),
                    ByteArray(4),
                ),
            ),
        )

        val rejected = result as PacketValidationResult.Rejected
        assertEquals(PacketValidationFailureReason.INVALID_SENSOR_BLOCKS, rejected.reason)
        assertEquals(1, rejected.parsedBlockCount)
        assertEquals(26, rejected.consumedBytes)
        assertEquals(4, rejected.trailingBytes)
        assertEquals(1, rejected.failedBlockIndex)
    }

    @Test
    fun validate_rejectsInvalidThirdBlockLayoutWithFactualMetadata() {
        val result = validator.validate(
            packetBytes = testPacket(
                counter = 7,
                timerMillis = 99,
                measurementCount = 3,
                blocks = listOf(
                    sensorBlock(sensorType = 2, channelSamples = listOf(listOf(10, 20))),
                    sensorBlock(sensorType = 3, channelSamples = listOf(listOf(30))),
                    sensorBlock(sensorType = 4, channelSamples = emptyList()),
                ),
            ),
        )

        val rejected = result as PacketValidationResult.Rejected
        assertEquals(PacketValidationFailureReason.INVALID_SENSOR_BLOCKS, rejected.reason)
        assertEquals(3, rejected.parsedBlockCount)
        assertEquals(40, rejected.consumedBytes)
        assertEquals(0, rejected.trailingBytes)
        assertEquals(2, rejected.failedBlockIndex)
    }

    @Test
    fun validate_rejectsOversizedTrailerWithoutInventingFailedBlock() {
        val block = sensorBlock(sensorType = 2, channelSamples = listOf(listOf(10, 20)))
        val packet = testPacket(
            counter = 7,
            timerMillis = 99,
            measurementCount = 3,
            blocks = listOf(block, block, block),
        ) + ByteArray(5)
        packet[4] = (packet.size and 0xFF).toByte()
        packet[5] = ((packet.size shr 8) and 0xFF).toByte()

        val result = validator.validate(packet)

        val rejected = result as PacketValidationResult.Rejected
        assertEquals(PacketValidationFailureReason.INVALID_SENSOR_BLOCKS, rejected.reason)
        assertEquals(3, rejected.parsedBlockCount)
        assertEquals(46, rejected.consumedBytes)
        assertEquals(5, rejected.trailingBytes)
        assertTrue(rejected.failedBlockIndex == null)
    }

    @Test
    fun validate_acceptsPacketWithFourByteTrailer() {
        val block = sensorBlock(
            sensorType = 2,
            channelSamples = listOf(listOf(10, 20)),
        )
        val packet = testPacket(
            counter = 7,
            timerMillis = 99,
            measurementCount = 1,
            blocks = listOf(block),
        ) + byteArrayOf(1, 2, 3, 4)
        packet[4] = (packet.size and 0xFF).toByte()
        packet[5] = ((packet.size shr 8) and 0xFF).toByte()

        assertTrue(validator.validate(packet) is PacketValidationResult.Accepted)
    }

    private fun testPacket(
        counter: Int,
        timerMillis: Int,
        measurementCount: Int,
        blocks: List<ByteArray> = emptyList(),
    ): ByteArray {
        val payload = blocks.fold(ByteArray(0)) { acc, block -> acc + block }
        val length = 16 + payload.size
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
            if (payload.isNotEmpty()) {
                System.arraycopy(payload, 0, this, 16, payload.size)
            }
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
