package com.example.myapplication.protocol

data class ValidatedPacket(
    val bytes: ByteArray,
    val counter: Long,
    val timerMillis: Long,
    val measurementCount: Int,
    val sensorBlocks: List<SensorBlock>,
) {
    fun channelSamples(
        sensorType: Int,
        channel: Int,
    ): List<Float> {
        if (channel <= 0) return emptyList()

        return sensorBlocks
            .asSequence()
            .filter { it.sensorType == sensorType && channel <= it.channelSamples.size }
            .flatMap { it.channelSamples[channel - 1].asSequence() }
            .toList()
    }
}

enum class PacketValidationFailureReason(val description: String) {
    INVALID_START("Invalid packet start marker"),
    INVALID_LENGTH("Invalid packet length"),
    INVALID_MEASUREMENT_COUNT("Invalid measurement count"),
    INVALID_SENSOR_BLOCKS("Invalid sensor block layout"),
}

sealed interface PacketValidationResult {
    data class Accepted(
        val packet: ValidatedPacket,
    ) : PacketValidationResult

    data class Rejected(
        val reason: PacketValidationFailureReason,
        val parsedBlockCount: Int? = null,
        val consumedBytes: Int? = null,
        val trailingBytes: Int? = null,
        val failedBlockIndex: Int? = null,
    ) : PacketValidationResult
}

class PacketValidator(
    private val sensorBlockParser: SensorBlockParser = SensorBlockParser(),
) {
    fun validate(packetBytes: ByteArray): PacketValidationResult {
        if (packetBytes.size < MIN_PACKET_SIZE) {
            return PacketValidationResult.Rejected(PacketValidationFailureReason.INVALID_LENGTH)
        }

        if (!hasStartMarker(packetBytes)) {
            return PacketValidationResult.Rejected(PacketValidationFailureReason.INVALID_START)
        }

        val declaredLength = decodeLength(packetBytes)
        if (
            declaredLength != packetBytes.size ||
            declaredLength !in MIN_PACKET_SIZE..MAX_PACKET_SIZE
        ) {
            return PacketValidationResult.Rejected(PacketValidationFailureReason.INVALID_LENGTH)
        }

        val measurementCount = packetBytes[MEASUREMENT_COUNT_OFFSET].toInt() and 0xFF
        if (measurementCount !in 1..MAX_MEASUREMENT_COUNT) {
            return PacketValidationResult.Rejected(PacketValidationFailureReason.INVALID_MEASUREMENT_COUNT)
        }

        val parseResult = sensorBlockParser.parseResult(packetBytes)
        val trailingBytes = packetBytes.size - parseResult.consumedBytes
        if (
            parseResult.parsedBlockCount != measurementCount ||
            parseResult.blocks.size != measurementCount ||
            parseResult.blocks.any { it.channelSamples.isEmpty() } ||
            trailingBytes !in 0..MAX_SENSOR_BLOCK_TRAILER_BYTES
        ) {
            val failedBlockIndex = when {
                parseResult.parsedBlockCount != measurementCount ||
                    parseResult.blocks.size != measurementCount -> parseResult.parsedBlockCount
                else -> parseResult.blocks.indexOfFirst { it.channelSamples.isEmpty() }.takeIf { it >= 0 }
            }
            return PacketValidationResult.Rejected(
                reason = PacketValidationFailureReason.INVALID_SENSOR_BLOCKS,
                parsedBlockCount = parseResult.parsedBlockCount,
                consumedBytes = parseResult.consumedBytes,
                trailingBytes = trailingBytes,
                failedBlockIndex = failedBlockIndex,
            )
        }

        return PacketValidationResult.Accepted(
            packet = ValidatedPacket(
                bytes = packetBytes,
                counter = decodeCounter(packetBytes),
                timerMillis = decodeTimer(packetBytes),
                measurementCount = measurementCount,
                sensorBlocks = parseResult.blocks,
            ),
        )
    }

    private fun hasStartMarker(packetBytes: ByteArray): Boolean {
        return packetBytes[0] == 0x33.toByte() &&
            packetBytes[1] == 0x99.toByte() &&
            packetBytes[2] == 0xAA.toByte() &&
            packetBytes[3] == 0x55.toByte()
    }

    private fun decodeLength(packetBytes: ByteArray): Int {
        return (packetBytes[LENGTH_OFFSET].toInt() and 0xFF) or
            ((packetBytes[LENGTH_OFFSET + 1].toInt() and 0xFF) shl 8)
    }

    private fun decodeCounter(packetBytes: ByteArray): Long {
        val c0 = packetBytes[COUNTER_OFFSET].toLong() and 0xFF
        val c1 = packetBytes[COUNTER_OFFSET + 1].toLong() and 0xFF
        val c2 = packetBytes[COUNTER_OFFSET + 2].toLong() and 0xFF
        val c3 = packetBytes[COUNTER_OFFSET + 3].toLong() and 0xFF
        return c0 or (c1 shl 8) or (c2 shl 16) or (c3 shl 24)
    }

    private fun decodeTimer(packetBytes: ByteArray): Long {
        val t0 = packetBytes[TIMER_OFFSET].toLong() and 0xFF
        val t1 = packetBytes[TIMER_OFFSET + 1].toLong() and 0xFF
        val t2 = packetBytes[TIMER_OFFSET + 2].toLong() and 0xFF
        val t3 = packetBytes[TIMER_OFFSET + 3].toLong() and 0xFF
        return t0 or (t1 shl 8) or (t2 shl 16) or (t3 shl 24)
    }

    private companion object {
        const val MIN_PACKET_SIZE = 16
        const val MAX_PACKET_SIZE = 16_384
        const val MAX_MEASUREMENT_COUNT = 4
        const val MAX_SENSOR_BLOCK_TRAILER_BYTES = 4
        const val LENGTH_OFFSET = 4
        const val MEASUREMENT_COUNT_OFFSET = 6
        const val COUNTER_OFFSET = 7
        const val TIMER_OFFSET = 11
    }
}
