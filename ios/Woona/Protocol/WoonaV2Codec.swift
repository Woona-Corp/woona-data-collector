import Foundation

struct V2Frame: Equatable {
    let type: UInt8
    let flags: UInt8
    let sequence: UInt32
    let requestID: UInt32
    let payload: Data
}

struct V2Hello: Equatable {
    let versionMin: Int
    let versionMax: Int
    let capabilities: UInt32
    let streamMask: UInt32
    let maxPayload: Int
    func hasCapability(_ bit: Int) -> Bool {
        (0..<32).contains(bit) && (capabilities & (UInt32(1) << bit)) != 0
    }
}

struct V2Stream: Equatable {
    let id: Int
    let format: Int
    let channels: Int
    let nativeRateHz: UInt32
}

struct V2Streams: Equatable {
    let status: Int
    let streamMask: UInt32
    let descriptors: [V2Stream]
}

struct V2LiveData: Equatable {
    let sessionID: UInt32
    let streamID: Int
    let flags: Int
    let count: Int
    let rateHz: Int
    let streamSequence: UInt32
    let timestampUs: UInt64
    let samples: Data
}

struct V2Error: Equatable {
    let status: Int
    let offendingType: UInt8
}

enum V2ProtocolError: Error, LocalizedError {
    case invalidState(String)
    case invalidArgument(String)
    case requestIDsExhausted
    var errorDescription: String? {
        switch self {
        case .invalidState(let reason), .invalidArgument(let reason): return reason
        case .requestIDsExhausted: return "Reconnect before V2 command IDs wrap"
        }
    }
}

/// Foundation-only V2 wire protocol. Legacy packets use their separate decoder.
enum WoonaV2Codec {
    static let maxPayload = 2048
    static let headerSize = 20
    static let maxRaw = headerSize + maxPayload + 4
    static let maxEncoded = maxRaw + maxRaw / 254 + 1
    static let helloCommand: UInt8 = 0x01
    static let getStreams: UInt8 = 0x02
    static let getStatus: UInt8 = 0x03
    static let startSession: UInt8 = 0x04
    static let stopSession: UInt8 = 0x05
    static let data: UInt8 = 0x40
    static let helloResponse: UInt8 = 0x81
    static let streamsResponse: UInt8 = 0x82
    static let statusResponse: UInt8 = 0x83
    static let startSessionResponse: UInt8 = 0x84
    static let stopSessionResponse: UInt8 = 0x85
    static let errorResponse: UInt8 = 0xff
    private static let magic: [UInt8] = [0x57, 0x4e, 0x41, 0x32]

    static func encodeRaw(type: UInt8, sequence: UInt32, requestID: UInt32,
                          payload: Data = Data(), flags: UInt8 = 0) throws -> Data {
        guard payload.count <= maxPayload else { throw V2ProtocolError.invalidArgument("V2 payload exceeds 2048 bytes") }
        var bytes = magic + [2, type, flags, UInt8(headerSize)]
        put16(UInt16(payload.count), into: &bytes); put16(0, into: &bytes)
        put32(sequence, into: &bytes); put32(requestID, into: &bytes)
        bytes.append(contentsOf: payload)
        put32(crc32(bytes), into: &bytes)
        return Data(bytes)
    }

    static func encodeWire(type: UInt8, sequence: UInt32, requestID: UInt32,
                           payload: Data = Data(), flags: UInt8 = 0) throws -> Data {
        var wire = try cobsEncode(encodeRaw(type: type, sequence: sequence, requestID: requestID, payload: payload, flags: flags))
        wire.append(0)
        return wire
    }

    static func decodeRaw(_ raw: Data) -> V2Frame? {
        guard (24...maxRaw).contains(raw.count) else { return nil }
        let bytes = [UInt8](raw)
        guard Array(bytes[0..<4]) == magic, bytes[4] == 2, bytes[7] == UInt8(headerSize),
              u16(bytes, 10) == 0 else { return nil }
        let length = Int(u16(bytes, 8))
        guard length <= maxPayload, length + 24 == bytes.count,
              u32(bytes, 20 + length) == crc32(Array(bytes.prefix(20 + length))) else { return nil }
        return V2Frame(type: bytes[5], flags: bytes[6], sequence: u32(bytes, 12),
                       requestID: u32(bytes, 16), payload: Data(bytes[20..<(20 + length)]))
    }

    static func cobsEncode(_ raw: Data) throws -> Data {
        guard raw.count <= maxRaw else { throw V2ProtocolError.invalidArgument("V2 COBS input exceeds the maximum frame size") }
        var result: [UInt8] = [0]
        result.reserveCapacity(raw.count + raw.count / 254 + 2)
        var position = 0
        var code = 1
        for byte in raw {
            if byte == 0 {
                result[position] = UInt8(code); position = result.count
                result.append(0); code = 1
            } else {
                result.append(byte); code += 1
                if code == 255 {
                    result[position] = 255; position = result.count
                    result.append(0); code = 1
                }
            }
        }
        result[position] = UInt8(code)
        return Data(result)
    }

    static func cobsDecode(_ encoded: Data) -> Data? {
        guard !encoded.isEmpty, encoded.count <= maxEncoded else { return nil }
        let bytes = [UInt8](encoded)
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let code = Int(bytes[index]); index += 1
            guard code > 0, code - 1 <= bytes.count - index else { return nil }
            for _ in 0..<(code - 1) {
                let byte = bytes[index]; index += 1
                guard byte != 0 else { return nil }
                result.append(byte)
            }
            if code != 255 && index < bytes.count { result.append(0) }
            guard result.count <= maxRaw else { return nil }
        }
        return Data(result)
    }

    static func hello(_ frame: V2Frame) -> V2Hello? {
        guard frame.type == helloResponse, frame.payload.count == 16 else { return nil }
        let bytes = [UInt8](frame.payload)
        guard u16(bytes, 2) == 0, u16(bytes, 14) == 0 else { return nil }
        return V2Hello(versionMin: Int(bytes[0]), versionMax: Int(bytes[1]), capabilities: u32(bytes, 4),
                       streamMask: u32(bytes, 8), maxPayload: Int(u16(bytes, 12)))
    }

    static func streams(_ frame: V2Frame) -> V2Streams? {
        guard frame.type == streamsResponse, (8...maxPayload).contains(frame.payload.count) else { return nil }
        let bytes = [UInt8](frame.payload)
        guard bytes[2] == 8, bytes[3] == 0 else { return nil }
        let count = Int(bytes[1])
        guard count <= 32, bytes.count == 8 + count * 8 else { return nil }
        var descriptors: [V2Stream] = []
        for index in 0..<count {
            let offset = 8 + index * 8
            guard bytes[offset + 3] == 0 else { return nil }
            descriptors.append(V2Stream(id: Int(bytes[offset]), format: Int(bytes[offset + 1]),
                channels: Int(bytes[offset + 2]), nativeRateHz: u32(bytes, offset + 4)))
        }
        let streams = V2Streams(status: Int(bytes[0]), streamMask: u32(bytes, 4), descriptors: descriptors)
        return streams.status != 0 || validStreams(streams) ? streams : nil
    }

    static func validStreams(_ streams: V2Streams) -> Bool {
        guard streams.status == 0, streams.streamMask != 0, (1...32).contains(streams.descriptors.count) else { return false }
        var mask: UInt32 = 0
        for descriptor in streams.descriptors {
            guard (1...32).contains(descriptor.id), (1...2).contains(descriptor.format),
                  (1...16).contains(descriptor.channels), descriptor.nativeRateHz > 0 else { return false }
            if (1...7).contains(descriptor.id) {
                guard descriptor.format == (descriptor.id == 5 ? 2 : 1),
                      descriptor.channels == (descriptor.id <= 2 ? 3 : 1) else { return false }
            }
            let bit = UInt32(1) << (descriptor.id - 1)
            guard (mask & bit) == 0 else { return false }
            mask |= bit
        }
        return mask == streams.streamMask
    }

    static func liveData(_ frame: V2Frame) -> V2LiveData? {
        guard frame.type == data, (24...maxPayload).contains(frame.payload.count) else { return nil }
        let bytes = [UInt8](frame.payload)
        guard bytes[5] == 0 else { return nil }
        return V2LiveData(sessionID: u32(bytes, 0), streamID: Int(bytes[4]), flags: Int(u16(bytes, 6)),
            count: Int(u16(bytes, 8)), rateHz: Int(u16(bytes, 10)), streamSequence: u32(bytes, 12),
            timestampUs: u64(bytes, 16), samples: Data(bytes.dropFirst(24)))
    }

    static func error(_ frame: V2Frame) -> V2Error? {
        guard frame.type == errorResponse, frame.payload.count == 4 else { return nil }
        let bytes = [UInt8](frame.payload)
        guard bytes[2] == 0, bytes[3] == 0 else { return nil }
        return V2Error(status: Int(bytes[0]), offendingType: bytes[1])
    }

    static func statusDescription(_ status: Int) -> String {
        switch status {
        case 0: return "ok"
        case 1: return "invalid message"
        case 2: return "invalid argument"
        case 3: return "unsupported stream"
        case 4: return "device busy; preserve its active session"
        case 5: return "no recording sink available"
        case 6: return "invalid device state"
        case 7: return "invalid session"
        case 8: return "device internal error"
        case 9: return "request ID conflicts with a cached command"
        case 10: return "request ID expired; reconcile device state before another action"
        case 11: return "not found"
        case 12: return "device storage error"
        default: return "unknown device status"
        }
    }

    static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
    static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 { value |= UInt32(bytes[offset + index]) << (index * 8) }
        return value
    }
    static func u64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 { value |= UInt64(bytes[offset + index]) << (index * 8) }
        return value
    }
    static func put16(_ value: UInt16, into bytes: inout [UInt8]) {
        for shift in stride(from: 0, to: 16, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    static func put32(_ value: UInt32, into bytes: inout [UInt8]) {
        for shift in stride(from: 0, to: 32, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    static func put64(_ value: UInt64, into bytes: inout [UInt8]) {
        for shift in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = (value >> 1) ^ ((value & 1) == 0 ? 0 : 0xedb88320) }
        return value
    }
    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in bytes { crc = crcTable[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8) }
        return crc ^ 0xffffffff
    }
}

/// One instance per connection, owned by the caller's serial protocol queue.
final class WoonaV2StreamDecoder {
    private var pending: [UInt8] = []
    private var discarding = false
    private(set) var rejectedFrames: UInt64 = 0
    func reset() { pending.removeAll(keepingCapacity: true); discarding = false; rejectedFrames = 0 }
    func append(_ bytes: Data) -> [V2Frame] {
        var frames: [V2Frame] = []
        for byte in bytes {
            if byte == 0 {
                if !discarding && !pending.isEmpty {
                    if let raw = WoonaV2Codec.cobsDecode(Data(pending)), let frame = WoonaV2Codec.decodeRaw(raw) {
                        frames.append(frame)
                    } else { reject() }
                }
                pending.removeAll(keepingCapacity: true); discarding = false
            } else if !discarding {
                if pending.count >= WoonaV2Codec.maxEncoded {
                    pending.removeAll(keepingCapacity: true); discarding = true; reject()
                } else { pending.append(byte) }
            }
        }
        return frames
    }
    private func reject() { if rejectedFrames < UInt64.max { rejectedFrames += 1 } }
}
