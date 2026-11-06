import Foundation

struct CompletedPacket: Equatable {
    let bytes: [UInt8]
    let counter: UInt64
    let sensorBlocks: [SensorBlock]
    // Only the assembler can mint this evidence; arbitrary blocks are never
    // accepted as validation. Rejections retain their original diagnostics.
    fileprivate(set) var validation: PacketValidationResult? = nil

    init(bytes: [UInt8], counter: UInt64, sensorBlocks: [SensorBlock]) {
        self.bytes = bytes
        self.counter = counter
        self.sensorBlocks = sensorBlocks
    }

    func channelSamples(sensorType: Int, channel: Int) -> [Float] {
        guard channel > 0 else { return [] }

        return sensorBlocks.flatMap { block -> [Float] in
            guard block.sensorType == sensorType, channel <= block.channelSamples.count else {
                return []
            }
            return block.channelSamples[channel - 1]
        }
    }
}

struct PacketOverlapDiagnostic: Equatable, Sendable {
    let currentCounter: UInt64?
    let nextCounter: UInt64?
    let expectedLength: Int
    let receivedBeforeNextStart: Int
    let missingBytes: Int
    let notificationPayloadBytes: Int

    var estimatedMissingNotifications: Int {
        guard missingBytes > 0 else { return 0 }
        return (missingBytes + notificationPayloadBytes - 1) / notificationPayloadBytes
    }
}

enum PacketAssemblyFailureReason: Equatable {
    case overlappingPacketStart(PacketOverlapDiagnostic? = nil)

    var rawValue: String {
        switch self {
        case .overlappingPacketStart:
            return "New packet start marker found before previous packet completed"
        }
    }

    var diagnosticMessage: String {
        switch self {
        case .overlappingPacketStart(nil):
            return rawValue
        case .overlappingPacketStart(let diagnostic?):
            var details = [
                "currentCounter=\(diagnostic.currentCounter.map(String.init) ?? "?")",
                "nextCounter=\(diagnostic.nextCounter.map(String.init) ?? "?")",
                "expectedLength=\(diagnostic.expectedLength)",
                "receivedBeforeNextStart=\(diagnostic.receivedBeforeNextStart)",
                "missingBytes=\(diagnostic.missingBytes)",
                "estimatedMissingNotificationsAt\(diagnostic.notificationPayloadBytes)B=\(diagnostic.estimatedMissingNotifications)"
            ]
            if diagnostic.missingBytes % diagnostic.notificationPayloadBytes != 0 {
                details.append("notificationEstimateRoundedUp=true")
            }
            return "\(rawValue) (\(details.joined(separator: ", ")))"
        }
    }
}

enum PacketAssemblyResult: Equatable {
    case completed(CompletedPacket)
    case rejected(PacketAssemblyFailureReason)
}

final class PacketAssembler {
    private var buffer: [UInt8]
    private var pendingBoundaryCandidate: [UInt8] = []
    private let packetValidator: PacketValidator

    init(
        initialCapacity: Int = PacketValidator.maximumPacketSize,
        sensorBlockParser: SensorBlockParser = SensorBlockParser()
    ) {
        self.buffer = []
        self.buffer.reserveCapacity(initialCapacity)
        self.packetValidator = PacketValidator(sensorBlockParser: sensorBlockParser)
    }

    func reset() {
        buffer.removeAll(keepingCapacity: true)
        pendingBoundaryCandidate.removeAll(keepingCapacity: false)
    }

    func append(_ chunk: [UInt8]) -> [PacketAssemblyResult] {
        guard !chunk.isEmpty else { return [] }

        var results: [PacketAssemblyResult] = []
        let chunkToAppend = resolveBoundaryCandidate(chunk, results: &results)
        guard !chunkToAppend.isEmpty else { return results }

        buffer.append(contentsOf: chunkToAppend)

        while true {
            guard buffer.count >= Self.minimumPacketSize else { return results }

            guard let headerIndex = findHeader(in: buffer) else {
                keepTailForPartialHeader()
                return results
            }

            if headerIndex > 0 {
                shiftLeft(headerIndex)
            }

            guard buffer.count >= Self.minimumPacketSize else { return results }

            let expectedLength = PacketValidator.decodeLength(buffer)
            if expectedLength < Self.minimumPacketSize || expectedLength > PacketValidator.maximumPacketSize {
                shiftLeft(1)
                continue
            }

            if buffer.count < expectedLength {
                switch scanForNestedOverlap(
                    before: expectedLength,
                    lookbackBytes: Self.maximumNestedOverlapLookbackBytes,
                    requireCandidateEndAfterExpectedLength: false
                ) {
                case .none:
                    break
                case .pending:
                    return results
                case .confirmed(let index):
                    let diagnostic = makeOverlapDiagnostic(expectedLength: expectedLength, nextStartIndex: index)
                    shiftLeft(index)
                    results.append(.rejected(.overlappingPacketStart(diagnostic)))
                    continue
                }
            }

            guard buffer.count >= expectedLength else { return results }

            let packetBytes = Array(buffer[0..<expectedLength])
            let validation = packetValidator.validate(packetBytes)
            switch validation {
            case .accepted:
                switch scanForNestedOverlap(
                    before: expectedLength,
                    lookbackBytes: Self.maximumNestedOverlapLookbackBytes,
                    requireCandidateEndAfterExpectedLength: true
                ) {
                case .none:
                    break
                case .pending:
                    return results
                case .confirmed(let index):
                    let diagnostic = makeOverlapDiagnostic(expectedLength: expectedLength, nextStartIndex: index)
                    shiftLeft(index)
                    results.append(.rejected(.overlappingPacketStart(diagnostic)))
                    continue
                }
            case .rejected:
                switch scanForNestedOverlap(
                    before: expectedLength,
                    lookbackBytes: nil,
                    requireCandidateEndAfterExpectedLength: false
                ) {
                case .none:
                    break
                case .pending:
                    return results
                case .confirmed(let index):
                    let diagnostic = makeOverlapDiagnostic(expectedLength: expectedLength, nextStartIndex: index)
                    shiftLeft(index)
                    results.append(.rejected(.overlappingPacketStart(diagnostic)))
                    continue
                }
            }

            let blocks: [SensorBlock]
            if case .accepted(let packet) = validation { blocks = packet.sensorBlocks }
            else { blocks = [] }
            var completed = CompletedPacket(bytes: packetBytes, counter: PacketValidator.decodeCounter(packetBytes), sensorBlocks: blocks)
            completed.validation = validation
            results.append(.completed(completed))
            shiftLeft(expectedLength)
        }
    }

    private func hasIncompletePacket() -> Bool {
        guard buffer.count >= Self.minimumPacketSize else { return false }
        guard findHeader(in: buffer) == 0 else { return false }

        let expectedLength = PacketValidator.decodeLength(buffer)
        return expectedLength >= Self.minimumPacketSize && buffer.count < expectedLength
    }

    private func keepTailForPartialHeader() {
        guard buffer.count > Self.headerSize - 1 else { return }
        buffer = Array(buffer.suffix(Self.headerSize - 1))
    }

    private func shiftLeft(_ count: Int) {
        guard count > 0 else { return }
        if count >= buffer.count {
            buffer.removeAll(keepingCapacity: true)
        } else {
            buffer.removeFirst(count)
        }
    }

    private func resolveBoundaryCandidate(
        _ chunk: [UInt8],
        results: inout [PacketAssemblyResult]
    ) -> [UInt8] {
        if !pendingBoundaryCandidate.isEmpty {
            pendingBoundaryCandidate.append(contentsOf: chunk)
            return resolvePendingBoundaryCandidate(results: &results)
        }

        guard hasIncompletePacket(), startsWithHeaderPrefix(chunk) else {
            return chunk
        }

        pendingBoundaryCandidate = chunk
        return resolvePendingBoundaryCandidate(results: &results)
    }

    private func resolvePendingBoundaryCandidate(
        results: inout [PacketAssemblyResult]
    ) -> [UInt8] {
        let candidate = pendingBoundaryCandidate
        guard startsWithHeaderPrefix(candidate) else {
            pendingBoundaryCandidate.removeAll()
            return candidate
        }

        switch classifyOverlapCandidate(candidate) {
        case .incomplete:
            return []
        case .invalid:
            pendingBoundaryCandidate.removeAll()
            return candidate
        case .confirmed:
            let expectedLength = PacketValidator.decodeLength(buffer)
            let diagnostic = makeOverlapDiagnostic(
                expectedLength: expectedLength,
                nextStartIndex: buffer.count,
                nextPacketBytes: candidate
            )
            pendingBoundaryCandidate.removeAll()
            buffer.removeAll(keepingCapacity: true)
            results.append(.rejected(.overlappingPacketStart(diagnostic)))
            return candidate
        }
    }

    private func classifyOverlapCandidate(_ chunk: [UInt8]) -> OverlapCandidateState {
        guard chunk.count >= Self.minimumPacketSize else { return .incomplete }
        guard PacketValidator.hasStartMarker(chunk, at: 0) else { return .invalid }

        let declaredLength = PacketValidator.decodeLength(chunk)
        guard (Self.minimumPacketSize...PacketValidator.maximumPacketSize).contains(declaredLength) else {
            return .invalid
        }

        let measurementCount = Int(chunk[PacketValidator.measurementCountOffset])
        guard (1...PacketValidator.maximumMeasurementCount).contains(measurementCount) else {
            return .invalid
        }

        let currentCounter = PacketValidator.decodeCounter(buffer)
        let currentTimer = PacketValidator.decodeTimer(buffer)
        let candidateCounter = PacketValidator.decodeCounter(chunk)
        let candidateTimer = PacketValidator.decodeTimer(chunk)
        guard candidateCounter > currentCounter,
              candidateTimer >= currentTimer else {
            return .invalid
        }

        guard chunk.count >= declaredLength else { return .incomplete }

        let packetBytes = Array(chunk[0..<declaredLength])
        if case .accepted = packetValidator.validate(packetBytes) {
            return .confirmed
        }

        return .invalid
    }

    private func scanForNestedOverlap(
        before expectedLength: Int,
        lookbackBytes: Int?,
        requireCandidateEndAfterExpectedLength: Bool
    ) -> NestedOverlapResult {
        guard expectedLength > 1 else { return .none }
        guard buffer.count >= Self.headerSize else { return .none }

        let searchStart = lookbackBytes.map { max(1, expectedLength - $0) } ?? 1
        let searchEnd = min(expectedLength, buffer.count - Self.headerSize + 1)
        guard searchStart < searchEnd else { return .none }

        var hasIncompleteCandidate = false
        for index in searchStart..<searchEnd where PacketValidator.hasStartMarker(buffer, at: index) {
            let candidate = Array(buffer[index..<buffer.count])
            let canUseCandidate = !requireCandidateEndAfterExpectedLength
                || candidateExtendsBeyondExpectedLength(at: index, expectedLength: expectedLength)
            switch classifyOverlapCandidate(candidate) {
            case .confirmed:
                if canUseCandidate {
                    return .confirmed(index: index)
                }
            case .incomplete:
                if canUseCandidate {
                    hasIncompleteCandidate = true
                }
            case .invalid:
                continue
            }
        }

        return hasIncompleteCandidate ? .pending : .none
    }

    private func candidateExtendsBeyondExpectedLength(at index: Int, expectedLength: Int) -> Bool {
        guard buffer.count >= index + PacketValidator.lengthOffset + 2 else {
            return index + Self.minimumPacketSize > expectedLength
        }

        let declaredLength = PacketValidator.decodeLength(buffer, at: index)
        guard (Self.minimumPacketSize...PacketValidator.maximumPacketSize).contains(declaredLength) else {
            return false
        }

        return index + declaredLength > expectedLength
    }

    private func makeOverlapDiagnostic(
        expectedLength: Int,
        nextStartIndex: Int,
        nextPacketBytes: [UInt8]? = nil
    ) -> PacketOverlapDiagnostic {
        let receivedBeforeNextStart = min(nextStartIndex, expectedLength)
        let missingBytes = max(expectedLength - receivedBeforeNextStart, 0)
        let nextCounter: UInt64?
        if let nextPacketBytes, nextPacketBytes.count >= Self.minimumPacketSize {
            nextCounter = PacketValidator.decodeCounter(nextPacketBytes)
        } else if buffer.count >= nextStartIndex + Self.minimumPacketSize {
            nextCounter = PacketValidator.decodeCounter(buffer, at: nextStartIndex)
        } else {
            nextCounter = nil
        }

        return PacketOverlapDiagnostic(
            currentCounter: buffer.count >= Self.minimumPacketSize ? PacketValidator.decodeCounter(buffer) : nil,
            nextCounter: nextCounter,
            expectedLength: expectedLength,
            receivedBeforeNextStart: receivedBeforeNextStart,
            missingBytes: missingBytes,
            notificationPayloadBytes: Self.assumedNotificationPayloadBytes
        )
    }

    private func startsWithHeaderPrefix(_ chunk: [UInt8]) -> Bool {
        let prefixSize = min(chunk.count, Self.headerSize)
        guard prefixSize > 0 else { return false }
        return chunk[0..<prefixSize].elementsEqual(PacketValidator.startMarker[0..<prefixSize])
    }

    private func findHeader(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= Self.headerSize else { return nil }

        for index in 0...(bytes.count - Self.headerSize) where PacketValidator.hasStartMarker(bytes, at: index) {
            return index
        }
        return nil
    }

    private static let headerSize = 4
    private static let minimumPacketSize = 16
    private static let maximumNestedOverlapLookbackBytes = 1_024
    private static let assumedNotificationPayloadBytes = 244

    private enum OverlapCandidateState {
        case incomplete
        case invalid
        case confirmed
    }

    private enum NestedOverlapResult {
        case none
        case pending
        case confirmed(index: Int)
    }
}
