import XCTest
@testable import Woona

final class PacketStatsTrackerTests: XCTestCase {
    func testRecordCountsReceivedPackets() {
        let tracker = PacketStatsTracker()

        _ = tracker.record(counter: 10)
        let result = tracker.record(counter: 11)

        XCTAssertEqual(result.snapshot.packetsReceived, 2)
        XCTAssertEqual(result.snapshot.packetsLost, 0)
        XCTAssertEqual(result.gapCount, 0)
    }

    func testRecordCountsCounterGapsAsLostPackets() {
        let tracker = PacketStatsTracker()

        _ = tracker.record(counter: 100)
        let result = tracker.record(counter: 103)

        XCTAssertEqual(result.snapshot.packetsReceived, 2)
        XCTAssertEqual(result.snapshot.packetsLost, 2)
        XCTAssertEqual(result.gapCount, 2)
        XCTAssertEqual(result.expectedCounter, 101)
        XCTAssertEqual(result.actualCounter, 103)
    }

    func testRecordIgnoresBackwardsCounterForLossAccounting() {
        let tracker = PacketStatsTracker()

        _ = tracker.record(counter: 10)
        let result = tracker.record(counter: 9)

        XCTAssertEqual(result.snapshot.packetsReceived, 2)
        XCTAssertEqual(result.snapshot.packetsLost, 0)
        XCTAssertEqual(result.gapCount, 0)
    }

    func testResetClearsCountersForNewSession() {
        let tracker = PacketStatsTracker()

        _ = tracker.record(counter: 5)
        _ = tracker.record(counter: 8)
        tracker.reset()
        let result = tracker.record(counter: 100)

        XCTAssertEqual(result.snapshot.packetsReceived, 1)
        XCTAssertEqual(result.snapshot.packetsLost, 0)
        XCTAssertEqual(result.gapCount, 0)
    }

    func testRecordUsesUnsigned32CounterRollover() {
        let tracker = PacketStatsTracker()

        _ = tracker.record(counter: UInt64(UInt32.max))
        let result = tracker.record(counter: 0)

        XCTAssertEqual(result.snapshot.packetsReceived, 2)
        XCTAssertEqual(result.snapshot.packetsLost, 0)
        XCTAssertEqual(result.gapCount, 0)
        XCTAssertEqual(result.expectedCounter, 0)
        XCTAssertTrue(result.counterRolledOver)
        XCTAssertEqual(result.actualCounter, 0)
    }
    func testSharedSequenceFixturesCoverPoisonResetRolloverAndConfirmedLargeGap() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let contents = try String(contentsOf: root.appendingPathComponent("shared/test-fixtures/packet-sequence.csv"), encoding: .utf8)
        let lines = contents.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("#") }.dropFirst()
        var scenario = ""
        var guardState = PacketSequenceGuard()
        var stats = PacketStatsTracker()
        for line in lines {
            let row = line.split(separator: ",").map(String.init)
            if row[0] != scenario {
                scenario = row[0]
                guardState = PacketSequenceGuard()
                stats = PacketStatsTracker()
            }
            let counter = try XCTUnwrap(UInt64(row[1]))
            let timer = try XCTUnwrap(UInt64(row[2]))
            let decision = guardState.evaluate(counter: counter, timerMillis: timer)
            XCTAssertEqual(decision.accepted, row[3] == "true", String(line))
            XCTAssertEqual(decision.confirmedDiscontinuity, row[6] == "true", String(line))
            XCTAssertEqual(decision.rolledOver, row[7] == "true", String(line))
            if decision.accepted {
                guardState.accept(counter: counter, timerMillis: timer)
                _ = stats.record(counter: counter, confirmedDiscontinuity: decision.confirmedDiscontinuity)
            }
            XCTAssertEqual(stats.snapshot().packetsReceived, try XCTUnwrap(UInt64(row[4])), String(line))
            XCTAssertEqual(stats.snapshot().packetsLost, try XCTUnwrap(UInt64(row[5])), String(line))
        }
    }

    func testHugeUnconfirmedJumpReportsUnknownLossAndDoesNotOverflow() {
        let stats = PacketStatsTracker()
        _ = stats.record(counter: 644)
        let jump = stats.record(counter: 3_222_815_366)
        XCTAssertTrue(jump.lossCountUnknown)
        XCTAssertEqual(jump.snapshot.counterDiscontinuities, 1)
        XCTAssertEqual(jump.snapshot.packetsLost, 0)
        let invalid = stats.record(counter: UInt64.max)
        XCTAssertTrue(invalid.lossCountUnknown)
    }

    func testInvalidUnsignedHeaderDoesNotMutateTrustedBaseline() {
        let guardState = PacketSequenceGuard()
        guardState.accept(counter: 10, timerMillis: 100)
        XCTAssertEqual(guardState.evaluate(counter: UInt64.max, timerMillis: 101).issue, .invalidUnsignedHeader)
        XCTAssertTrue(guardState.evaluate(counter: 11, timerMillis: 101).accepted)
    }

    func testResetClearsPendingAndTrustedClock() {
        let guardState = PacketSequenceGuard()
        guardState.accept(counter: 10, timerMillis: 100)
        XCTAssertEqual(guardState.evaluate(counter: 11, timerMillis: 90).issue, .timerRegression)
        guardState.reset()
        XCTAssertTrue(guardState.evaluate(counter: 1, timerMillis: 1).accepted)
    }

}
