import Foundation
import XCTest
@testable import Woona

final class WoonaV2Tests: XCTestCase {
    private struct Document: Decodable {
        let frames: [Fixture]
        let invalidFrames: [InvalidFixture]
        let fragmentSizes: [Int]
    }
    private struct Fixture: Decodable {
        let name: String
        let type: UInt8
        let sequence: UInt32
        let requestId: UInt32
        let flags: UInt8
        let payloadHex: String
        let rawHex: String
        let wireHex: String
        let expectedData: ExpectedData?
    }
    private struct InvalidFixture: Decodable { let name: String; let rawHex: String; let wireHex: String }
    private struct ExpectedData: Decodable {
        let sessionId: UInt32
        let streamId: Int
        let format: Int
        let channels: Int
        let count: Int
        let rateHz: Int
        let streamSequence: UInt32
        let timestampUs: String
        let samples: [Int]
    }

    private func document() throws -> Document {
        let url = try XCTUnwrap(Bundle(for: WoonaV2Tests.self).url(forResource: "woona-v2-wire-vectors", withExtension: "json"))
        return try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
    }
    private func fixture(_ name: String) throws -> Fixture { try XCTUnwrap(document().frames.first { $0.name == name }) }
    private func hex(_ value: String) throws -> Data {
        let chars = Array(value)
        guard chars.count % 2 == 0 else { throw V2ProtocolError.invalidArgument("Odd fixture hex length") }
        return Data(try stride(from: 0, to: chars.count, by: 2).map {
            try XCTUnwrap(UInt8(String(chars[$0...($0 + 1)]), radix: 16))
        })
    }
    private func frame(_ name: String) throws -> V2Frame { try XCTUnwrap(WoonaV2Codec.decodeRaw(hex(fixture(name).rawHex))) }
    private func replace(_ frame: V2Frame, sequence: UInt32? = nil, requestID: UInt32? = nil, payload: Data? = nil) -> V2Frame {
        V2Frame(type: frame.type, flags: frame.flags, sequence: sequence ?? frame.sequence,
                requestID: requestID ?? frame.requestID, payload: payload ?? frame.payload)
    }
    private func wire(_ event: WoonaV2LiveSession.Event) throws -> Data {
        guard case .transmit(let bytes) = event else { throw V2ProtocolError.invalidArgument("Expected LIVE transmit") }
        return bytes
    }
    private func discoveryWire(_ event: WoonaV2Discovery.Event?) throws -> Data {
        guard case .transmit(let bytes)? = event else { throw V2ProtocolError.invalidArgument("Expected discovery transmit") }
        return bytes
    }
    private func streams() throws -> V2Streams { try XCTUnwrap(WoonaV2Codec.streams(frame("streams_response"))) }
    private func ready() throws -> WoonaV2Discovery {
        let controller = WoonaV2Discovery()
        _ = try controller.begin()
        _ = controller.receive(try frame("hello_response"))
        _ = controller.receive(try frame("streams_response"))
        let complete = controller.receive(try frame("status_response"))
        guard case .complete? = complete.first else { throw V2ProtocolError.invalidArgument("Expected discovery readiness") }
        return controller
    }
    private func live() throws -> WoonaV2LiveSession {
        let controller = WoonaV2LiveSession(streams: try streams())
        _ = try controller.start(streamMask: 3)
        XCTAssertEqual(controller.receive(try frame("start_response")), [.started(sessionID: 77, streamMask: 3)])
        return controller
    }
    private func block(_ sequence: UInt32, wireSequence: UInt32, session: UInt32 = 77,
                       flags: UInt16 = 1, rate: UInt16 = 1000, count: UInt16 = 2,
                       timestamp: UInt64 = 9_007_199_254_740_993, samples: Data? = nil) -> V2Frame {
        var bytes: [UInt8] = []
        WoonaV2Codec.put32(session, into: &bytes); bytes += [1, 0]
        WoonaV2Codec.put16(flags, into: &bytes); WoonaV2Codec.put16(count, into: &bytes)
        WoonaV2Codec.put16(rate, into: &bytes); WoonaV2Codec.put32(sequence, into: &bytes)
        WoonaV2Codec.put64(timestamp, into: &bytes)
        bytes.append(contentsOf: samples ?? Data(repeating: 0, count: Int(count) * 6))
        return V2Frame(type: WoonaV2Codec.data, flags: 0, sequence: wireSequence, requestID: 0, payload: Data(bytes))
    }
    private func gap(_ events: [WoonaV2LiveSession.Event]) throws -> Bool {
        guard case .samples(_, _, _, let gap)? = events.first, events.count == 1 else {
            throw V2ProtocolError.invalidArgument("Expected one sample event")
        }
        return gap
    }

    func testCWireVectorsMatchBytesCRCAndEveryBLEFragmentation() throws {
        let vectors = try document()
        XCTAssertEqual(vectors.frames.count, 17)
        for fixture in vectors.frames {
            let raw = try hex(fixture.rawHex), wire = try hex(fixture.wireHex)
            let parsed = try XCTUnwrap(WoonaV2Codec.decodeRaw(raw), fixture.name)
            XCTAssertEqual(parsed.type, fixture.type, fixture.name)
            XCTAssertEqual(parsed.sequence, fixture.sequence, fixture.name)
            XCTAssertEqual(parsed.requestID, fixture.requestId, fixture.name)
            XCTAssertEqual(parsed.flags, fixture.flags, fixture.name)
            XCTAssertEqual(parsed.payload, try hex(fixture.payloadHex), fixture.name)
            XCTAssertEqual(try WoonaV2Codec.encodeRaw(type: parsed.type, sequence: parsed.sequence,
                requestID: parsed.requestID, payload: parsed.payload, flags: parsed.flags), raw, fixture.name)
            XCTAssertEqual(try WoonaV2Codec.encodeWire(type: parsed.type, sequence: parsed.sequence,
                requestID: parsed.requestID, payload: parsed.payload, flags: parsed.flags), wire, fixture.name)
            for size in vectors.fragmentSizes {
                let receiver = WoonaV2StreamDecoder()
                var result: [V2Frame] = []
                for offset in stride(from: 0, to: wire.count, by: size) {
                    result += receiver.append(wire.subdata(in: offset..<min(wire.count, offset + size)))
                }
                XCTAssertEqual(result, [parsed], "\(fixture.name) / fragment \(size)")
                XCTAssertEqual(receiver.rejectedFrames, 0)
            }
            if let expected = fixture.expectedData {
                let data = try XCTUnwrap(WoonaV2Codec.liveData(parsed))
                XCTAssertEqual(data.sessionID, expected.sessionId)
                XCTAssertEqual(data.streamID, expected.streamId)
                XCTAssertEqual(data.count, expected.count)
                XCTAssertEqual(data.rateHz, expected.rateHz)
                XCTAssertEqual(data.streamSequence, expected.streamSequence)
                XCTAssertEqual(data.timestampUs, try XCTUnwrap(UInt64(expected.timestampUs)))
                let bytes = [UInt8](data.samples)
                let values = stride(from: 0, to: bytes.count, by: 2).map { offset -> Int in
                    let value = WoonaV2Codec.u16(bytes, offset)
                    return expected.format == 1 ? Int(Int16(bitPattern: value)) : Int(value)
                }
                XCTAssertEqual(values, expected.samples)
                XCTAssertEqual(values.count, expected.count * expected.channels)
            }
        }
        XCTAssertEqual(vectors.invalidFrames.count, 6)
        for fixture in vectors.invalidFrames {
            XCTAssertNil(WoonaV2Codec.decodeRaw(try hex(fixture.rawHex)), fixture.name)
            let receiver = WoonaV2StreamDecoder()
            XCTAssertTrue(receiver.append(try hex(fixture.wireHex)).isEmpty, fixture.name)
            XCTAssertEqual(receiver.rejectedFrames, 1, fixture.name)
        }
    }

    func testNonzeroDataSlicesDoNotIndexAtAbsoluteZero() throws {
        let raw = try hex(fixture("accel_data").rawHex)
        var wrapped = Data([255]); wrapped.append(raw)
        XCTAssertEqual(WoonaV2Codec.decodeRaw(wrapped.dropFirst()), WoonaV2Codec.decodeRaw(raw))
        let encoded = try WoonaV2Codec.cobsEncode(raw)
        var cobsWrapped = Data([255]); cobsWrapped.append(encoded)
        XCTAssertEqual(WoonaV2Codec.cobsDecode(cobsWrapped.dropFirst()), raw)
        var payloadWrapped = Data([255]); payloadWrapped.append(try frame("accel_data").payload)
        XCTAssertEqual(WoonaV2Codec.liveData(replace(try frame("accel_data"), payload: payloadWrapped.dropFirst()))?.timestampUs,
                       9_007_199_254_740_993)
    }

    func testBoundedCOBSFuzzAndOversizedSegmentsResynchronize() throws {
        var random: UInt64 = 27_102_026
        func next() -> UInt64 { random = random &* 6_364_136_223_846_793_005 &+ 1; return random }
        for _ in 0..<1000 {
            let length = Int(next() % UInt64(WoonaV2Codec.maxRaw + 1))
            let raw = Data((0..<length).map { _ in UInt8(truncatingIfNeeded: next() >> 32) })
            let encoded = try WoonaV2Codec.cobsEncode(raw)
            XCTAssertLessThanOrEqual(encoded.count, WoonaV2Codec.maxEncoded)
            XCTAssertEqual(WoonaV2Codec.cobsDecode(encoded), raw)
            _ = WoonaV2Codec.decodeRaw(raw)
            _ = WoonaV2Codec.cobsDecode(raw)
        }
        XCTAssertThrowsError(try WoonaV2Codec.cobsEncode(Data(repeating: 1, count: WoonaV2Codec.maxRaw + 1)))
        XCTAssertThrowsError(try WoonaV2Codec.encodeRaw(type: 1, sequence: 1, requestID: 1,
            payload: Data(repeating: 0, count: WoonaV2Codec.maxPayload + 1)))
        XCTAssertNil(WoonaV2Codec.cobsDecode(Data(repeating: 1, count: WoonaV2Codec.maxEncoded + 1)))
        let receiver = WoonaV2StreamDecoder()
        XCTAssertTrue(receiver.append(Data(repeating: 1, count: 1_000_000)).isEmpty)
        var recovery = Data([0]); recovery.append(try hex(fixture("hello_response").wireHex))
        XCTAssertEqual(receiver.append(recovery).count, 1)
        XCTAssertEqual(receiver.rejectedFrames, 1)
        receiver.reset(); XCTAssertEqual(receiver.rejectedFrames, 0)
    }

    func testDescriptorsRejectDuplicatesMaskAliasesZeroRateAndInvalidKnownLayouts() throws {
        XCTAssertTrue(WoonaV2Codec.validStreams(try streams()))
        for descriptor in [V2Stream(id: 0, format: 1, channels: 3, nativeRateHz: 1000),
            V2Stream(id: 33, format: 1, channels: 3, nativeRateHz: 1000),
            V2Stream(id: 1, format: 2, channels: 3, nativeRateHz: 1000),
            V2Stream(id: 1, format: 1, channels: 1, nativeRateHz: 1000),
            V2Stream(id: 1, format: 1, channels: 3, nativeRateHz: 0)] {
            XCTAssertFalse(WoonaV2Codec.validStreams(V2Streams(status: 0, streamMask: 1, descriptors: [descriptor])))
        }
        let descriptor = V2Stream(id: 1, format: 1, channels: 3, nativeRateHz: 1000)
        XCTAssertFalse(WoonaV2Codec.validStreams(V2Streams(status: 0, streamMask: 1, descriptors: [descriptor, descriptor])))
        XCTAssertFalse(WoonaV2Codec.validStreams(V2Streams(status: 0, streamMask: 3, descriptors: [descriptor])))
        XCTAssertTrue(WoonaV2Codec.validStreams(V2Streams(status: 0, streamMask: 0x80000000,
            descriptors: [V2Stream(id: 32, format: 1, channels: 16, nativeRateHz: 8000)])))
        let invalid = WoonaV2LiveSession(streams: V2Streams(status: 0, streamMask: 0, descriptors: []))
        XCTAssertThrowsError(try invalid.start(streamMask: 1))
    }

    func testDiscoveryCorrelatesCommandsAndRetriesIdenticalWireBytes() throws {
        let controller = WoonaV2Discovery()
        let original = try discoveryWire(controller.begin())
        XCTAssertEqual(original, try hex(fixture("hello_request").wireHex))
        XCTAssertEqual(try discoveryWire(controller.onResponseTimeout()), original)
        XCTAssertEqual(try discoveryWire(controller.onResponseTimeout()), original)
        XCTAssertTrue(controller.receive(replace(try frame("hello_response"), requestID: 99)).isEmpty)
        guard case .failure? = controller.onResponseTimeout() else { return XCTFail("Expected bounded timeout failure") }
        XCTAssertNil(controller.onResponseTimeout())
        controller.resetForNewConnection()
        _ = try controller.begin()
        XCTAssertEqual(try discoveryWire(controller.receive(frame("hello_response")).first), try hex(fixture("streams_request").wireHex))
        XCTAssertEqual(try discoveryWire(controller.receive(frame("streams_response")).first), try hex(fixture("status_request").wireHex))
        _ = controller.receive(try frame("status_response"))
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(controller.pendingRequestID, 0)
        XCTAssertNil(controller.onResponseTimeout())
        XCTAssertEqual(try ready().phase, .ready)
    }

    func testGenericErrorFailsEachDiscoveryStageImmediately() throws {
        for stage in 1...3 {
            let controller = WoonaV2Discovery(); _ = try controller.begin()
            if stage >= 2 { _ = controller.receive(try frame("hello_response")) }
            if stage >= 3 { _ = controller.receive(try frame("streams_response")) }
            let wrong = V2Frame(type: 255, flags: 0, sequence: 100, requestID: UInt32(stage), payload: Data([4, 9, 0, 0]))
            XCTAssertTrue(controller.receive(wrong).isEmpty)
            let response = replace(wrong, payload: Data([4, UInt8(stage), 0, 0]))
            guard case .failure(let reason)? = controller.receive(response).first else { return XCTFail("Expected matching ERROR failure") }
            XCTAssertTrue(reason.contains("device busy"))
            XCTAssertEqual(controller.phase, .failed)
        }
    }

    func testUnsupportedCapabilitiesAndInconsistentCatalogNeverBecomeReady() throws {
        for bit in [0, 2, 3, 4, 5] {
            let controller = WoonaV2Discovery(); _ = try controller.begin()
            let response = try frame("hello_response")
            var bytes = [UInt8](response.payload)
            let mask = WoonaV2Codec.u32(bytes, 4) & ~(UInt32(1) << bit)
            for index in 0..<4 { bytes[4 + index] = UInt8(truncatingIfNeeded: mask >> (index * 8)) }
            _ = controller.receive(replace(response, payload: Data(bytes)))
            XCTAssertEqual(controller.phase, .failed)
        }
        let controller = WoonaV2Discovery(); _ = try controller.begin()
        _ = controller.receive(try frame("hello_response"))
        var bytes = [UInt8](try frame("streams_response").payload); bytes[4] ^= 1
        _ = controller.receive(replace(try frame("streams_response"), payload: Data(bytes)))
        XCTAssertEqual(controller.phase, .failed)
    }

    func testBusyStatusPreservesDeviceStateWithoutAutomaticStopOrStorageAck() throws {
        for (name, mode) in [("status_response", 1), ("status_response", 2), ("status_response_extended", 2)] {
            let controller = WoonaV2Discovery(); _ = try controller.begin()
            _ = controller.receive(try frame("hello_response")); _ = controller.receive(try frame("streams_response"))
            let response = try frame(name)
            var bytes = [UInt8](response.payload); bytes[2] = UInt8(mode); bytes[4] = 77; bytes[8] = 1
            if bytes.count == 48 { bytes[36] = 2 }
            let events = controller.receive(replace(response, payload: Data(bytes)))
            guard case .failure(let reason)? = events.first else { return XCTFail("Expected busy failure") }
            XCTAssertEqual(events.count, 1); XCTAssertTrue(reason.contains("busy"))
            XCTAssertEqual(controller.lastStatus?.sessionMode, mode)
            XCTAssertEqual(controller.lastStatus?.sessionID, 77)
            XCTAssertEqual(controller.phase, .failed)
        }
    }

    func testCoalescedStartAckFirstDataAndPartialNextNotificationKeepSamples() throws {
        for partial in [false, true] {
            let controller = WoonaV2LiveSession(streams: try streams())
            XCTAssertEqual(try wire(controller.start(streamMask: 3)), try hex(fixture("start_request").wireHex))
            let receiver = WoonaV2StreamDecoder()
            let data = try hex(fixture("accel_data").wireHex)
            let split = partial ? data.count / 2 : data.count
            var batch = try hex(fixture("start_response").wireHex); batch.append(data.prefix(split))
            var events = receiver.append(batch).flatMap { controller.receive($0) }
            if partial { events += receiver.append(data.dropFirst(split)).flatMap { controller.receive($0) } }
            XCTAssertEqual(events.count, 2)
            XCTAssertEqual(events.first, .started(sessionID: 77, streamMask: 3))
            guard case .samples(_, let block, _, _)? = events.last else { return XCTFail("Missing first coalesced DATA") }
            XCTAssertEqual(block.timestampUs, 9_007_199_254_740_993)
            XCTAssertEqual(block.count, 2)
        }
    }

    func testDuplicateAndBackwardsDataDoNotPoisonStreamSequence() throws {
        let controller = try live()
        XCTAssertFalse(try gap(controller.receive(block(10, wireSequence: 105))))
        XCTAssertTrue(controller.receive(block(10, wireSequence: 106)).isEmpty)
        XCTAssertTrue(controller.receive(block(9, wireSequence: 107)).isEmpty)
        XCTAssertFalse(try gap(controller.receive(block(11, wireSequence: 108))))
        XCTAssertTrue(try gap(controller.receive(block(13, wireSequence: 109))))
        XCTAssertTrue(controller.receive(block(12, wireSequence: 110)).isEmpty)
        XCTAssertFalse(try gap(controller.receive(block(14, wireSequence: 111))))
    }

    func testBothUInt32WrapsAreForwardAndHalfRangeIsNot() throws {
        let controller = try live()
        XCTAssertFalse(try gap(controller.receive(block(UInt32.max, wireSequence: 105))))
        XCTAssertFalse(try gap(controller.receive(block(0, wireSequence: 106))))
        XCTAssertTrue(controller.receive(block(UInt32.max - 1, wireSequence: 107)).isEmpty)
        XCTAssertTrue(controller.receive(block(0x80000000, wireSequence: 108)).isEmpty)
        XCTAssertFalse(try gap(controller.receive(block(1, wireSequence: 109))))
        let outer = WoonaV2LiveSession(streams: try streams()); _ = try outer.start(streamMask: 3)
        _ = outer.receive(replace(try frame("start_response"), sequence: UInt32.max - 1))
        XCTAssertFalse(try gap(outer.receive(block(0, wireSequence: UInt32.max))))
        XCTAssertFalse(try gap(outer.receive(block(1, wireSequence: 0))))
        XCTAssertTrue(outer.receive(block(2, wireSequence: UInt32.max - 1)).isEmpty)
        XCTAssertFalse(try gap(outer.receive(block(2, wireSequence: 1))))
    }

    func testWireGapInvalidRateAndUntimedBlocksAreIndependent() throws {
        let controller = try live()
        XCTAssertFalse(try gap(controller.receive(block(0, wireSequence: 105, flags: 0, timestamp: UInt64.max))))
        XCTAssertTrue(controller.receive(block(1, wireSequence: 106, rate: 1001)).isEmpty)
        XCTAssertFalse(try gap(controller.receive(block(1, wireSequence: 107))))
        XCTAssertTrue(try gap(controller.receive(block(2, wireSequence: 109))))
        XCTAssertTrue(controller.receive(block(3, wireSequence: 109)).isEmpty)
        XCTAssertTrue(controller.receive(block(3, wireSequence: 110, session: 999)).isEmpty)
        XCTAssertTrue(controller.receive(block(3, wireSequence: 111, samples: Data([1, 2]))).isEmpty)
        XCTAssertTrue(controller.receive(block(3, wireSequence: 112, count: 0)).isEmpty)
        XCTAssertFalse(try gap(controller.receive(block(3, wireSequence: 113))))
    }

    func testLiveRetriesStaleAckLateDataAndResetNeverReuseCommandIDs() throws {
        let controller = WoonaV2LiveSession(streams: try streams())
        let original = try wire(controller.start(streamMask: 3))
        XCTAssertEqual(try wire(XCTUnwrap(controller.onResponseTimeout())), original)
        XCTAssertTrue(controller.receive(replace(try frame("start_response"), requestID: 99)).isEmpty)
        _ = controller.receive(try frame("start_response"))
        XCTAssertEqual(controller.pendingRequestID, 0); XCTAssertNil(controller.onResponseTimeout())
        let stale = V2Frame(type: 255, flags: 0, sequence: 105, requestID: 4, payload: Data([4, 4, 0, 0]))
        XCTAssertTrue(controller.receive(stale).isEmpty); XCTAssertEqual(controller.phase, .running)
        let stop = try wire(controller.stop())
        XCTAssertEqual(try wire(XCTUnwrap(controller.onResponseTimeout())), stop)
        _ = controller.receive(try frame("stop_response"))
        XCTAssertEqual(controller.phase, .stopped)
        XCTAssertEqual(controller.receive(block(0, wireSequence: 107)).count, 1)
        controller.reset()
        let next = try wire(controller.start(streamMask: 3))
        let command = try XCTUnwrap(WoonaV2Codec.decodeRaw(XCTUnwrap(WoonaV2Codec.cobsDecode(next.dropLast()))))
        XCTAssertEqual(command.requestID, 6)
        XCTAssertTrue(controller.receive(try frame("start_response")).isEmpty)
        XCTAssertEqual(controller.phase, .waitStart)
    }

    func testLiveErrorsAndTimeoutNeverPublishFalseStartOrStop() throws {
        for status in [4, 9, 10, 12] {
            let controller = WoonaV2LiveSession(streams: try streams()); _ = try controller.start(streamMask: 3)
            var bytes = [UInt8](try frame("start_response").payload); bytes[0] = UInt8(status)
            guard case .failure? = controller.receive(replace(try frame("start_response"), payload: Data(bytes))).first else {
                return XCTFail("Rejected START must not publish Started")
            }
            XCTAssertEqual(controller.phase, .failed); XCTAssertEqual(controller.sessionID, 0)
        }
        let rejectedStop = try live(); _ = try rejectedStop.stop()
        var stopBytes = [UInt8](try frame("stop_response").payload); stopBytes[0] = 4
        guard case .failure? = rejectedStop.receive(replace(try frame("stop_response"), payload: Data(stopBytes))).first else {
            return XCTFail("Rejected STOP must not publish Stopped")
        }
        XCTAssertEqual(rejectedStop.sessionID, 77)
        let timedOut = WoonaV2LiveSession(streams: try streams())
        let original = try wire(timedOut.start(streamMask: 3))
        for _ in 0..<2 { XCTAssertEqual(try wire(XCTUnwrap(timedOut.onResponseTimeout())), original) }
        guard case .failure? = timedOut.onResponseTimeout() else { return XCTFail("Expected bounded LIVE timeout") }
        XCTAssertNil(timedOut.onResponseTimeout())
        XCTAssertTrue(timedOut.receive(try frame("start_response")).isEmpty)
    }
}
