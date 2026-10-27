import Foundation

/// Preview-only LIVE commands. No storage commands, ACKs or persistence formats
/// are generated. The caller serializes this controller on its protocol queue.
final class WoonaV2LiveSession {
    enum Phase: Equatable { case idle, waitStart, running, waitStop, stopped, failed }
    enum Event: Equatable {
        case transmit(Data)
        case started(sessionID: UInt32, streamMask: UInt32)
        case samples(frameSequence: UInt32, block: V2LiveData, descriptor: V2Stream, sequenceGap: Bool)
        case stopped(sessionID: UInt32)
        case failure(String)
    }
    private(set) var phase = Phase.idle
    private(set) var sessionID: UInt32 = 0
    private(set) var pendingRequestID: UInt32 = 0
    private let streams: V2Streams
    private var activeMask: UInt32 = 0
    private var pendingType: UInt8 = 0
    private var pendingWire = Data()
    private var retries = 0
    private var nextSequence: UInt64 = 4
    private var nextRequestID: UInt64 = 4
    private var lastStreamSequence: [Int: UInt32] = [:]
    private var lastFrameSequence: UInt32?
    private var pendingWireGap = false

    init(streams: V2Streams) { self.streams = streams }

    func start(streamMask: UInt32) throws -> Event {
        guard phase == .idle || phase == .stopped else { throw V2ProtocolError.invalidState("Cannot start V2 LIVE in \(phase)") }
        guard WoonaV2Codec.validStreams(streams), streamMask != 0,
              (streamMask & streams.streamMask) == streamMask else { throw V2ProtocolError.invalidArgument("Invalid V2 descriptors or unsupported stream mask") }
        var payload: [UInt8] = [1, 0, 0, 0]
        WoonaV2Codec.put32(streamMask, into: &payload); WoonaV2Codec.put32(0, into: &payload)
        let event = try command(WoonaV2Codec.startSession, payload: Data(payload))
        activeMask = streamMask; sessionID = 0; lastStreamSequence.removeAll(); phase = .waitStart
        return event
    }

    func stop() throws -> Event {
        guard phase == .running else { throw V2ProtocolError.invalidState("Cannot stop V2 LIVE in \(phase)") }
        var payload: [UInt8] = []
        WoonaV2Codec.put32(sessionID, into: &payload)
        let event = try command(WoonaV2Codec.stopSession, payload: Data(payload))
        phase = .waitStop
        return event
    }

    func receive(_ frame: V2Frame) -> [Event] {
        guard phase != .idle, phase != .failed else { return [] }
        let delta = lastFrameSequence.map { frame.sequence &- $0 }
        let fresh = delta.map { $0 > 0 && $0 < 0x80000000 } ?? true
        if fresh {
            lastFrameSequence = frame.sequence
            if let delta = delta, delta > 1 { pendingWireGap = true }
        }
        // STOP_ACK may overtake queued data. Keep the session ID until the next
        // START/disconnect and accept late blocks from precisely that session.
        if frame.type == WoonaV2Codec.data, frame.requestID == 0,
           [Phase.running, .waitStop, .stopped].contains(phase) {
            guard fresh, let sample = receiveData(frame) else { return [] }
            return [sample]
        }
        guard [Phase.waitStart, .waitStop].contains(phase), pendingRequestID != 0,
              frame.requestID == pendingRequestID else { return [] }
        if let error = WoonaV2Codec.error(frame), error.offendingType == pendingType {
            return [fail("V2 command 0x\(String(pendingType, radix: 16)) rejected: status=\(error.status) (\(WoonaV2Codec.statusDescription(error.status)))")]
        }
        switch phase {
        case .waitStart:
            guard frame.type == WoonaV2Codec.startSessionResponse else { return [] }
            return [receiveStart(frame)]
        case .waitStop:
            guard frame.type == WoonaV2Codec.stopSessionResponse else { return [] }
            return [receiveStop(frame)]
        default: return []
        }
    }

    func onResponseTimeout() -> Event? {
        guard [Phase.waitStart, .waitStop].contains(phase), pendingRequestID != 0 else { return nil }
        retries += 1
        return retries <= 2 ? .transmit(pendingWire) : fail("V2 LIVE command timed out; reconcile device state before retrying")
    }

    /// Runtime reset does not prove disconnect: keep monotonically allocated IDs
    /// so a firmware cache cannot replay an old START as a new user action.
    func reset() {
        phase = .idle; sessionID = 0; activeMask = 0; clearPending()
        lastStreamSequence.removeAll(); lastFrameSequence = nil; pendingWireGap = false
    }

    private func receiveStart(_ frame: V2Frame) -> Event {
        guard frame.payload.count == 24 else { return fail("Malformed V2 LIVE START_SESSION_RESPONSE") }
        let bytes = [UInt8](frame.payload)
        let status = Int(bytes[0])
        guard status == 0 else { return fail("START_SESSION rejected: status=\(status) (\(WoonaV2Codec.statusDescription(status)))") }
        let identity = WoonaV2Codec.u32(bytes, 4)
        let mask = WoonaV2Codec.u32(bytes, 8)
        guard bytes[1] == 1, WoonaV2Codec.u16(bytes, 2) == 0, identity != 0, mask == activeMask,
              WoonaV2Codec.u32(bytes, 12) == 0, WoonaV2Codec.u64(bytes, 16) == 0 else {
            return fail("Malformed V2 LIVE START_SESSION_RESPONSE")
        }
        sessionID = identity; phase = .running; clearPending()
        return .started(sessionID: identity, streamMask: mask)
    }

    private func receiveStop(_ frame: V2Frame) -> Event {
        guard frame.payload.count == 8 else { return fail("Malformed V2 LIVE STOP_SESSION_RESPONSE") }
        let bytes = [UInt8](frame.payload)
        let status = Int(bytes[0])
        guard status == 0 else { return fail("STOP_SESSION rejected: status=\(status) (\(WoonaV2Codec.statusDescription(status)))") }
        let identity = WoonaV2Codec.u32(bytes, 4)
        guard bytes[1] == 0, WoonaV2Codec.u16(bytes, 2) == 0, identity == sessionID else {
            return fail("Malformed V2 LIVE STOP_SESSION_RESPONSE")
        }
        phase = .stopped; clearPending()
        return .stopped(sessionID: identity)
    }

    private func receiveData(_ frame: V2Frame) -> Event? {
        guard let block = WoonaV2Codec.liveData(frame), block.sessionID == sessionID,
              (1...32).contains(block.streamID), (activeMask & (UInt32(1) << (block.streamID - 1))) != 0,
              block.count > 0, block.rateHz > 0,
              let descriptor = streams.descriptors.first(where: { $0.id == block.streamID }),
              (1...16).contains(descriptor.channels), (1...2).contains(descriptor.format),
              block.rateHz <= Int(descriptor.nativeRateHz),
              block.samples.count == block.count * descriptor.channels * 2 else { return nil }
        let delta = lastStreamSequence[block.streamID].map { block.streamSequence &- $0 }
        if let delta = delta, delta == 0 || delta >= 0x80000000 { return nil }
        lastStreamSequence[block.streamID] = block.streamSequence
        let gap = (delta.map { $0 > 1 } ?? false) || pendingWireGap
        pendingWireGap = false
        // timestampUs remains UInt64, including values above 2^53. A zero
        // timestamp-valid flag is a decoded block; only the chart mapper skips it.
        return .samples(frameSequence: frame.sequence, block: block, descriptor: descriptor, sequenceGap: gap)
    }

    private func command(_ type: UInt8, payload: Data) throws -> Event {
        guard nextSequence <= UInt64(UInt32.max), nextRequestID <= UInt64(UInt32.max) else { throw V2ProtocolError.requestIDsExhausted }
        let identity = UInt32(nextRequestID)
        let wire = try WoonaV2Codec.encodeWire(type: type, sequence: UInt32(nextSequence), requestID: identity, payload: payload)
        nextSequence += 1; nextRequestID += 1
        pendingType = type; pendingRequestID = identity; pendingWire = wire; retries = 0
        return .transmit(wire)
    }
    private func fail(_ reason: String) -> Event { phase = .failed; clearPending(); return .failure(reason) }
    private func clearPending() { pendingRequestID = 0; pendingType = 0; pendingWire = Data(); retries = 0 }
}
