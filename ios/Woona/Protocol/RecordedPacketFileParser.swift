import Foundation

enum RecordedPacketFileParserError: Error, Equatable, LocalizedError {
    case truncatedPacketHeader(offset: Int)
    case invalidPacketStartMarker(offset: Int)
    case invalidPacketLength(length: Int, offset: Int)
    case truncatedPacketBody(offset: Int, expectedLength: Int)

    var errorDescription: String? {
        switch self {
        case let .truncatedPacketHeader(offset):
            "Truncated packet header at offset \(offset)"
        case let .invalidPacketStartMarker(offset):
            "Invalid packet start marker at offset \(offset)"
        case let .invalidPacketLength(length, offset):
            "Invalid packet length \(length) at offset \(offset)"
        case let .truncatedPacketBody(offset, expectedLength):
            "Truncated packet body at offset \(offset): expected \(expectedLength) bytes"
        }
    }
}

struct RecordedPacketFileParser {
    func splitIntoPackets(_ fileBytes: [UInt8]) throws -> [[UInt8]] {
        var packets: [[UInt8]] = []
        try forEachPacket(fileBytes) { packets.append($0) }
        return packets
    }

    func forEachPacket(_ fileBytes: [UInt8], onPacket: ([UInt8]) throws -> Void) throws {
        var remaining = fileBytes[...]
        try forEachPacket(read: { count in
            let bytes = Array(remaining.prefix(count))
            remaining = remaining.dropFirst(bytes.count)
            return bytes
        }, onPacket: onPacket)
    }

    func forEachPacket(in file: URL, onPacket: ([UInt8]) throws -> Void) throws {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        try forEachPacket(read: input.readReplayBytes, onPacket: onPacket)
    }

    func forEachPacket(read: (Int) throws -> [UInt8], onPacket: ([UInt8]) throws -> Void) throws {
        var offset = 0
        while let packet = try readPacket(read: read, offset: &offset) {
            try onPacket(packet)
        }
    }

    func readPacket(read: (Int) throws -> [UInt8], offset: inout Int) throws -> [UInt8]? {
        let header = try read(PacketValidator.minimumPacketSize)
        guard !header.isEmpty else { return nil }
        guard header.count == PacketValidator.minimumPacketSize else {
            throw RecordedPacketFileParserError.truncatedPacketHeader(offset: offset)
        }
        guard PacketValidator.hasStartMarker(header, at: 0) else {
            throw RecordedPacketFileParserError.invalidPacketStartMarker(offset: offset)
        }
        let length = PacketValidator.decodeLength(header)
        guard (PacketValidator.minimumPacketSize...PacketValidator.maximumPacketSize).contains(length) else {
            throw RecordedPacketFileParserError.invalidPacketLength(length: length, offset: offset)
        }
        let body = try read(length - header.count)
        guard header.count + body.count == length else {
            throw RecordedPacketFileParserError.truncatedPacketBody(offset: offset, expectedLength: length)
        }
        offset += length
        return header + body
    }
}

extension FileHandle {
    // Short reads are legal; a hostile declared length must not preallocate its full size.
    func readReplayBytes(upToCount count: Int) throws -> [UInt8] {
        var bytes: [UInt8] = []
        while bytes.count < count {
            try Task.checkCancellation()
            let chunk = try read(upToCount: min(count - bytes.count, 64 * 1024)) ?? Data()
            if chunk.isEmpty { break }
            bytes.append(contentsOf: chunk)
        }
        return bytes
    }
}
