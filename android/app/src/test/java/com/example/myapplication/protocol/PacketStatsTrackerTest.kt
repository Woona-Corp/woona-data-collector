package com.example.myapplication.protocol

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import java.io.File
import org.junit.Test

class PacketStatsTrackerTest {
    @Test
    fun record_countsReceivedPackets() {
        val tracker = PacketStatsTracker()

        tracker.record(10)
        val result = tracker.record(11)

        assertEquals(2L, result.snapshot.packetsReceived)
        assertEquals(0L, result.snapshot.packetsLost)
        assertEquals(0L, result.gapCount)
    }

    @Test
    fun record_countsCounterGapsAsLostPackets() {
        val tracker = PacketStatsTracker()

        tracker.record(100)
        val result = tracker.record(103)

        assertEquals(2L, result.snapshot.packetsReceived)
        assertEquals(2L, result.snapshot.packetsLost)
        assertEquals(2L, result.gapCount)
        assertEquals(101L, result.expectedCounter)
        assertEquals(103L, result.actualCounter)
    }

    @Test
    fun record_ignoresBackwardsCounterForLossAccounting() {
        val tracker = PacketStatsTracker()

        tracker.record(10)
        val result = tracker.record(9)

        assertEquals(2L, result.snapshot.packetsReceived)
        assertEquals(0L, result.snapshot.packetsLost)
        assertEquals(0L, result.gapCount)
    }

    @Test
    fun record_treatsHugeForwardJumpAsCounterDiscontinuity() {
        val tracker = PacketStatsTracker()

        tracker.record(10)
        val discontinuity = tracker.record(100_010)
        val next = tracker.record(100_011)

        assertEquals(0L, discontinuity.snapshot.packetsLost)
        assertEquals(0L, discontinuity.gapCount)
        assertEquals(3L, next.snapshot.packetsReceived)
        assertEquals(0L, next.snapshot.packetsLost)
    }

    @Test
    fun reset_clearsCountersForNewSession() {
        val tracker = PacketStatsTracker()

        tracker.record(5)
        tracker.record(8)
        tracker.reset()
        val result = tracker.record(100)

        assertEquals(1L, result.snapshot.packetsReceived)
        assertEquals(0L, result.snapshot.packetsLost)
        assertEquals(0L, result.gapCount)
    }
    @Test
    fun sharedSequenceFixtures_coverPoisonResetRolloverAndConfirmedLargeGap() {
        var scenario = ""
        var guard = PacketSequenceGuard()
        var stats = PacketStatsTracker()
        val fixture = File("../../shared/test-fixtures/packet-sequence.csv")
        assertTrue("Shared sequence fixture exists", fixture.isFile)
        fixture.readLines().filter { it.isNotBlank() && !it.startsWith("#") }.drop(1).forEach { line ->
            val row = line.split(',')
            if (row[0] != scenario) {
                scenario = row[0]
                guard = PacketSequenceGuard()
                stats = PacketStatsTracker()
            }
            val counter = row[1].toLong()
            val timer = row[2].toLong()
            val decision = guard.evaluate(counter, timer)
            assertEquals(line, row[3].toBoolean(), decision.accepted)
            assertEquals(line, row[6].toBoolean(), decision.confirmedDiscontinuity)
            assertEquals(line, row[7].toBoolean(), decision.rolledOver)
            if (decision.accepted) {
                guard.accept(counter, timer)
                stats.record(counter, decision.confirmedDiscontinuity)
            }
            assertEquals(line, row[4].toLong(), stats.snapshot().packetsReceived)
            assertEquals(line, row[5].toLong(), stats.snapshot().packetsLost)
        }
    }

    @Test
    fun hugeUnconfirmedJump_reportsUnknownLossInsteadOfSilentlyZero() {
        val stats = PacketStatsTracker()
        stats.record(644)
        val jump = stats.record(3_222_815_366L)
        assertTrue(jump.lossCountUnknown)
        assertEquals(1L, jump.snapshot.counterDiscontinuities)
        assertEquals(0L, jump.snapshot.packetsLost)
    }

    @Test
    fun invalidUnsignedHeader_doesNotMutateTrustedBaseline() {
        val guard = PacketSequenceGuard()
        guard.accept(10, 100)
        assertEquals(PacketSequenceIssue.INVALID_UNSIGNED_HEADER, guard.evaluate(-1, 101).issue)
        assertTrue(guard.evaluate(11, 101).accepted)
    }

    @Test
    fun reset_clearsPendingAndTrustedClock() {
        val guard = PacketSequenceGuard()
        guard.accept(10, 100)
        assertEquals(PacketSequenceIssue.TIMER_REGRESSION, guard.evaluate(11, 90).issue)
        guard.reset()
        assertTrue(guard.evaluate(1, 1).accepted)
    }

}
