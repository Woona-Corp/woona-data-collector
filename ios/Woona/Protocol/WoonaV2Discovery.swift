import Foundation

/// Opt-in discovery. Receiving HELLO changes firmware protocol mode; no implicit
/// Legacy fallback, STOP_SESSION or storage ACK is sent from this controller.
final class WoonaV2Discovery {
    enum Phase: Equatable { case idle, waitHello, waitStreams, waitStatus, ready, failed }
    struct Status: Equatable {
        let sessionMode: Int
        let sessionID: UInt32
        let activeStreamMask: UInt32
        let supportedStreamMask: UInt32
        let batteryPercent: Int?
        let measurementPhase: Int?
    }
    struct Device: Equatable {
        let hello: V2Hello
        let streams: V2Streams
        let status: Status
    }
    enum Event: Equatable {
        case transmit(Data)
        case complete(Device)
        case failure(String)
    }
    private(set) var phase = Phase.idle
    private(set) var pendingRequestID: UInt32 = 0
    private(set) var lastStatus: Status?
    private var hello: V2Hello?
    private var streams: V2Streams?
    private var pendingType: UInt8 = 0
    private var pendingWire = Data()
    private var retries = 0
    private var nextSequence: UInt64 = 1
    private var nextRequestID: UInt64 = 1

    func begin() throws -> Event {
        guard phase == .idle else { throw V2ProtocolError.invalidState("V2 discovery may only start once per connection") }
        let event = try command(WoonaV2Codec.helloCommand)
        phase = .waitHello
        return event
    }

    /// An external, connection-wide decoder routes frames individually so a
    /// response and the first DATA can share one notification without a reset.
    func receive(_ frame: V2Frame) -> [Event] {
        guard [Phase.waitHello, .waitStreams, .waitStatus].contains(phase),
              pendingRequestID != 0, frame.requestID == pendingRequestID else { return [] }
        if let error = WoonaV2Codec.error(frame), error.offendingType == pendingType {
            return [fail("V2 command 0x\(String(pendingType, radix: 16)) rejected: status=\(error.status) (\(WoonaV2Codec.statusDescription(error.status)))")]
        }
        switch phase {
        case .waitHello:
            guard frame.type == WoonaV2Codec.helloResponse else { return [] }
            guard let info = WoonaV2Codec.hello(frame), info.versionMin <= 2, info.versionMax >= 2,
                  info.versionMin <= info.versionMax, (36...WoonaV2Codec.maxPayload).contains(info.maxPayload),
                  info.streamMask != 0 else { return [fail("Unsupported V2 version, stream mask or payload limit")] }
            guard [0, 2, 3, 4, 5].allSatisfy(info.hasCapability) else {
                return [fail("V2 LIVE preview requires LIVE, stream info, status, session control and command replay capabilities")]
            }
            hello = info
            do { let event = try command(WoonaV2Codec.getStreams); phase = .waitStreams; return [event] }
            catch { return [fail(error.localizedDescription)] }
        case .waitStreams:
            guard frame.type == WoonaV2Codec.streamsResponse else { return [] }
            guard let info = WoonaV2Codec.streams(frame) else { return [fail("Malformed V2 STREAMS_RESPONSE descriptors or mask")] }
            guard info.status == 0 else {
                return [fail("GET_STREAMS rejected: status=\(info.status) (\(WoonaV2Codec.statusDescription(info.status)))")]
            }
            guard let announced = hello, info.streamMask == announced.streamMask else { return [fail("GET_STREAMS mask disagrees with HELLO")] }
            streams = info
            do { let event = try command(WoonaV2Codec.getStatus); phase = .waitStatus; return [event] }
            catch { return [fail(error.localizedDescription)] }
        case .waitStatus:
            guard frame.type == WoonaV2Codec.statusResponse else { return [] }
            guard let status = decodeStatus(frame) else { return [fail("Malformed V2 STATUS_RESPONSE")] }
            lastStatus = status // Preserve busy/error state for the disconnect warning UI.
            let code = Int(frame.payload.first ?? 255)
            guard code == 0 else { return [fail("GET_STATUS rejected: status=\(code) (\(WoonaV2Codec.statusDescription(code)))")] }
            guard let hello = hello, let streams = streams,
                  status.supportedStreamMask == streams.streamMask,
                  (status.activeStreamMask & streams.streamMask) == status.activeStreamMask else {
                return [fail("V2 status stream masks disagree with discovery")]
            }
            guard status.sessionMode == 0, status.sessionID == 0 else {
                let mode = status.sessionMode == 2 ? "STORAGE" : "LIVE"
                return [fail("V2 device is busy with \(mode) session \(status.sessionID); preserve the active session")]
            }
            guard status.measurementPhase == nil || status.measurementPhase == 0 else {
                return [fail("V2 measurement is not idle; preserve the current connection and device state")]
            }
            phase = .ready; clearPending()
            return [.complete(Device(hello: hello, streams: streams, status: status))]
        default: return []
        }
    }

    /// Called only after the last ATT write callback for this request/generation.
    func onResponseTimeout() -> Event? {
        guard [Phase.waitHello, .waitStreams, .waitStatus].contains(phase), pendingRequestID != 0 else { return nil }
        retries += 1
        return retries <= 2 ? .transmit(pendingWire) : fail("V2 discovery response timed out")
    }

    func resetForNewConnection() {
        phase = .idle; hello = nil; streams = nil; lastStatus = nil
        clearPending(); nextSequence = 1; nextRequestID = 1
    }

    private func command(_ type: UInt8) throws -> Event {
        guard nextSequence <= UInt64(UInt32.max), nextRequestID <= UInt64(UInt32.max) else { throw V2ProtocolError.requestIDsExhausted }
        let identity = UInt32(nextRequestID)
        let wire = try WoonaV2Codec.encodeWire(type: type, sequence: UInt32(nextSequence), requestID: identity)
        nextSequence += 1; nextRequestID += 1
        pendingRequestID = identity; pendingType = type; pendingWire = wire; retries = 0
        return .transmit(wire)
    }

    private func decodeStatus(_ frame: V2Frame) -> Status? {
        guard [36, 48].contains(frame.payload.count) else { return nil }
        let bytes = [UInt8](frame.payload)
        guard bytes[1] == 1, bytes[2] <= 2, bytes[3] == 1,
              bytes[33...35].allSatisfy({ $0 == 0 }), bytes.count != 48 || bytes[36] <= 4 else { return nil }
        let battery = Int(bytes[32])
        return Status(sessionMode: Int(bytes[2]), sessionID: WoonaV2Codec.u32(bytes, 4),
            activeStreamMask: WoonaV2Codec.u32(bytes, 8), supportedStreamMask: WoonaV2Codec.u32(bytes, 12),
            batteryPercent: battery <= 100 ? battery : nil, measurementPhase: bytes.count == 48 ? Int(bytes[36]) : nil)
    }
    private func fail(_ reason: String) -> Event { phase = .failed; clearPending(); return .failure(reason) }
    private func clearPending() { pendingRequestID = 0; pendingType = 0; pendingWire = Data(); retries = 0 }
}
