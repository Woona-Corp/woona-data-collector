import Foundation

private let packetUInt32Mask: UInt64 = 0xffff_ffff
private let packetUInt32HalfRange: UInt64 = 0x8000_0000
private let maximumUnconfirmedCounterAdvance: UInt64 = 100_000
private let maximumUnconfirmedTimerAdvanceMillis: UInt64 = 3_600_000

private func packetForwardDelta(_ previous: UInt64, _ current: UInt64) -> UInt64 {
    (current &- previous) & packetUInt32Mask
}

struct PacketStatsSnapshot: Equatable {
    let packetsReceived: UInt64
    let packetsLost: UInt64
    var counterDiscontinuities: UInt64 = 0
}

struct PacketRecordResult: Equatable {
    let snapshot: PacketStatsSnapshot
    let gapCount: UInt64
    let expectedCounter: UInt64?
    let actualCounter: UInt64?
    var lossCountUnknown = false
    var counterRolledOver = false
}

final class PacketStatsTracker {
    private var lastCounter: UInt64?
    private var packetsReceived: UInt64 = 0
    private var packetsLost: UInt64 = 0
    private var counterDiscontinuities: UInt64 = 0

    func reset() {
        lastCounter = nil
        packetsReceived = 0
        packetsLost = 0
        counterDiscontinuities = 0
    }

    // Confirmation permits a real large gap; unknown continuity is recorded separately.
    func record(counter: UInt64, confirmedDiscontinuity: Bool = false) -> PacketRecordResult {
        let previous = lastCounter
        let expectedCounter = previous.map { ($0 + 1) & packetUInt32Mask }
        var gapCount: UInt64 = 0
        var lossCountUnknown = false
        var rolledOver = false
        if counter > packetUInt32Mask {
            lossCountUnknown = true
        } else if let previous {
            let delta = packetForwardDelta(previous, counter)
            if delta == 0 || delta >= packetUInt32HalfRange
                || (counter < previous && delta >= maximumUnconfirmedCounterAdvance)
                || (delta >= maximumUnconfirmedCounterAdvance && !confirmedDiscontinuity) {
                lossCountUnknown = true
            } else {
                gapCount = delta - 1
                packetsLost += gapCount
                rolledOver = counter < previous
            }
        }
        if lossCountUnknown { counterDiscontinuities += 1 }
        packetsReceived += 1
        if counter <= packetUInt32Mask { lastCounter = counter }
        return PacketRecordResult(
            snapshot: snapshot(), gapCount: gapCount, expectedCounter: expectedCounter,
            actualCounter: counter, lossCountUnknown: lossCountUnknown, counterRolledOver: rolledOver
        )
    }

    func snapshot() -> PacketStatsSnapshot {
        PacketStatsSnapshot(packetsReceived: packetsReceived, packetsLost: packetsLost,
                            counterDiscontinuities: counterDiscontinuities)
    }
}

enum PacketSequenceIssue: Equatable {
    case timerRegression, counterDiscontinuity, timerDiscontinuity, invalidUnsignedHeader
}

struct PacketSequenceDecision: Equatable {
    var issue: PacketSequenceIssue?
    var confirmedDiscontinuity = false
    var rolledOver = false
    var accepted: Bool { issue == nil }
    var startsNewSegment: Bool { confirmedDiscontinuity || rolledOver }
}

// Header fields are unsigned32, not unsigned16. A suspect first header never
// updates the trusted clock; a second coherent packet can establish a new
// explicitly discontinuous segment. The limits apply only to unconfirmed jumps.
final class PacketSequenceGuard {
    private struct Header {
        let counter: UInt64
        let timer: UInt64
    }
    private var trusted: Header?
    private var pending: Header?

    func reset() {
        trusted = nil
        pending = nil
    }

    func evaluate(counter: UInt64, timerMillis: UInt64) -> PacketSequenceDecision {
        guard counter <= packetUInt32Mask, timerMillis <= packetUInt32Mask else {
            pending = nil
            return PacketSequenceDecision(issue: .invalidUnsignedHeader)
        }
        let next = Header(counter: counter, timer: timerMillis)
        guard let previous = trusted else { return PacketSequenceDecision() }
        if coherent(previous, next) {
            pending = nil
            return PacketSequenceDecision(rolledOver: counter < previous.counter || timerMillis < previous.timer)
        }
        if let candidate = pending, coherent(candidate, next) {
            pending = nil
            return PacketSequenceDecision(confirmedDiscontinuity: true)
        }
        pending = next
        if packetForwardDelta(previous.timer, timerMillis) >= packetUInt32HalfRange {
            return PacketSequenceDecision(issue: .timerRegression)
        }
        let counterDelta = packetForwardDelta(previous.counter, counter)
        if counterDelta == 0 || counterDelta >= maximumUnconfirmedCounterAdvance {
            return PacketSequenceDecision(issue: .counterDiscontinuity)
        }
        return PacketSequenceDecision(issue: .timerDiscontinuity)
    }

    // Persistence, not validation, commits the new baseline.
    func accept(counter: UInt64, timerMillis: UInt64) {
        trusted = Header(counter: counter, timer: timerMillis)
        pending = nil
    }

    private func coherent(_ previous: Header, _ next: Header) -> Bool {
        let counterDelta = packetForwardDelta(previous.counter, next.counter)
        return counterDelta > 0 && counterDelta < maximumUnconfirmedCounterAdvance
            && packetForwardDelta(previous.timer, next.timer) <= maximumUnconfirmedTimerAdvanceMillis
    }
}
