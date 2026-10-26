package com.example.myapplication.protocol

/** The legacy packet header has two little-endian unsigned 32-bit fields. */
private const val UINT32_MASK = 0xFFFF_FFFFL
private const val UINT32_HALF_RANGE = 0x8000_0000L
private const val MAX_UNCONFIRMED_COUNTER_ADVANCE = 100_000L
private const val MAX_UNCONFIRMED_TIMER_ADVANCE_MS = 3_600_000L

private fun forwardDelta(previous: Long, current: Long): Long = (current - previous) and UINT32_MASK

data class PacketStatsSnapshot(
    val packetsReceived: Long,
    val packetsLost: Long,
    val counterDiscontinuities: Long = 0L,
)

data class PacketRecordResult(
    val snapshot: PacketStatsSnapshot,
    val gapCount: Long = 0L,
    val expectedCounter: Long? = null,
    val actualCounter: Long? = null,
    val lossCountUnknown: Boolean = false,
    val counterRolledOver: Boolean = false,
)

class PacketStatsTracker {
    private var lastCounter: Long? = null
    private var packetsReceived = 0L
    private var packetsLost = 0L
    private var counterDiscontinuities = 0L

    fun reset() {
        lastCounter = null
        packetsReceived = 0L
        packetsLost = 0L
        counterDiscontinuities = 0L
    }

    /** Large gaps need independent sequence confirmation; they are never silently clamped. */
    fun record(counter: Long, confirmedDiscontinuity: Boolean = false): PacketRecordResult {
        val previous = lastCounter
        val expectedCounter = previous?.let { (it + 1) and UINT32_MASK }
        var gapCount = 0L
        var lossCountUnknown = false
        var rolledOver = false
        if (counter !in 0..UINT32_MASK) {
            lossCountUnknown = true
        } else if (previous != null) {
            val delta = forwardDelta(previous, counter)
            when {
                delta == 0L || delta >= UINT32_HALF_RANGE ||
                    (counter < previous && delta >= MAX_UNCONFIRMED_COUNTER_ADVANCE) -> lossCountUnknown = true
                delta >= MAX_UNCONFIRMED_COUNTER_ADVANCE && !confirmedDiscontinuity -> lossCountUnknown = true
                else -> {
                    gapCount = delta - 1
                    packetsLost += gapCount
                    rolledOver = counter < previous
                }
            }
        }
        if (lossCountUnknown) counterDiscontinuities++
        packetsReceived++
        if (counter in 0..UINT32_MASK) lastCounter = counter
        return PacketRecordResult(snapshot(), gapCount, expectedCounter, counter, lossCountUnknown, rolledOver)
    }

    fun snapshot() = PacketStatsSnapshot(packetsReceived, packetsLost, counterDiscontinuities)
}

enum class PacketSequenceIssue {
    TIMER_REGRESSION,
    COUNTER_DISCONTINUITY,
    TIMER_DISCONTINUITY,
    INVALID_UNSIGNED_HEADER,
}

data class PacketSequenceDecision(
    val issue: PacketSequenceIssue? = null,
    val confirmedDiscontinuity: Boolean = false,
    val rolledOver: Boolean = false,
) {
    val accepted: Boolean get() = issue == null
    val startsNewSegment: Boolean get() = confirmedDiscontinuity || rolledOver
}

/**
 * Quarantine an implausible header before it can poison the trusted clock.
 * Limits bound an UNCONFIRMED advance, not the supported recording/gap length:
 * a second coherent packet confirms a real discontinuity, explicitly breaking
 * the chart/alignment segment. Every quarantined byte is still kept in raw.
 */
class PacketSequenceGuard {
    private data class Header(val counter: Long, val timer: Long)
    private var trusted: Header? = null
    private var pending: Header? = null

    fun reset() {
        trusted = null
        pending = null
    }

    fun evaluate(counter: Long, timerMillis: Long): PacketSequenceDecision {
        if (counter !in 0..UINT32_MASK || timerMillis !in 0..UINT32_MASK) {
            pending = null
            return PacketSequenceDecision(PacketSequenceIssue.INVALID_UNSIGNED_HEADER)
        }
        val next = Header(counter, timerMillis)
        val previous = trusted ?: return PacketSequenceDecision()
        if (coherent(previous, next)) {
            pending = null
            return PacketSequenceDecision(rolledOver = counter < previous.counter || timerMillis < previous.timer)
        }
        val candidate = pending
        if (candidate != null && coherent(candidate, next)) {
            pending = null
            return PacketSequenceDecision(confirmedDiscontinuity = true)
        }
        pending = next
        val timerDelta = forwardDelta(previous.timer, timerMillis)
        val issue = when {
            timerDelta >= UINT32_HALF_RANGE -> PacketSequenceIssue.TIMER_REGRESSION
            forwardDelta(previous.counter, counter) !in 1 until MAX_UNCONFIRMED_COUNTER_ADVANCE ->
                PacketSequenceIssue.COUNTER_DISCONTINUITY
            else -> PacketSequenceIssue.TIMER_DISCONTINUITY
        }
        return PacketSequenceDecision(issue)
    }

    /** Commit only after packet/timeline persistence succeeded. */
    fun accept(counter: Long, timerMillis: Long) {
        trusted = Header(counter, timerMillis)
        pending = null
    }

    private fun coherent(previous: Header, next: Header): Boolean =
        forwardDelta(previous.counter, next.counter) in 1 until MAX_UNCONFIRMED_COUNTER_ADVANCE &&
            forwardDelta(previous.timer, next.timer) <= MAX_UNCONFIRMED_TIMER_ADVANCE_MS
}
