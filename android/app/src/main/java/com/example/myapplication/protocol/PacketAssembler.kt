package com.example.myapplication.protocol

data class CompletedPacket(
    val bytes: ByteArray,
    val counter: Long,
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

data class PacketOverlapDiagnostic(
    val currentCounter: Long?,
    val nextCounter: Long?,
    val expectedLength: Int,
    val receivedBeforeNextStart: Int,
    val missingBytes: Int,
    val notificationPayloadBytes: Int,
) {
    val estimatedMissingNotifications: Int
        get() = if (missingBytes <= 0) {
            0
        } else {
            (missingBytes + notificationPayloadBytes - 1) / notificationPayloadBytes
        }

    fun summary(): String = listOf(
        "currentCounter=${currentCounter ?: "?"}",
        "nextCounter=${nextCounter ?: "?"}",
        "expectedLength=$expectedLength",
        "receivedBeforeNextStart=$receivedBeforeNextStart",
        "missingBytes=$missingBytes",
        "estimatedMissingNotificationsAt${notificationPayloadBytes}B=$estimatedMissingNotifications",
    ).joinToString(", ")
}

enum class PacketAssemblyFailureReason(val description: String) {
    OVERLAPPING_PACKET_START("New packet start marker found before previous packet completed"),
}

sealed interface PacketAssemblyResult {
    data class Completed(
        val packet: CompletedPacket,
    ) : PacketAssemblyResult

    data class Rejected(
        val reason: PacketAssemblyFailureReason,
        val diagnostic: PacketOverlapDiagnostic? = null,
    ) : PacketAssemblyResult
}

/**
 * Reassembles packets from arbitrary BLE notification boundaries.
 *
 * A packet start may appear inside a notification when one or more preceding
 * notifications were lost. In that case the old implementation consumed the
 * next packet header as sensor samples. Keep the raw stream untouched, reject
 * the incomplete packet, and resume at the plausible next packet header.
 */
class PacketAssembler(
    initialCapacity: Int = DEFAULT_CAPACITY,
    private val sensorBlockParser: SensorBlockParser = SensorBlockParser(),
) {
    private var buffer = ByteArray(initialCapacity.coerceAtLeast(MIN_PACKET_SIZE))
    private var size = 0
    private var pendingBoundaryCandidate = ByteArray(0)
    private val packetValidator = PacketValidator(sensorBlockParser)

    fun reset() {
        size = 0
        pendingBoundaryCandidate = ByteArray(0)
    }

    fun append(chunk: ByteArray): List<PacketAssemblyResult> {
        if (chunk.isEmpty()) return emptyList()

        val results = mutableListOf<PacketAssemblyResult>()
        val chunkToAppend = resolveBoundaryCandidate(chunk, results)
        if (chunkToAppend.isEmpty()) return results

        ensureCapacity(size + chunkToAppend.size)
        System.arraycopy(chunkToAppend, 0, buffer, size, chunkToAppend.size)
        size += chunkToAppend.size

        while (true) {
            if (size < MIN_PACKET_SIZE) return results

            val headerIndex = findHeader(buffer, size)
            if (headerIndex == -1) {
                keepTailForPartialHeader()
                return results
            }

            if (headerIndex > 0) shiftLeft(headerIndex)
            if (size < MIN_PACKET_SIZE) return results

            val expectedLength = decodeLength(buffer)
            if (expectedLength !in MIN_PACKET_SIZE..MAX_PACKET_SIZE) {
                shiftLeft(1)
                continue
            }

            if (size < expectedLength) {
                when (val overlap = scanForNestedOverlap(
                    expectedLength = expectedLength,
                    lookbackBytes = MAX_NESTED_OVERLAP_LOOKBACK_BYTES,
                    requireCandidateEndAfterExpectedLength = false,
                )) {
                    NestedOverlapResult.None -> Unit
                    NestedOverlapResult.Pending -> return results
                    is NestedOverlapResult.Confirmed -> {
                        val diagnostic = makeOverlapDiagnostic(expectedLength, overlap.index)
                        shiftLeft(overlap.index)
                        results += PacketAssemblyResult.Rejected(
                            reason = PacketAssemblyFailureReason.OVERLAPPING_PACKET_START,
                            diagnostic = diagnostic,
                        )
                        continue
                    }
                }
                return results
            }

            when (val overlap = scanForNestedOverlap(
                expectedLength = expectedLength,
                lookbackBytes = MAX_NESTED_OVERLAP_LOOKBACK_BYTES,
                requireCandidateEndAfterExpectedLength = true,
            )) {
                NestedOverlapResult.None -> Unit
                NestedOverlapResult.Pending -> return results
                is NestedOverlapResult.Confirmed -> {
                    val diagnostic = makeOverlapDiagnostic(expectedLength, overlap.index)
                    shiftLeft(overlap.index)
                    results += PacketAssemblyResult.Rejected(
                        reason = PacketAssemblyFailureReason.OVERLAPPING_PACKET_START,
                        diagnostic = diagnostic,
                    )
                    continue
                }
            }

            val packetBytes = buffer.copyOfRange(0, expectedLength)
            results += PacketAssemblyResult.Completed(
                packet = CompletedPacket(
                    bytes = packetBytes,
                    counter = decodeCounter(packetBytes),
                    sensorBlocks = sensorBlockParser.parse(packetBytes),
                ),
            )
            shiftLeft(expectedLength)
        }
    }

    private fun resolveBoundaryCandidate(
        chunk: ByteArray,
        results: MutableList<PacketAssemblyResult>,
    ): ByteArray {
        if (pendingBoundaryCandidate.isNotEmpty()) {
            pendingBoundaryCandidate += chunk
            return resolvePendingBoundaryCandidate(results)
        }

        if (!hasIncompletePacket() || !startsWithHeaderPrefix(chunk)) return chunk

        pendingBoundaryCandidate = chunk.copyOf()
        return resolvePendingBoundaryCandidate(results)
    }

    private fun resolvePendingBoundaryCandidate(
        results: MutableList<PacketAssemblyResult>,
    ): ByteArray {
        val candidate = pendingBoundaryCandidate
        if (!startsWithHeaderPrefix(candidate)) {
            pendingBoundaryCandidate = ByteArray(0)
            return candidate
        }

        return when (classifyOverlapCandidateChunk(candidate)) {
            OverlapCandidateState.INCOMPLETE -> ByteArray(0)
            OverlapCandidateState.INVALID -> {
                pendingBoundaryCandidate = ByteArray(0)
                candidate
            }

            OverlapCandidateState.CONFIRMED -> {
                val expectedLength = decodeLength(buffer)
                val diagnostic = makeOverlapDiagnostic(
                    expectedLength = expectedLength,
                    nextStartIndex = size,
                    nextPacketBytes = candidate,
                )
                pendingBoundaryCandidate = ByteArray(0)
                size = 0
                results += PacketAssemblyResult.Rejected(
                    reason = PacketAssemblyFailureReason.OVERLAPPING_PACKET_START,
                    diagnostic = diagnostic,
                )
                candidate
            }
        }
    }

    private fun scanForNestedOverlap(
        expectedLength: Int,
        lookbackBytes: Int,
        requireCandidateEndAfterExpectedLength: Boolean,
    ): NestedOverlapResult {
        if (expectedLength <= 1 || size < HEADER_SIZE) return NestedOverlapResult.None

        val searchStart = maxOf(1, expectedLength - lookbackBytes)
        val searchEnd = minOf(expectedLength, size - HEADER_SIZE + 1)
        if (searchStart >= searchEnd) return NestedOverlapResult.None

        var hasIncompleteCandidate = false
        for (index in searchStart until searchEnd) {
            if (!hasHeaderAt(buffer, index)) continue

            val canUseCandidate = !requireCandidateEndAfterExpectedLength ||
                candidateExtendsBeyondExpectedLength(index, expectedLength)
            if (!canUseCandidate) continue

            when (classifyOverlapCandidate(index)) {
                OverlapCandidateState.CONFIRMED -> return NestedOverlapResult.Confirmed(index)
                OverlapCandidateState.INCOMPLETE -> hasIncompleteCandidate = true
                OverlapCandidateState.INVALID -> Unit
            }
        }

        return if (hasIncompleteCandidate) {
            NestedOverlapResult.Pending
        } else {
            NestedOverlapResult.None
        }
    }

    private fun classifyOverlapCandidate(index: Int): OverlapCandidateState {
        val availableBytes = size - index
        if (availableBytes < MIN_PACKET_SIZE) return OverlapCandidateState.INCOMPLETE
        if (!hasHeaderAt(buffer, index)) return OverlapCandidateState.INVALID

        val declaredLength = decodeLength(buffer, index)
        if (declaredLength !in MIN_PACKET_SIZE..MAX_PACKET_SIZE) return OverlapCandidateState.INVALID

        val measurementCount = buffer[index + MEASUREMENT_COUNT_OFFSET].toInt() and 0xFF
        if (measurementCount !in 1..MAX_MEASUREMENT_COUNT) return OverlapCandidateState.INVALID

        val currentCounter = decodeCounter(buffer)
        val currentTimer = decodeTimer(buffer)
        val candidateCounter = decodeCounter(buffer, index)
        val candidateTimer = decodeTimer(buffer, index)
        if (candidateCounter <= currentCounter || candidateTimer < currentTimer) {
            return OverlapCandidateState.INVALID
        }

        if (availableBytes < declaredLength) return OverlapCandidateState.INCOMPLETE

        val candidateBytes = buffer.copyOfRange(index, index + declaredLength)
        return if (packetValidator.validate(candidateBytes) is PacketValidationResult.Accepted) {
            OverlapCandidateState.CONFIRMED
        } else {
            OverlapCandidateState.INVALID
        }
    }

    private fun classifyOverlapCandidateChunk(chunk: ByteArray): OverlapCandidateState {
        if (chunk.size < MIN_PACKET_SIZE) return OverlapCandidateState.INCOMPLETE
        if (!hasHeaderAt(chunk, 0)) return OverlapCandidateState.INVALID

        val declaredLength = decodeLength(chunk)
        if (declaredLength !in MIN_PACKET_SIZE..MAX_PACKET_SIZE) return OverlapCandidateState.INVALID

        val measurementCount = chunk[MEASUREMENT_COUNT_OFFSET].toInt() and 0xFF
        if (measurementCount !in 1..MAX_MEASUREMENT_COUNT) return OverlapCandidateState.INVALID

        val currentCounter = decodeCounter(buffer)
        val currentTimer = decodeTimer(buffer)
        val candidateCounter = decodeCounter(chunk)
        val candidateTimer = decodeTimer(chunk)
        if (candidateCounter <= currentCounter || candidateTimer < currentTimer) {
            return OverlapCandidateState.INVALID
        }

        if (chunk.size < declaredLength) return OverlapCandidateState.INCOMPLETE

        val candidateBytes = chunk.copyOfRange(0, declaredLength)
        return if (packetValidator.validate(candidateBytes) is PacketValidationResult.Accepted) {
            OverlapCandidateState.CONFIRMED
        } else {
            OverlapCandidateState.INVALID
        }
    }

    private fun candidateExtendsBeyondExpectedLength(
        index: Int,
        expectedLength: Int,
    ): Boolean {
        if (size < index + LENGTH_OFFSET + 2) return false
        val declaredLength = decodeLength(buffer, index)
        if (declaredLength !in MIN_PACKET_SIZE..MAX_PACKET_SIZE) return false
        return index + declaredLength > expectedLength
    }

    private fun makeOverlapDiagnostic(
        expectedLength: Int,
        nextStartIndex: Int,
        nextPacketBytes: ByteArray? = null,
    ): PacketOverlapDiagnostic {
        val receivedBeforeNextStart = minOf(nextStartIndex, expectedLength)
        val nextCounter = when {
            nextPacketBytes != null && nextPacketBytes.size >= MIN_PACKET_SIZE ->
                decodeCounter(nextPacketBytes)
            nextStartIndex + MIN_PACKET_SIZE <= size ->
                decodeCounter(buffer, nextStartIndex)
            else -> null
        }
        return PacketOverlapDiagnostic(
            currentCounter = if (size >= MIN_PACKET_SIZE) decodeCounter(buffer) else null,
            nextCounter = nextCounter,
            expectedLength = expectedLength,
            receivedBeforeNextStart = receivedBeforeNextStart,
            missingBytes = (expectedLength - receivedBeforeNextStart).coerceAtLeast(0),
            notificationPayloadBytes = ASSUMED_NOTIFICATION_PAYLOAD_BYTES,
        )
    }

    private fun hasIncompletePacket(): Boolean {
        if (size < MIN_PACKET_SIZE || findHeader(buffer, size) != 0) return false
        val expectedLength = decodeLength(buffer)
        return expectedLength in MIN_PACKET_SIZE..MAX_PACKET_SIZE && size < expectedLength
    }

    private fun ensureCapacity(required: Int) {
        if (required <= buffer.size) return

        var newCapacity = buffer.size
        while (newCapacity < required) newCapacity *= 2
        val expanded = ByteArray(newCapacity)
        System.arraycopy(buffer, 0, expanded, 0, size)
        buffer = expanded
    }

    private fun keepTailForPartialHeader() {
        if (size <= HEADER_SIZE - 1) return

        val tailSize = HEADER_SIZE - 1
        System.arraycopy(buffer, size - tailSize, buffer, 0, tailSize)
        size = tailSize
    }

    private fun shiftLeft(count: Int) {
        val remaining = size - count
        if (remaining > 0) System.arraycopy(buffer, count, buffer, 0, remaining)
        size = remaining.coerceAtLeast(0)
    }

    private fun startsWithHeaderPrefix(chunk: ByteArray): Boolean {
        val prefixSize = minOf(chunk.size, HEADER_SIZE)
        if (prefixSize == 0) return false
        for (index in 0 until prefixSize) {
            if (chunk[index] != START_MARKER[index]) return false
        }
        return true
    }

    private fun decodeLength(packetBuffer: ByteArray, offset: Int = 0): Int {
        return (packetBuffer[offset + LENGTH_OFFSET].toInt() and 0xFF) or
            ((packetBuffer[offset + LENGTH_OFFSET + 1].toInt() and 0xFF) shl 8)
    }

    private fun decodeCounter(packetBytes: ByteArray, offset: Int = 0): Long {
        return (packetBytes[offset + COUNTER_OFFSET].toLong() and 0xFF) or
            ((packetBytes[offset + COUNTER_OFFSET + 1].toLong() and 0xFF) shl 8) or
            ((packetBytes[offset + COUNTER_OFFSET + 2].toLong() and 0xFF) shl 16) or
            ((packetBytes[offset + COUNTER_OFFSET + 3].toLong() and 0xFF) shl 24)
    }

    private fun decodeTimer(packetBytes: ByteArray, offset: Int = 0): Long {
        return (packetBytes[offset + TIMER_OFFSET].toLong() and 0xFF) or
            ((packetBytes[offset + TIMER_OFFSET + 1].toLong() and 0xFF) shl 8) or
            ((packetBytes[offset + TIMER_OFFSET + 2].toLong() and 0xFF) shl 16) or
            ((packetBytes[offset + TIMER_OFFSET + 3].toLong() and 0xFF) shl 24)
    }

    private fun findHeader(packetBuffer: ByteArray, packetSize: Int): Int {
        for (index in 0..packetSize - HEADER_SIZE) {
            if (hasHeaderAt(packetBuffer, index)) return index
        }
        return -1
    }

    private fun hasHeaderAt(packetBuffer: ByteArray, index: Int): Boolean {
        return packetBuffer[index] == START_MARKER[0] &&
            packetBuffer[index + 1] == START_MARKER[1] &&
            packetBuffer[index + 2] == START_MARKER[2] &&
            packetBuffer[index + 3] == START_MARKER[3]
    }

    private companion object {
        val START_MARKER = byteArrayOf(0x33, 0x99.toByte(), 0xAA.toByte(), 0x55)
        const val MAX_PACKET_SIZE = 16_384
        const val DEFAULT_CAPACITY = MAX_PACKET_SIZE
        const val MAX_NESTED_OVERLAP_LOOKBACK_BYTES = 16_384
        const val ASSUMED_NOTIFICATION_PAYLOAD_BYTES = 244
        const val HEADER_SIZE = 4
        const val MIN_PACKET_SIZE = 16
        const val MAX_MEASUREMENT_COUNT = 4
        const val LENGTH_OFFSET = 4
        const val MEASUREMENT_COUNT_OFFSET = 6
        const val COUNTER_OFFSET = 7
        const val TIMER_OFFSET = 11
    }

    private sealed interface NestedOverlapResult {
        data object None : NestedOverlapResult
        data object Pending : NestedOverlapResult
        data class Confirmed(val index: Int) : NestedOverlapResult
    }

    private enum class OverlapCandidateState {
        INCOMPLETE,
        INVALID,
        CONFIRMED,
    }
}
