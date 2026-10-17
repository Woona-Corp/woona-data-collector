import XCTest
@testable import Woona

final class PacketCaptureProcessorTests: XCTestCase {
    func testRawWriteFailureRejectsFragmentAndClosesIngress() async throws {
        let directory = try temporaryDirectory()
        let raw = RawFragmentFileStore(directory: directory)
        try raw.close()
        let errors = StorageErrorBox()
        let processor = PacketCaptureProcessor(
            packetFileStore: PacketFileStore(directory: directory),
            rawFragmentFileStore: raw,
            diagnosticLogFileStore: DiagnosticLogFileStore(directory: directory),
            onUpdate: { _ in XCTFail("Failed raw bytes must not become accepted packets") },
            onError: { message, _ in await errors.append(message) }
        )

        let first = await processor.submit([1])
        let second = await processor.submit([2])
        await processor.finishCaptureSession()

        let messages = await errors.messages
        let hasOpenFiles = await processor.hasOpenOutputFiles()
        XCTAssertEqual(first, .rejected)
        XCTAssertEqual(second, .rejected)
        XCTAssertEqual(messages, ["Failed to persist raw fragment"])
        XCTAssertFalse(hasOpenFiles)
    }

    func testPacketWriteFailurePreservesRawAndStopsCapture() async throws {
        let directory = try temporaryDirectory()
        let blockedDirectory = directory.appendingPathComponent("blocked")
        try Data([1]).write(to: blockedDirectory)
        let errors = StorageErrorBox()
        let processor = PacketCaptureProcessor(
            packetFileStore: PacketFileStore(directory: blockedDirectory),
            rawFragmentFileStore: RawFragmentFileStore(directory: directory),
            diagnosticLogFileStore: DiagnosticLogFileStore(directory: directory),
            onUpdate: { _ in },
            onError: { message, _ in await errors.append(message) }
        )
        let packet = makeTestPacket(counter: 1, timerMillis: 100, measurementCount: 1,
                                    blocks: [makeSensorBlock(sensorType: 1, channelSamples: [[]])])
        await processor.submit(packet)
        await processor.finishCaptureSession()

        let result = await processor.submit(packet)
        let messages = await errors.messages
        let rawURL = await processor.currentRawFile()
        let raw = try Data(contentsOf: XCTUnwrap(rawURL))
        let hasOpenFiles = await processor.hasOpenOutputFiles()
        XCTAssertEqual(result, .rejected)
        XCTAssertEqual(messages, ["Failed to append validated packet"])
        XCTAssertEqual(Array(raw.suffix(packet.count)), packet)
        XCTAssertFalse(hasOpenFiles)
    }

    func testFlushFailureIsTerminalAndReportedOnce() async throws {
        let directory = try temporaryDirectory()
        let packets = PacketFileStore(directory: directory)
        let errors = StorageErrorBox()
        let processor = PacketCaptureProcessor(
            packetFileStore: packets,
            rawFragmentFileStore: RawFragmentFileStore(directory: directory),
            diagnosticLogFileStore: DiagnosticLogFileStore(directory: directory),
            onUpdate: { _ in },
            onError: { message, _ in await errors.append(message) }
        )
        try packets.close()
        await processor.flush()
        let result = await processor.submit([1])
        await processor.finishCaptureSession()

        let messages = await errors.messages
        XCTAssertEqual(result, .rejected)
        XCTAssertEqual(messages, ["Failed to flush buffered output"])
    }

    func testFinishFailureStillClosesOtherWritersAndReportsBeforeReturning() async throws {
        let directory = try temporaryDirectory()
        let diagnostics = DiagnosticLogFileStore(directory: directory)
        let errors = StorageErrorBox()
        let processor = PacketCaptureProcessor(
            packetFileStore: PacketFileStore(directory: directory),
            rawFragmentFileStore: RawFragmentFileStore(directory: directory),
            diagnosticLogFileStore: diagnostics,
            onUpdate: { _ in },
            onError: { message, _ in await errors.append(message) }
        )
        let packet = makeTestPacket(counter: 1, timerMillis: 100, measurementCount: 1,
                                    blocks: [makeSensorBlock(sensorType: 1, channelSamples: [[]])])
        await processor.submit(packet)
        await processor.flush()
        try diagnostics.close()
        await processor.finishCaptureSession()

        let messages = await errors.messages
        let hasOpenFiles = await processor.hasOpenOutputFiles()
        let packetURL = await processor.currentPacketFile()
        XCTAssertEqual(messages, ["Failed to finish capture session"])
        XCTAssertFalse(hasOpenFiles)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(packetURL)), Data(packet))
    }

    func testSubmitterOverflowStillPersistsReceivedBytes() async throws {
        let harness = try makeHarness()
        let submitter = PacketFragmentSubmitter(packetProcessor: harness.processor,maxPendingFragments:0,onOverflow:{})
        let packet = makeTestPacket(counter:1,timerMillis:100,measurementCount:1,blocks:[makeSensorBlock(sensorType:1,channelSamples:[[10]])])
        submitter.enqueue(packet,receivedAtMonotonicNs:1_000)
        await submitter.finishCaptureProcessing()
        let rawURL = await harness.processor.currentRawFile()
        let raw = try XCTUnwrap(rawURL)
        XCTAssertEqual(Array(try Data(contentsOf: raw).suffix(packet.count)),packet)
    }

    func testAcceptedTimingUsesCompletionFragmentAndResets() async throws {
        let harness = try makeHarness()
        let packet = makeTestPacket(counter: 1, timerMillis: 100, measurementCount: 1,
                                    blocks: [makeSensorBlock(sensorType: 1, channelSamples: [[10]])])
        await harness.processor.submit(Array(packet.prefix(8)), receivedAtMonotonicNs: 1_000)
        await harness.processor.flush()
        let incomplete = await harness.processor.acceptedPacketTiming()
        XCTAssertNil(incomplete)
        await harness.processor.submit(Array(packet.dropFirst(8)), receivedAtMonotonicNs: 4_000)
        await harness.processor.finishCaptureSession()
        let timing = await harness.processor.acceptedPacketTiming()
        XCTAssertEqual(timing?.first, 4_000)
        XCTAssertEqual(timing?.last, 4_000)
        XCTAssertEqual(timing?.deviceTimer, 100)
        await harness.processor.resetSession()
        let reset = await harness.processor.acceptedPacketTiming()
        XCTAssertNil(reset)
    }

    func testSubmitWritesRawFragmentBeforeAcceptedPacket() async throws {
        let harness = try makeHarness()
        let packet = makeTestPacket(
            counter: 10,
            timerMillis: 50,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 1, channelSamples: [[]])]
        )

        let result = await harness.processor.submit(packet)
        await harness.processor.flush()

        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(harness.updates.single().packetsReceived, 1)
        let packetFileURL = await harness.processor.currentPacketFile()
        let packetFile = try XCTUnwrap(packetFileURL)
        XCTAssertEqual(try Data(contentsOf: packetFile), Data(packet))

        let rawFileURL = await harness.processor.currentRawFile()
        let rawFile = try XCTUnwrap(rawFileURL)
        let rawBytes = try [UInt8](Data(contentsOf: rawFile))
        XCTAssertEqual(Array(rawBytes.prefix(RawFragmentFileStore.magicHeader.count)), RawFragmentFileStore.magicHeader)
        XCTAssertEqual(Array(rawBytes.suffix(packet.count)), packet)
    }

    func testTimerRegressionRejectsPacketAndDoesNotWriteIt() async throws {
        let harness = try makeHarness()
        let first = makeTestPacket(
            counter: 10,
            timerMillis: 100,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 1, channelSamples: [[]])]
        )
        let regressed = makeTestPacket(
            counter: 11,
            timerMillis: 90,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 1, channelSamples: [[]])]
        )

        await harness.processor.submit(first)
        await harness.processor.submit(regressed)
        await harness.processor.flush()

        let lastUpdate = harness.updates.last!
        XCTAssertEqual(lastUpdate.packetsReceived, 1)
        XCTAssertEqual(lastUpdate.packetsRejected, 1)
        XCTAssertEqual(lastUpdate.timerRegressionRejects, 1)
        XCTAssertEqual(lastUpdate.lastPacketIssue, "Packet timer regressed")
        let packetFileURL = await harness.processor.currentPacketFile()
        let packetFile = try XCTUnwrap(packetFileURL)
        XCTAssertEqual(try Data(contentsOf: packetFile), Data(first))
    }

    func testCounterGapLossAndChartSegmentBreak() async throws {
        let harness = try makeHarness()
        let first = makeTestPacket(
            counter: 10,
            timerMillis: 50,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 2, channelSamples: [[10, 20]])]
        )
        let second = makeTestPacket(
            counter: 12,
            timerMillis: 90,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 2, channelSamples: [[30, 40]])]
        )

        await harness.processor.submit(first)
        await harness.processor.submit(second)
        await harness.processor.flush()

        let lastUpdate = harness.updates.last!
        XCTAssertEqual(lastUpdate.packetsReceived, 2)
        XCTAssertEqual(lastUpdate.packetsLost, 1)
        XCTAssertTrue(lastUpdate.diagnosticEvents.contains { $0.type == .gap && $0.message.contains("lost=1") })

        let points = try XCTUnwrap(lastUpdate.chartSamplesByStream[ChartStreamKey(sensorType: 2, channel: 1)])
        XCTAssertEqual(points.map(\.timeMillis), [90, 90])
        XCTAssertTrue(points.first?.startsNewSegment == true)
    }

    func testRejectionBreakdownAccumulatesByReason() async throws {
        let harness = try makeHarness()
        let invalidMeasurement = makeTestPacket(counter: 1, timerMillis: 1, measurementCount: 0)
        let accepted = makeTestPacket(
            counter: 2,
            timerMillis: 10,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 1, channelSamples: [[]])]
        )
        let timerRegression = makeTestPacket(
            counter: 3,
            timerMillis: 9,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 1, channelSamples: [[]])]
        )

        await harness.processor.submit(invalidMeasurement)
        await harness.processor.submit(accepted)
        await harness.processor.submit(timerRegression)
        await harness.processor.flush()

        let lastBreakdown = try XCTUnwrap(harness.updates.last?.rejectionBreakdown)
        XCTAssertTrue(lastBreakdown.contains("Invalid measurement count: 1"))
        XCTAssertTrue(lastBreakdown.contains("Packet timer regressed: 1"))
        XCTAssertEqual(harness.updates.last?.packetsRejected, 2)
    }

    func testChartStreamKeysAndInterpolatedTiming() async throws {
        let harness = try makeHarness()
        let first = makeTestPacket(
            counter: 10,
            timerMillis: 50,
            measurementCount: 2,
            blocks: [
                makeSensorBlock(sensorType: 2, channelSamples: [[10, 20], [30, 40]]),
                makeSensorBlock(sensorType: 4, channelSamples: [[50, 60]])
            ]
        )
        let second = makeTestPacket(
            counter: 11,
            timerMillis: 70,
            measurementCount: 2,
            blocks: [
                makeSensorBlock(sensorType: 2, channelSamples: [[11, 21], [31, 41]]),
                makeSensorBlock(sensorType: 4, channelSamples: [[51, 61]])
            ]
        )

        await harness.processor.submit(first)
        await harness.processor.submit(second)
        await harness.processor.flush()

        let lastUpdate = harness.updates.last!
        XCTAssertEqual(
            Set(lastUpdate.chartSamplesByStream.keys),
            [
                ChartStreamKey(sensorType: 2, channel: 1),
                ChartStreamKey(sensorType: 2, channel: 2),
                ChartStreamKey(sensorType: 4, channel: 1)
            ]
        )
        XCTAssertEqual(
            lastUpdate.chartSamplesByStream[ChartStreamKey(sensorType: 2, channel: 1)]?.map(\.timeMillis),
            [60, 70]
        )
    }

    func testResetClearsCountersAndStartsNewOutputFiles() async throws {
        var packetTimestamp: Int64 = 100
        var rawTimestamp: Int64 = 200
        var logTimestamp: Int64 = 300
        let harness = try makeHarness(
            packetTimestampProvider: { packetTimestamp },
            rawTimestampProvider: { rawTimestamp },
            logTimestampProvider: { logTimestamp }
        )

        let first = makeTestPacket(
            counter: 10,
            timerMillis: 50,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 1, channelSamples: [[]])]
        )
        await harness.processor.submit(first)
        await harness.processor.flush()
        let firstPacketFile = await harness.processor.currentPacketFile()
        let firstRawFile = await harness.processor.currentRawFile()
        let firstLogFile = await harness.processor.currentLogFile()

        packetTimestamp = 101
        rawTimestamp = 201
        logTimestamp = 301
        await harness.processor.resetSession()
        let second = makeTestPacket(
            counter: 1,
            timerMillis: 10,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 1, channelSamples: [[]])]
        )
        await harness.processor.submit(second)
        await harness.processor.flush()

        let secondPacketFile = await harness.processor.currentPacketFile()
        let secondRawFile = await harness.processor.currentRawFile()
        let secondLogFile = await harness.processor.currentLogFile()
        XCTAssertNotEqual(secondPacketFile, firstPacketFile)
        XCTAssertNotEqual(secondRawFile, firstRawFile)
        XCTAssertNotEqual(secondLogFile, firstLogFile)
        XCTAssertEqual(harness.updates.last?.packetsReceived, 1)
        XCTAssertEqual(harness.updates.last?.packetsLost, 0)
        XCTAssertEqual(harness.updates.last?.diagnosticEvents.first?.id, 0)
    }

    func testResetInvalidatesQueuedFragmentsBeforeWaitingForActiveDrain() async throws {
        var packetTimestamp: Int64 = 100
        var rawTimestamp: Int64 = 200
        var logTimestamp: Int64 = 300
        let directory = try temporaryDirectory()
        let updates = BlockingUpdateBox()
        let processor = PacketCaptureProcessor(
            packetFileStore: PacketFileStore(directory: directory, timestampProvider: { packetTimestamp }),
            rawFragmentFileStore: RawFragmentFileStore(directory: directory, timestampProvider: { rawTimestamp }),
            diagnosticLogFileStore: DiagnosticLogFileStore(directory: directory, timestampProvider: { logTimestamp }),
            wallClockMillisProvider: { 1_000 },
            fragmentTimestampProvider: { 2_000 },
            onUpdate: { update in
                await updates.append(update)
            },
            onError: { message, error in
                XCTFail("\(message): \(String(describing: error))")
            }
        )
        let first = makeTestPacket(
            counter: 1,
            timerMillis: 100,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 1, channelSamples: [[]])]
        )
        let queuedOld = makeTestPacket(
            counter: 2,
            timerMillis: 200,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 1, channelSamples: [[]])]
        )
        let newSessionPacket = makeTestPacket(
            counter: 1,
            timerMillis: 10,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 1, channelSamples: [[]])]
        )

        await processor.submit(first)
        await updates.waitUntilFirstUpdateIsBlocked()
        await processor.submit(queuedOld)
        let initialSessionId = await processor.sessionIdForTesting()

        packetTimestamp = 101
        rawTimestamp = 201
        logTimestamp = 301
        let resetTask = Task {
            await processor.resetSession()
        }
        while await processor.sessionIdForTesting() == initialSessionId {
            await Task.yield()
        }
        let pendingQueueDepth = await processor.pendingQueueDepthForTesting()
        XCTAssertEqual(pendingQueueDepth, 0)
        await updates.releaseFirstUpdate()
        await resetTask.value

        await processor.submit(newSessionPacket)
        await processor.flush()

        let recordedUpdates = await updates.values
        XCTAssertFalse(recordedUpdates.contains { $0.packetsReceived == 2 })
        XCTAssertEqual(recordedUpdates.last?.packetsReceived, 1)

        let packetFileURL = await processor.currentPacketFile()
        let packetFile = try XCTUnwrap(packetFileURL)
        XCTAssertEqual(try Data(contentsOf: packetFile), Data(newSessionPacket))
    }

    func testStopPreventsNewFragmentsFromBeingAccepted() async throws {
        let harness = try makeHarness()
        let packet = makeTestPacket(
            counter: 10,
            timerMillis: 50,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 1, channelSamples: [[]])]
        )

        await harness.processor.stopCapture()
        let result = await harness.processor.submit(packet)

        XCTAssertEqual(result, .rejected)
        XCTAssertTrue(harness.updates.isEmpty)
        let rawFile = await harness.processor.currentRawFile()
        let packetFile = await harness.processor.currentPacketFile()
        XCTAssertNil(rawFile)
        XCTAssertNil(packetFile)
    }

    func testFinishCaptureSessionClosesOutputHandlesAndPreservesArtifactUrls() async throws {
        var packetTimestamp: Int64 = 100
        var rawTimestamp: Int64 = 200
        var logTimestamp: Int64 = 300
        let harness = try makeHarness(
            packetTimestampProvider: { packetTimestamp },
            rawTimestampProvider: { rawTimestamp },
            logTimestampProvider: { logTimestamp }
        )
        let first = makeTestPacket(
            counter: 10,
            timerMillis: 50,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 1, channelSamples: [[]])]
        )

        await harness.processor.submit(first)
        await harness.processor.flush()

        let packetFileURL = await harness.processor.currentPacketFile()
        let rawFileURL = await harness.processor.currentRawFile()
        let logFileURL = await harness.processor.currentLogFile()
        let hasOpenOutputFiles = await harness.processor.hasOpenOutputFiles()
        let packetFile = try XCTUnwrap(packetFileURL)
        let rawFile = try XCTUnwrap(rawFileURL)
        let logFile = try XCTUnwrap(logFileURL)
        XCTAssertTrue(hasOpenOutputFiles)

        await harness.processor.finishCaptureSession()

        let finishedHasOpenOutputFiles = await harness.processor.hasOpenOutputFiles()
        let finishedPacketFile = await harness.processor.currentPacketFile()
        let finishedRawFile = await harness.processor.currentRawFile()
        let finishedLogFile = await harness.processor.currentLogFile()
        let rejectedSubmitResult = await harness.processor.submit(first)
        XCTAssertFalse(finishedHasOpenOutputFiles)
        XCTAssertEqual(finishedPacketFile, packetFile)
        XCTAssertEqual(finishedRawFile, rawFile)
        XCTAssertEqual(finishedLogFile, logFile)
        XCTAssertEqual(try Data(contentsOf: packetFile), Data(first))
        XCTAssertEqual(rejectedSubmitResult, .rejected)

        packetTimestamp = 101
        rawTimestamp = 201
        logTimestamp = 301
        await harness.processor.resetSession()
        await harness.processor.submit(first)
        await harness.processor.flush()

        let resetPacketFile = await harness.processor.currentPacketFile()
        let resetRawFile = await harness.processor.currentRawFile()
        let resetLogFile = await harness.processor.currentLogFile()
        let resetHasOpenOutputFiles = await harness.processor.hasOpenOutputFiles()
        XCTAssertNotEqual(resetPacketFile, packetFile)
        XCTAssertNotEqual(resetRawFile, rawFile)
        XCTAssertNotEqual(resetLogFile, logFile)
        XCTAssertTrue(resetHasOpenOutputFiles)
    }

    func testFinishCaptureSessionDrainsAcceptedPendingFragmentsBeforeClosing() async throws {
        let harness = try makeHarness()
        let packet = makeTestPacket(
            counter: 10,
            timerMillis: 50,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 1, channelSamples: [[]])]
        )

        let submitResult = await harness.processor.submit(packet)
        await harness.processor.finishCaptureSession()

        let packetFileURL = await harness.processor.currentPacketFile()
        let packetFile = try XCTUnwrap(packetFileURL)
        let hasOpenOutputFiles = await harness.processor.hasOpenOutputFiles()
        XCTAssertEqual(submitResult, .accepted)
        XCTAssertEqual(try Data(contentsOf: packetFile), Data(packet))
        XCTAssertEqual(harness.updates.last?.packetsReceived, 1)
        XCTAssertFalse(hasOpenOutputFiles)
    }

    func testSubmitReturnsOverflowWhenPendingQueueIsFull() async throws {
        let harness = try makeHarness(maxPendingFragments: 0)
        let packet = makeTestPacket(
            counter: 10,
            timerMillis: 50,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 1, channelSamples: [[]])]
        )

        let result = await harness.processor.submit(packet)
        await harness.processor.flush()

        XCTAssertEqual(result, .overflow)
        let packetFile = await harness.processor.currentPacketFile()
        XCTAssertNil(packetFile)

        let rawFileURL = await harness.processor.currentRawFile()
        let rawFile = try XCTUnwrap(rawFileURL)
        let rawBytes = try [UInt8](Data(contentsOf: rawFile))
        XCTAssertEqual(Array(rawBytes.suffix(packet.count)), packet)
        XCTAssertTrue(harness.updates.contains { update in
            update.diagnosticEvents.contains { $0.message.contains("Capture queue overflow") }
        })
    }

    func testBatchedUpdatesArePublishedOnMainActor() async {
        final class MainActorProbe {
            var updates: [PacketProcessingUpdate] = []

            @MainActor
            func append(_ update: PacketProcessingUpdate) {
                dispatchPrecondition(condition: .onQueue(.main))
                updates.append(update)
            }
        }

        let probe = MainActorProbe()
        let batcher = await PacketProcessingUpdateBatcher(dispatchIntervalMillis: 0) { update in
            probe.append(update)
        }

        let update = PacketProcessingUpdate(
            packetsReceived: 1,
            packetsLost: 0,
            packetsRejected: 0,
            timerRegressionRejects: 0
        )
        await batcher.submit(update)

        let count = await MainActor.run { probe.updates.count }
        XCTAssertEqual(count, 1)
    }

    @MainActor
    func testFlushNowInvalidatesCanceledScheduledFlush() async {
        var updates: [PacketProcessingUpdate] = []
        let batcher = PacketProcessingUpdateBatcher(dispatchIntervalMillis: 100) { update in
            updates.append(update)
        }

        batcher.submit(
            PacketProcessingUpdate(
                packetsReceived: 1,
                packetsLost: 0,
                packetsRejected: 0,
                timerRegressionRejects: 0
            )
        )
        batcher.flushNow()
        batcher.submit(
            PacketProcessingUpdate(
                packetsReceived: 2,
                packetsLost: 0,
                packetsRejected: 0,
                timerRegressionRejects: 0
            )
        )
        try? await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(updates.map(\.packetsReceived), [1])

        batcher.flushNow()
        XCTAssertEqual(updates.map(\.packetsReceived), [1, 2])
    }

    func testStorageWritesAreSerializedByCaptureActor() async throws {
        let harness = try makeHarness()
        let packets = (1...20).map { counter in
            makeTestPacket(
                counter: UInt32(counter),
                timerMillis: 100,
                measurementCount: 1,
                blocks: [makeSensorBlock(sensorType: 1, channelSamples: [[]])]
            )
        }

        await withTaskGroup(of: Void.self) { group in
            for packet in packets {
                group.addTask {
                    await harness.processor.submit(packet)
                }
            }
        }
        await harness.processor.flush()

        let packetFileURL = await harness.processor.currentPacketFile()
        let packetFile = try XCTUnwrap(packetFileURL)
        let writtenBytes = try [UInt8](Data(contentsOf: packetFile))
        XCTAssertEqual(writtenBytes.count, packets.reduce(0) { $0 + $1.count })
        XCTAssertEqual(harness.updates.last?.fragmentsReceived, UInt64(packets.count))
    }

    private func makeHarness(
        packetTimestampProvider: @escaping () -> Int64 = { 1 },
        rawTimestampProvider: @escaping () -> Int64 = { 2 },
        logTimestampProvider: @escaping () -> Int64 = { 3 },
        fragmentTimestampProvider: @escaping () -> Int64 = { 4 },
        wallClockMillisProvider: @escaping () -> Int64 = { 1_000 },
        maxPendingFragments: Int = 512
    ) throws -> CaptureHarness {
        let directory = try temporaryDirectory()
        let box = UpdateBox()
        let processor = PacketCaptureProcessor(
            packetFileStore: PacketFileStore(directory: directory, timestampProvider: packetTimestampProvider),
            rawFragmentFileStore: RawFragmentFileStore(directory: directory, timestampProvider: rawTimestampProvider),
            diagnosticLogFileStore: DiagnosticLogFileStore(directory: directory, timestampProvider: logTimestampProvider),
            wallClockMillisProvider: wallClockMillisProvider,
            fragmentTimestampProvider: fragmentTimestampProvider,
            maxPendingFragments: maxPendingFragments,
            onUpdate: { update in
                box.updates.append(update)
            },
            onError: { message, error in
                XCTFail("\(message): \(String(describing: error))")
            }
        )
        return CaptureHarness(directory: directory, processor: processor, updateBox: box)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("woona-capture-tests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct CaptureHarness {
    let directory: URL
    let processor: PacketCaptureProcessor
    private let updateBox: PacketCaptureProcessorTests.UpdateBox

    init(
        directory: URL,
        processor: PacketCaptureProcessor,
        updateBox: PacketCaptureProcessorTests.UpdateBox
    ) {
        self.directory = directory
        self.processor = processor
        self.updateBox = updateBox
    }

    var updates: [PacketProcessingUpdate] {
        updateBox.updates
    }
}

extension PacketCaptureProcessorTests {
    final class UpdateBox: @unchecked Sendable {
        var updates: [PacketProcessingUpdate] = []
    }
}

private actor BlockingUpdateBox {
    private var recordedValues: [PacketProcessingUpdate] = []
    private var didBlockFirstUpdate = false
    private var firstUpdateRelease: CheckedContinuation<Void, Never>?

    var values: [PacketProcessingUpdate] {
        recordedValues
    }

    func append(_ value: PacketProcessingUpdate) async {
        recordedValues.append(value)
        guard !didBlockFirstUpdate else { return }

        didBlockFirstUpdate = true
        await withCheckedContinuation { continuation in
            firstUpdateRelease = continuation
        }
    }

    func waitUntilFirstUpdateIsBlocked(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanoseconds
        while !didBlockFirstUpdate, DispatchTime.now().uptimeNanoseconds < deadline {
            await Task.yield()
        }
        XCTAssertTrue(didBlockFirstUpdate, file: file, line: line)
    }

    func releaseFirstUpdate() {
        firstUpdateRelease?.resume()
        firstUpdateRelease = nil
    }
}

private extension Array {
    func single(file: StaticString = #filePath, line: UInt = #line) -> Element {
        XCTAssertEqual(count, 1, file: file, line: line)
        return self[0]
    }
}

private actor StorageErrorBox {
    var messages: [String] = []
    func append(_ message: String) { messages.append(message) }
}
