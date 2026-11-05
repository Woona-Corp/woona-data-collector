import XCTest
@testable import Woona

final class PacketReplayControllerTests: XCTestCase {
    func testEmptyReplayFileErrorsAndStops() async throws {
        let events = ReplayEventBox()
        let controller = PacketReplayController(
            submitFragment: { _ in .accepted },
            onReplayStarted: { await events.append("started") },
            onReplayCompleted: { await events.append("completed") },
            onReplayStopped: { await events.append("stopped") },
            onError: { message, _ in await events.append("error:\(message)") },
            packetIntervalMillis: 0
        )

        await controller.startReplay(from: try replayFile([]))
        await events.waitUntilContains("stopped")

        let recordedEvents = await events.values
        XCTAssertEqual(recordedEvents, ["error:\(PacketReplayMessage.emptyFile)", "stopped"])
    }

    func testInvalidReplayFileErrorsAndStops() async throws {
        let events = ReplayEventBox()
        let controller = PacketReplayController(
            submitFragment: { _ in .accepted },
            onReplayStarted: { await events.append("started") },
            onReplayCompleted: { await events.append("completed") },
            onReplayStopped: { await events.append("stopped") },
            onError: { message, _ in await events.append("error:\(message)") },
            packetIntervalMillis: 0
        )

        await controller.startReplay(from: try replayFile([0x01, 0x02, 0x03]))
        await events.waitUntilContains("stopped")

        let recordedEvents = await events.values
        XCTAssertEqual(recordedEvents, ["error:\(PacketReplayMessage.invalidFile)", "stopped"])
    }

    func testValidDumpReplaysThroughNormalCaptureProcessing() async throws {
        let directory = try temporaryDirectory()
        let updates = UpdateBox()
        let processor = PacketCaptureProcessor(
            packetFileStore: PacketFileStore(directory: directory, timestampProvider: { 10 }),
            rawFragmentFileStore: RawFragmentFileStore(directory: directory, timestampProvider: { 20 }),
            diagnosticLogFileStore: DiagnosticLogFileStore(directory: directory, timestampProvider: { 30 }),
            wallClockMillisProvider: { 1_000 },
            fragmentTimestampProvider: { 2_000 },
            onUpdate: { update in await updates.append(update) },
            onError: { message, error in
                XCTFail("\(message): \(String(describing: error))")
            }
        )
        let events = ReplayEventBox()
        let controller = PacketReplayController(
            submitFragment: { fragment in await processor.submit(fragment) },
            onReplayStarted: { await events.append("started") },
            onReplayCompleted: { await events.append("completed") },
            onReplayStopped: { await events.append("stopped") },
            onError: { message, _ in await events.append("error:\(message)") },
            chunkSize: 5,
            chunkDelayMillis: 0,
            packetIntervalMillis: 0
        )
        let first = makeTestPacket(
            counter: 1,
            timerMillis: 100,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 2, channelSamples: [[10]])]
        )
        let second = makeTestPacket(
            counter: 2,
            timerMillis: 200,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 2, channelSamples: [[20]])]
        )

        await controller.startReplay(from: try replayFile(first + second))
        await events.waitUntilContains("completed")
        await processor.flush()

        let recordedEvents = await events.values
        XCTAssertEqual(recordedEvents, ["started", "completed"])
        let lastUpdate = await updates.values.last
        XCTAssertEqual(lastUpdate?.packetsReceived, 2)

        let packetFileURL = await processor.currentPacketFile()
        let packetFile = try XCTUnwrap(packetFileURL)
        XCTAssertEqual(try Data(contentsOf: packetFile), Data(first + second))
    }

    func testRawFragmentReplayPreservesAssemblerBoundaryFailures() async throws {
        let directory = try temporaryDirectory()
        let updates = UpdateBox()
        let processor = PacketCaptureProcessor(
            packetFileStore: PacketFileStore(directory: directory, timestampProvider: { 10 }),
            rawFragmentFileStore: RawFragmentFileStore(directory: directory, timestampProvider: { 20 }),
            diagnosticLogFileStore: DiagnosticLogFileStore(directory: directory, timestampProvider: { 30 }),
            wallClockMillisProvider: { 1_000 },
            fragmentTimestampProvider: { 2_000 },
            onUpdate: { update in await updates.append(update) },
            onError: { message, error in
                XCTFail("\(message): \(String(describing: error))")
            }
        )
        let events = ReplayEventBox()
        let controller = PacketReplayController(
            submitFragment: { fragment in await processor.submit(fragment) },
            onReplayStarted: { await events.append("started") },
            onReplayCompleted: { await events.append("completed") },
            onReplayStopped: { await events.append("stopped") },
            onError: { message, _ in await events.append("error:\(message)") },
            chunkDelayMillis: 0,
            packetIntervalMillis: 0
        )
        let first = makeTestPacket(
            counter: 1,
            timerMillis: 100,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 2, channelSamples: [[10, 20]])]
        )
        let corrupted = makeTestPacket(
            counter: 2,
            timerMillis: 1_100,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 2, channelSamples: [[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]])]
        )
        let recovered = makeTestPacket(
            counter: 3,
            timerMillis: 2_100,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 2, channelSamples: [[30, 40]])]
        )
        let corruptedPrefix = Array(corrupted.dropLast(PacketValidator.minimumPacketSize))
        let recoveredHeader = Array(recovered.prefix(PacketValidator.minimumPacketSize))
        let rawFile = RawFragmentFileStore.magicHeader
            + makeReplayRawFragmentRecord(sequence: 0, receivedAtMillis: 10_000, bytes: first)
            + makeReplayRawFragmentRecord(sequence: 1, receivedAtMillis: 11_000, bytes: corruptedPrefix + recoveredHeader)
            + makeReplayRawFragmentRecord(
                sequence: 2,
                receivedAtMillis: 11_015,
                bytes: Array(recovered.dropFirst(PacketValidator.minimumPacketSize))
            )

        await controller.startReplay(from: try replayFile(rawFile))
        await events.waitUntilContains("completed")
        await processor.flush()

        let recordedEvents = await events.values
        let recordedUpdates = await updates.values
        XCTAssertEqual(recordedEvents, ["started", "completed"])
        let overlapMessage = PacketAssemblyFailureReason.overlappingPacketStart().rawValue
        XCTAssertTrue(recordedUpdates.contains { $0.lastPacketIssue?.hasPrefix(overlapMessage) == true })
        XCTAssertEqual(recordedUpdates.last?.packetsReceived, 2)
        XCTAssertEqual(recordedUpdates.last?.packetsLost, 1)

        let packetFileURL = await processor.currentPacketFile()
        let packetFile = try XCTUnwrap(packetFileURL)
        XCTAssertEqual(try Data(contentsOf: packetFile), Data(first + recovered))
    }

    func testRawFragmentReplayTimingCapIsIndependentFromChunkDelay() async throws {
        let events = ReplayEventBox()
        let submitted = SubmittedFragmentBox()
        let rawFile = RawFragmentFileStore.magicHeader
            + makeReplayRawFragmentRecord(sequence: 0, receivedAtMillis: 1_000, bytes: [0x01])
            + makeReplayRawFragmentRecord(sequence: 1, receivedAtMillis: 2_000, bytes: [0x02])
        let controller = PacketReplayController(
            submitFragment: { fragment in
                await submitted.append(fragment)
                return .accepted
            },
            onReplayStarted: { await events.append("started") },
            onReplayCompleted: { await events.append("completed") },
            onReplayStopped: { await events.append("stopped") },
            onError: { message, _ in await events.append("error:\(message)") },
            chunkDelayMillis: 10_000,
            packetIntervalMillis: 0
        )

        await controller.startReplay(from: try replayFile(rawFile))
        await events.waitUntilContains("completed", timeoutNanoseconds: 300_000_000)

        let submittedFragments = await submitted.values
        let recordedEvents = await events.values
        XCTAssertEqual(submittedFragments, [[0x01], [0x02]])
        XCTAssertEqual(recordedEvents, ["started", "completed"])
    }

    func testRuntimeFailureStopsReplayState() async throws {
        let events = ReplayEventBox()
        let controller = PacketReplayController(
            submitFragment: { _ in .overflow },
            onReplayStarted: { await events.append("started") },
            onReplayCompleted: { await events.append("completed") },
            onReplayStopped: { await events.append("stopped") },
            onError: { message, _ in await events.append("error:\(message)") },
            packetIntervalMillis: 0
        )

        await controller.startReplay(from: try replayFile(makeTestPacket(counter: 1, measurementCount: 1)))
        await events.waitUntilContains("stopped")

        let recordedEvents = await events.values
        XCTAssertEqual(recordedEvents, ["started", "error:\(PacketReplayMessage.failed)", "stopped"])
    }

    func testReplayCancellationStopsWithoutCompleting() async throws {
        let events = ReplayEventBox()
        let first = makeTestPacket(counter: 1, measurementCount: 1)
        let second = makeTestPacket(counter: 2, measurementCount: 1)
        let controller = PacketReplayController(
            submitFragment: { _ in .accepted },
            onReplayStarted: { await events.append("started") },
            onReplayCompleted: { await events.append("completed") },
            onReplayStopped: { await events.append("stopped") },
            onError: { message, _ in await events.append("error:\(message)") },
            chunkSize: 247,
            chunkDelayMillis: 0,
            packetIntervalMillis: 10_000
        )

        await controller.startReplay(from: try replayFile(first + second))
        await events.waitUntilContains("started")
        await controller.stop()

        let recordedEvents = await events.values
        XCTAssertEqual(recordedEvents, ["started", "stopped"])
    }

    func testTruncatedTailDoesNotSubmitValidPrefix() async throws {
        let events = ReplayEventBox()
        let submitted = SubmittedFragmentBox()
        let controller = PacketReplayController(
            submitFragment: { bytes in await submitted.append(bytes); return .accepted },
            onReplayStarted: { await events.append("started") },
            onReplayCompleted: { await events.append("completed") },
            onReplayStopped: { await events.append("stopped") },
            onError: { message, _ in await events.append("error:\(message)") },
            packetIntervalMillis: 0
        )
        let bytes = makeTestPacket(counter: 1, measurementCount: 1) + [0x33, 0x99]
        let file = try replayFile(bytes)
        await controller.startReplay(from: file)
        await events.waitUntilContains("stopped")
        await controller.stop()
        let fragments = await submitted.values
        let recorded = await events.values
        XCTAssertTrue(fragments.isEmpty)
        XCTAssertEqual(recorded, ["error:\(PacketReplayMessage.invalidFile)", "stopped"])
        XCTAssertEqual(try Data(contentsOf: file), Data(bytes))
    }

    func testMissingReplaySourceReportsLoadFailure() async throws {
        let events = ReplayEventBox()
        let directory = try temporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let controller = PacketReplayController(
            submitFragment: { _ in .accepted },
            onReplayStarted: { await events.append("started") },
            onReplayCompleted: { await events.append("completed") },
            onReplayStopped: { await events.append("stopped") },
            onError: { message, _ in await events.append("error:\(message)") }
        )
        await controller.startReplay(from: directory.appendingPathComponent("missing.bin"))
        await events.waitUntilContains("stopped")
        await controller.stop()
        let recorded = await events.values
        XCTAssertEqual(recorded, ["error:\(PacketReplayMessage.loadFailed)", "stopped"])
    }

    func testConcurrentStartsKeepOnlyLatestReplay() async throws {
        let gate = ReplaySubmissionGate()
        let controller = gatedReplayController(gate)
        let first = try rawReplayFile(marker: 1)
        let replaced = try rawReplayFile(marker: 2)
        let latest = try rawReplayFile(marker: 3)
        await controller.startReplay(from: first)
        await gate.events.waitUntilContains("submitted:1")
        let replacing = Task { await controller.startReplay(from: replaced) }
        await gate.events.waitUntilContains("cancelled")

        let entered = expectation(description: "Latest request entered the controller")
        let startingLatest = Task {
            await requestReplay(on: controller, from: latest, entered: entered)
        }
        await fulfillment(of: [entered], timeout: 1)
        await gate.release()
        await replacing.value
        await startingLatest.value
        await gate.events.waitUntilContains("submitted:3")
        await controller.stop()
        try await Task.sleep(nanoseconds: 250_000_000)

        let submitted = await gate.values
        XCTAssertEqual(submitted, [[1], [3]])
    }

    func testStopSupersedesPendingStartAndWaitsForFragment() async throws {
        let gate = ReplaySubmissionGate()
        let controller = gatedReplayController(gate)
        await controller.startReplay(from: try rawReplayFile(marker: 1))
        await gate.events.waitUntilContains("submitted:1")
        let replacement = try rawReplayFile(marker: 2)
        let replacing = Task { await controller.startReplay(from: replacement) }
        await gate.events.waitUntilContains("cancelled")

        let returned = expectation(description: "Stop must await the blocked fragment")
        returned.isInverted = true
        let stopping = Task {
            await controller.stop()
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 0.1)
        await gate.release()
        await replacing.value
        await stopping.value
        await controller.stop()

        let submitted = await gate.values
        XCTAssertEqual(submitted, [[1]])
    }

    func testCloseWaitsForReplayAlreadyBeingStopped() async throws {
        let gate = ReplaySubmissionGate()
        let controller = gatedReplayController(gate)
        await controller.startReplay(from: try rawReplayFile(marker: 1))
        await gate.events.waitUntilContains("submitted:1")
        let stopping = Task { await controller.stop() }
        await gate.events.waitUntilContains("cancelled")

        let returned = expectation(description: "Close must await the blocked fragment")
        returned.isInverted = true
        let closing = Task {
            await controller.close()
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 0.1)
        await gate.release()
        await stopping.value
        await closing.value

        let submitted = await gate.values
        XCTAssertEqual(submitted, [[1]])
    }

    private func gatedReplayController(_ gate: ReplaySubmissionGate) -> PacketReplayController {
        PacketReplayController(
            submitFragment: { await gate.submit($0) },
            onReplayStarted: {},
            onReplayCompleted: {},
            onReplayStopped: {},
            onError: { message, _ in XCTFail(message) },
            packetIntervalMillis: 200
        )
    }

    private func rawReplayFile(marker: UInt8) throws -> URL {
        try replayFile(RawFragmentFileStore.magicHeader
            + makeReplayRawFragmentRecord(sequence: 0, receivedAtMillis: 0, bytes: [marker])
            + makeReplayRawFragmentRecord(sequence: 1, receivedAtMillis: 200, bytes: [marker]))
    }

    private func replayFile(_ bytes: [UInt8]) throws -> URL {
        let directory = try temporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("input.bin")
        try Data(bytes).write(to: file)
        return file
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("woona-replay-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private func requestReplay(
    on controller: isolated PacketReplayController,
    from file: URL,
    entered: XCTestExpectation
) async {
    entered.fulfill()
    await controller.startReplay(from: file)
}

private actor ReplaySubmissionGate {
    let events = ReplayEventBox()
    private(set) var values: [[UInt8]] = []
    private var continuation: CheckedContinuation<Void, Never>?

    func submit(_ bytes: [UInt8]) async -> PacketSubmitResult {
        values.append(bytes)
        await events.append("submitted:\(bytes[0])")
        if bytes == [1], values.count == 1 {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation = $0 }
            } onCancel: {
                Task { await self.events.append("cancelled") }
            }
        }
        return .accepted
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor ReplayEventBox {
    private var recordedValues: [String] = []

    var values: [String] {
        recordedValues
    }

    func append(_ value: String) {
        recordedValues.append(value)
    }

    func waitUntilContains(
        _ value: String,
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !recordedValues.contains(value), DispatchTime.now().uptimeNanoseconds < deadline {
            await Task.yield()
        }
        XCTAssertTrue(recordedValues.contains(value), file: file, line: line)
    }
}

private actor UpdateBox {
    private var recordedValues: [PacketProcessingUpdate] = []

    var values: [PacketProcessingUpdate] {
        recordedValues
    }

    func append(_ value: PacketProcessingUpdate) {
        recordedValues.append(value)
    }
}

private actor SubmittedFragmentBox {
    private var recordedValues: [[UInt8]] = []

    var values: [[UInt8]] {
        recordedValues
    }

    func append(_ value: [UInt8]) {
        recordedValues.append(value)
    }
}

private func makeReplayRawFragmentRecord(sequence: Int64, receivedAtMillis: Int64, bytes: [UInt8]) -> [UInt8] {
    var record: [UInt8] = []
    record.appendBigEndianInt64(sequence)
    record.appendBigEndianInt64(receivedAtMillis)
    record.appendBigEndianInt64(0)
    record.appendBigEndianInt32(Int32(bytes.count))
    record.append(contentsOf: bytes)
    return record
}
