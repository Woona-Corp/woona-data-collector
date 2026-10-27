import XCTest
@testable import Woona

final class BleControlWriteQueueTests: XCTestCase {
    func testFragmentationWaitsForEveryAcknowledgmentAndCompletesOnlyAtFrameEnd() throws {
        let queue = BleControlWriteQueue(); let result = WriteProbe()
        // Nonzero Data.startIndex must not shift or duplicate ATT bytes.
        let wire = Data([99, 1, 2, 3, 4, 5, 88])[1..<6]
        try queue.enqueue(wire, maximumChunkBytes: 2) { result.append($0) }
        XCTAssertEqual(queue.nextFragment(), Data([1, 2])); XCTAssertNil(queue.nextFragment())
        XCTAssertEqual(result.count, 0)
        queue.acknowledge(); XCTAssertEqual(queue.nextFragment(), Data([3, 4]))
        XCTAssertEqual(result.count, 0)
        queue.acknowledge(); XCTAssertEqual(queue.nextFragment(), Data([5]))
        queue.acknowledge(); XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result.success); XCTAssertEqual(queue.pendingFrameCount, 0)
        queue.acknowledge(); XCTAssertEqual(result.count, 1, "Late duplicate callback cannot complete twice")
    }

    func testQueueBoundsFourFramesAndDisconnectFailsEveryPendingCommandOnce() throws {
        let queue = BleControlWriteQueue(); let result = WriteProbe()
        for _ in 0..<4 { try queue.enqueue(Data(repeating: 1, count: 2082), maximumChunkBytes: 185) { result.append($0) } }
        XCTAssertThrowsError(try queue.enqueue(Data([1]), maximumChunkBytes: 185) { _ in })
        XCTAssertThrowsError(try queue.enqueue(Data(repeating: 1, count: 2083), maximumChunkBytes: 185) { _ in })
        XCTAssertNotNil(queue.nextFragment()); queue.reset()
        XCTAssertEqual(result.count, 4); XCTAssertFalse(result.success)
        XCTAssertNil(queue.nextFragment()); queue.acknowledge(); XCTAssertEqual(result.count, 4)
        try queue.enqueue(Data([8]), maximumChunkBytes: Int.max) { result.append($0) }
        XCTAssertEqual(queue.nextFragment(), Data([8])); queue.acknowledge()
        XCTAssertEqual(result.count, 5, "A fresh queue can be used after explicit reset")
    }
}

private final class WriteProbe: @unchecked Sendable {
    private let lock = NSLock(); private var values: [Bool] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    var success: Bool { lock.lock(); defer { lock.unlock() }; return values.last ?? false }
    func append(_ result: Result<Void, Error>) {
        lock.lock(); defer { lock.unlock() }
        if case .success = result { values.append(true) } else { values.append(false) }
    }
}

@MainActor
final class V2PreviewTests: XCTestCase {
    private struct Fixtures: Decodable { let frames: [Frame] }
    private struct Frame: Decodable { let name: String; let wireHex: String }
    private func wire(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: WoonaV2Tests.self).url(forResource: "woona-v2-wire-vectors", withExtension: "json"))
        let document = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
        let hex = try XCTUnwrap(document.frames.first { $0.name == name }?.wireHex)
        return Data(stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        })
    }
    private func wait(_ predicate: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 2
        while !predicate(), ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(predicate(), file: file, line: line)
    }
    private func discover(_ worker: V2PreviewWorker, writes: PreviewWrites) async throws {
        worker.prepare(UUID()); worker.ready()
        try await wait { writes.count == 1 }
        worker.receive(try wire("hello_response")); try await wait { writes.count == 2 }
        worker.receive(try wire("streams_response")); try await wait { writes.count == 3 }
        worker.receive(try wire("status_response"))
    }

    func testBackgroundBeforeStatusDoesNotDisconnectAndLateOwnStartAckStopsOnlyOwnLive() async throws {
        let writes = PreviewWrites(); var snapshot = V2PreviewSnapshot()
        let worker = V2PreviewWorker(update: { _, value in snapshot = value }, write: { _, wire, completion in writes.frames.append(wire); completion(.success(())) })
        worker.prepare(UUID()); worker.ready(); try await wait { writes.count == 1 }
        worker.setForeground(false)
        // Discovery can settle while backgrounded; no START/STOP or SD command.
        worker.receive(try wire("hello_response")); try await wait { writes.count == 2 }
        worker.receive(try wire("streams_response")); try await wait { writes.count == 3 }
        worker.receive(try wire("status_response")); try await wait { snapshot.stage == .ready }
        worker.start(); try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertEqual(writes.count, 3, "Background never starts a preview")
        worker.setForeground(true); worker.start(); try await wait { writes.count == 4 }
        worker.setForeground(false)
        worker.receive(try wire("start_response")); try await wait { writes.count == 5 }
        let decoder = WoonaV2StreamDecoder()
        let stop = try XCTUnwrap(decoder.append(writes.frames[4]).first)
        XCTAssertEqual(stop.type, WoonaV2Codec.stopSession)
        XCTAssertEqual(stop.requestID, 5)
        worker.receive(try wire("stop_response")); try await wait { snapshot.stage == .stopped }
        XCTAssertEqual(writes.count, 5, "Only our correlated LIVE session is stopped; no SD ACK or disconnect")
        worker.disconnected()
    }

    func testLastAvailableStreamCannotBeDeselectedAndStartKeepsItsMask() async throws {
        let writes = PreviewWrites(); var snapshot = V2PreviewSnapshot()
        let worker = V2PreviewWorker(update: { _, value in snapshot = value }, write: { _, wire, completion in writes.frames.append(wire); completion(.success(())) })
        try await discover(worker, writes: writes); try await wait { snapshot.stage == .ready }
        worker.select(mask: 1); try await wait { snapshot.selectedMask == 1 }
        worker.select(mask: 0); worker.start(); try await wait { writes.count == 4 }
        let decoder = WoonaV2StreamDecoder()
        let start = try XCTUnwrap(decoder.append(writes.frames[3]).first)
        XCTAssertEqual(start.type, WoonaV2Codec.startSession)
        XCTAssertEqual(WoonaV2Codec.u32([UInt8](start.payload), 4), 1)
        worker.disconnected()
    }

    func testQueuedStartIsCancelledBeforeTransmissionWhenTheAppLeavesForeground() async throws {
        let writes = PreviewWrites(); var snapshot = V2PreviewSnapshot()
        let worker = V2PreviewWorker(update: { _, value in snapshot = value }, write: { _, wire, completion in writes.frames.append(wire); completion(.success(())) })
        try await discover(worker, writes: writes); try await wait { snapshot.stage == .ready }
        // No MainActor yield occurs between these actions: the START transmission
        // is still queued when the protocol worker receives the lifecycle change.
        worker.start(); worker.setForeground(false)
        try await wait { snapshot.stage == .stopped }
        XCTAssertEqual(writes.count, 3, "An unsent START must not run after cancellation")
        XCTAssertNotNil(snapshot.reason)
        worker.setForeground(true); worker.start(); try await wait { writes.count == 4 }
        let decoder = WoonaV2StreamDecoder()
        let nextStart = try XCTUnwrap(decoder.append(writes.frames[3]).first)
        XCTAssertEqual(nextStart.type, WoonaV2Codec.startSession)
        XCTAssertEqual(nextStart.requestID, 5, "Cancelled command IDs are never reused on the same connection")
        worker.disconnected()
    }

    func testBoundedChartAndQueueTrackDecodedVersusUIOmissionsWithoutRewritingClocks() async throws {
        let writes = PreviewWrites(); var snapshot = V2PreviewSnapshot()
        let worker = V2PreviewWorker(update: { _, value in snapshot = value }, write: { _, wire, completion in writes.frames.append(wire); completion(.success(())) })
        try await discover(worker, writes: writes); try await wait { snapshot.stage == .ready }
        worker.start(); try await wait { writes.count == 4 }
        worker.receive(try wire("start_response")); try await wait { snapshot.stage == .running }
        let decoder = WoonaV2StreamDecoder()
        let example = try XCTUnwrap(decoder.append(try wire("accel_data")).first)
        // A burst larger than the UI queue is counted in full before UI drops.
        for index in 0..<200 {
            var payload = [UInt8](example.payload)
            for byte in 0..<4 { payload[12 + byte] = UInt8(truncatingIfNeeded: UInt32(index) >> (8 * byte)) }
            // Preserve all integer microseconds until subtraction (fixture >2^53).
            let stamp = WoonaV2Codec.u64(payload, 16) + UInt64(index * 50_000)
            for byte in 0..<8 { payload[16 + byte] = UInt8(truncatingIfNeeded: stamp >> (8 * byte)) }
            let frame = try WoonaV2Codec.encodeWire(type: WoonaV2Codec.data, sequence: UInt32(105 + index), requestID: 0, payload: Data(payload))
            worker.receive(frame)
        }
        try await wait { snapshot.decodedBlocks == 200 }
        XCTAssertGreaterThan(snapshot.skippedUIBlocks, 0)
        XCTAssertLessThanOrEqual(snapshot.channels.count, 11)
        XCTAssertTrue(snapshot.channels.allSatisfy { $0.points.count <= 6000 })
        XCTAssertTrue(snapshot.channels.flatMap(\.points).allSatisfy { $0.time.isFinite && $0.value.isFinite })
        let omittedBefore = snapshot.skippedUIBlocks
        let plottedBefore = snapshot.channels.reduce(0) { $0 + $1.points.count }
        var backwards = [UInt8](example.payload)
        for byte in 0..<4 { backwards[12 + byte] = UInt8(truncatingIfNeeded: UInt32(200) >> (8 * byte)) }
        let backwardsStamp = WoonaV2Codec.u64(backwards, 16) + 198 * 50_000
        for byte in 0..<8 { backwards[16 + byte] = UInt8(truncatingIfNeeded: backwardsStamp >> (8 * byte)) }
        worker.receive(try WoonaV2Codec.encodeWire(type: WoonaV2Codec.data, sequence: 305, requestID: 0, payload: Data(backwards)))
        try await wait { snapshot.decodedBlocks == 201 }
        XCTAssertEqual(snapshot.skippedUIBlocks, omittedBefore + 1, "A backwards clock is counted as decoded and explicitly omitted from the chart")
        XCTAssertEqual(snapshot.channels.reduce(0) { $0 + $1.points.count }, plottedBefore)
        worker.disconnected()
    }

    func testCoarseningKeepsEndpointsAndPropagatesSegmentBreaks() {
        var input: [V2PreviewPoint] = []
        for index in 0..<7001 {
            let startsSegment = index == 101 || index == 4999
            input.append(V2PreviewPoint(time: Double(index), value: Double(index), breakBefore: startsSegment, timestampUs: UInt64(index) * 1000))
        }
        let output = V2PreviewWorker.coarsen(input)
        XCTAssertLessThanOrEqual(output.count, 3000)
        XCTAssertEqual(output.first?.time, 0); XCTAssertEqual(output.last?.time, 7000)
        XCTAssertEqual(output.filter { $0.breakBefore }.count, 2)
        XCTAssertTrue(output.contains { $0.time >= 101 && $0.time <= 103 && $0.breakBefore })
    }
}

@MainActor
private final class PreviewWrites {
    var frames: [Data] = []
    var count: Int { frames.count }
}
