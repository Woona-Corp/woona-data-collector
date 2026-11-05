import Foundation

enum PacketReplayMessage {
    static let emptyFile = "Replay file is empty"
    static let invalidFile = "Replay file is not a valid replay file"
    static let loadFailed = "Failed to load replay file"
    static let interrupted = "Replay interrupted"
    static let failed = "Replay failed"
}

enum PacketReplayRuntimeError: Error, Equatable, LocalizedError {
    case fragmentRejected
    case queueOverflow

    var errorDescription: String? {
        switch self {
        case .fragmentRejected:
            "Replay fragment was rejected by capture pipeline"
        case .queueOverflow:
            "Replay overflowed the capture queue"
        }
    }
}

actor PacketReplayController {
    private let submitFragment: @Sendable ([UInt8]) async -> PacketSubmitResult
    private let onReplayStarted: @Sendable () async -> Void
    private let onReplayCompleted: @Sendable () async -> Void
    private let onReplayStopped: @Sendable () async -> Void
    private let onError: @Sendable (String, Error?) async -> Void
    private let packetFileParser: RecordedPacketFileParser
    private let rawFragmentFileParser: RawFragmentFileParser
    private let chunkSize: Int
    private let chunkDelayMillis: UInt64
    private let packetIntervalMillis: UInt64
    private let maximumRawFragmentDelayMillis: UInt64

    private var replayTask: Task<Void, Never>?
    private var latestRequestID = UUID()

    init(
        submitFragment: @escaping @Sendable ([UInt8]) async -> PacketSubmitResult,
        onReplayStarted: @escaping @Sendable () async -> Void,
        onReplayCompleted: @escaping @Sendable () async -> Void,
        onReplayStopped: @escaping @Sendable () async -> Void,
        onError: @escaping @Sendable (String, Error?) async -> Void,
        packetFileParser: RecordedPacketFileParser = RecordedPacketFileParser(),
        rawFragmentFileParser: RawFragmentFileParser = RawFragmentFileParser(),
        chunkSize: Int = 247,
        chunkDelayMillis: UInt64 = 15,
        packetIntervalMillis: UInt64 = 1_000,
        maximumRawFragmentDelayMillis: UInt64? = nil
    ) {
        self.submitFragment = submitFragment
        self.onReplayStarted = onReplayStarted
        self.onReplayCompleted = onReplayCompleted
        self.onReplayStopped = onReplayStopped
        self.onError = onError
        self.packetFileParser = packetFileParser
        self.rawFragmentFileParser = rawFragmentFileParser
        self.chunkSize = chunkSize
        self.chunkDelayMillis = chunkDelayMillis
        self.packetIntervalMillis = packetIntervalMillis
        self.maximumRawFragmentDelayMillis = maximumRawFragmentDelayMillis ?? packetIntervalMillis
    }

    func startReplay(from fileURL: URL) async {
        let requestID = UUID()
        latestRequestID = requestID
        replayTask?.cancel()
        await replayTask?.value
        guard latestRequestID == requestID else { return }
        let submitFragment = submitFragment
        let onReplayStarted = onReplayStarted
        let onReplayCompleted = onReplayCompleted
        let onReplayStopped = onReplayStopped
        let onError = onError
        let packetFileParser = packetFileParser
        let rawFragmentFileParser = rawFragmentFileParser
        let chunkSize = chunkSize
        let chunkDelayMillis = chunkDelayMillis
        let packetIntervalMillis = packetIntervalMillis
        let maximumRawFragmentDelayMillis = maximumRawFragmentDelayMillis

        replayTask = Task.detached {
            #if os(iOS) || os(macOS)
            let didAccess = fileURL.startAccessingSecurityScopedResource()
            defer { if didAccess { fileURL.stopAccessingSecurityScopedResource() } }
            #endif
            var started = false
            do {
                try Task.checkCancellation()
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let prepared = directory.appendingPathComponent("replay.bin")
                try Self.copyReplaySource(from: fileURL, to: prepared)
                let input = try FileHandle(forReadingFrom: prepared)
                defer { try? input.close() }

                let prefix = try input.readReplayBytes(upToCount: RawFragmentFileStore.magicHeader.count)
                let isRaw = rawFragmentFileParser.hasMagicHeader(prefix)
                try input.seek(toOffset: 0)
                var recordCount = 0
                let countRecord: () throws -> Void = {
                    try Task.checkCancellation()
                    recordCount += 1
                }
                // Validate the complete immutable copy before publishing any capture data.
                if isRaw {
                    try rawFragmentFileParser.forEachFragment(read: input.readReplayBytes) { _ in try countRecord() }
                } else {
                    try packetFileParser.forEachPacket(read: input.readReplayBytes) { _ in try countRecord() }
                }
                try Task.checkCancellation()
                guard recordCount > 0 else {
                    await onError(PacketReplayMessage.emptyFile, nil)
                    await onReplayStopped()
                    return
                }
                try input.seek(toOffset: 0)
                await onReplayStarted()
                started = true
                try Task.checkCancellation()
                if isRaw {
                    let isV2 = try rawFragmentFileParser.readMagicHeader(read: input.readReplayBytes)
                    var offset = RawFragmentFileStore.magicHeader.count
                    try await Self.replayRawFragments(
                        next: { try rawFragmentFileParser.readFragment(read: input.readReplayBytes, isV2: isV2, offset: &offset) },
                        maximumFragmentDelayMillis: maximumRawFragmentDelayMillis,
                        submitFragment: submitFragment
                    )
                } else {
                    var offset = 0
                    try await Self.replayPackets(
                        next: { try packetFileParser.readPacket(read: input.readReplayBytes, offset: &offset) },
                        chunkSize: chunkSize,
                        chunkDelayMillis: chunkDelayMillis,
                        packetIntervalMillis: packetIntervalMillis,
                        submitFragment: submitFragment
                    )
                }
                try Task.checkCancellation()
                await onReplayCompleted()
            } catch is CancellationError {
                await onReplayStopped()
            } catch {
                let message: String
                if started {
                    message = PacketReplayMessage.failed
                } else if error is RecordedPacketFileParserError || error is RawFragmentFileParserError {
                    message = PacketReplayMessage.invalidFile
                } else {
                    message = PacketReplayMessage.loadFailed
                }
                await onError(message, error)
                await onReplayStopped()
            }
        }
    }

    private static func copyReplaySource(from source: URL, to target: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        while true {
            try Task.checkCancellation()
            let chunk = try input.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { return }
            try output.write(contentsOf: chunk)
        }
    }

    func stop() async {
        let requestID = UUID()
        latestRequestID = requestID
        // Retain the draining task so concurrent stop/close calls also await it.
        replayTask?.cancel()
        await replayTask?.value
        if latestRequestID == requestID { replayTask = nil }
    }

    func close() async {
        await stop()
    }

    private static func replayPackets(
        next: () throws -> [UInt8]?,
        chunkSize: Int,
        chunkDelayMillis: UInt64,
        packetIntervalMillis: UInt64,
        submitFragment: @Sendable ([UInt8]) async -> PacketSubmitResult
    ) async throws {
        let resolvedChunkSize = max(1, chunkSize)

        while let packet = try next() {
            try Task.checkCancellation()
            let packetStartNanos = DispatchTime.now().uptimeNanoseconds

            var offset = 0
            while offset < packet.count {
                try Task.checkCancellation()
                let endOffset = min(offset + resolvedChunkSize, packet.count)
                let result = await submitFragment(Array(packet[offset..<endOffset]))
                try Task.checkCancellation()

                switch result {
                case .accepted:
                    break
                case .rejected:
                    throw PacketReplayRuntimeError.fragmentRejected
                case .overflow:
                    throw PacketReplayRuntimeError.queueOverflow
                }

                offset = endOffset
                if offset < packet.count {
                    try await sleep(milliseconds: chunkDelayMillis)
                }
            }

            let elapsedMillis = (DispatchTime.now().uptimeNanoseconds - packetStartNanos) / 1_000_000
            if packetIntervalMillis > elapsedMillis {
                try await sleep(milliseconds: packetIntervalMillis - elapsedMillis)
            }
        }
    }

    private static func replayRawFragments(
        next: () throws -> RawFragmentRecord?,
        maximumFragmentDelayMillis: UInt64,
        submitFragment: @Sendable ([UInt8]) async -> PacketSubmitResult
    ) async throws {
        var current = try next()
        while let fragment = current {
            try Task.checkCancellation()
            let result = await submitFragment(fragment.bytes)
            try Task.checkCancellation()
            switch result {
            case .accepted:
                break
            case .rejected:
                throw PacketReplayRuntimeError.fragmentRejected
            case .overflow:
                throw PacketReplayRuntimeError.queueOverflow
            }
            current = try next()
            if let following = current {
                try await sleep(milliseconds: rawReplayDelayMillis(
                    from: fragment, to: following, maximumDelayMillis: maximumFragmentDelayMillis
                ))
            }
        }
    }

    private static func rawReplayDelayMillis(
        from current: RawFragmentRecord,
        to next: RawFragmentRecord,
        maximumDelayMillis: UInt64
    ) -> UInt64 {
        guard maximumDelayMillis > 0 else { return 0 }
        guard next.receivedAtMillis > current.receivedAtMillis else { return 0 }

        return min(UInt64(next.receivedAtMillis - current.receivedAtMillis), maximumDelayMillis)
    }

    private static func sleep(milliseconds: UInt64) async throws {
        guard milliseconds > 0 else { return }
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }

}
