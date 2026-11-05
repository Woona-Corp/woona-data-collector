import Foundation

enum RawFragmentFileParserError: Error, Equatable, LocalizedError {
    case invalidMagicHeader
    case truncatedRecordHeader(offset: Int)
    case invalidFragmentLength(length: Int32, offset: Int)
    case truncatedFragmentBody(offset: Int, expectedLength: Int)

    var errorDescription: String? {
        switch self {
        case .invalidMagicHeader:
            "Raw fragment file has an invalid magic header"
        case let .truncatedRecordHeader(offset):
            "Truncated raw fragment record header at offset \(offset)"
        case let .invalidFragmentLength(length, offset):
            "Invalid raw fragment length \(length) at offset \(offset)"
        case let .truncatedFragmentBody(offset, expectedLength):
            "Truncated raw fragment body at offset \(offset): expected \(expectedLength) bytes"
        }
    }
}

struct RawFragmentRecord: Equatable {
    let sequence: Int64
    let receivedAtMillis: Int64
    let receivedAtMonotonicNs: Int64?
    let bytes: [UInt8]

    init(sequence: Int64, receivedAtMillis: Int64, receivedAtMonotonicNs: Int64? = nil, bytes: [UInt8]) {
        self.sequence = sequence
        self.receivedAtMillis = receivedAtMillis
        self.receivedAtMonotonicNs = receivedAtMonotonicNs
        self.bytes = bytes
    }
}

struct RawFragmentFileParser {
    func hasMagicHeader(_ bytes: [UInt8]) -> Bool {
        bytes.starts(with: RawFragmentFileStore.magicHeader)
            || bytes.starts(with: RawFragmentFileStore.legacyMagicHeader)
    }

    func splitIntoFragments(_ fileBytes: [UInt8]) throws -> [RawFragmentRecord] {
        var fragments: [RawFragmentRecord] = []
        try forEachFragment(fileBytes) { fragments.append($0) }
        return fragments
    }

    func forEachFragment(_ fileBytes: [UInt8], onFragment: (RawFragmentRecord) throws -> Void) throws {
        var remaining = fileBytes[...]
        try forEachFragment(read: { count in
            let bytes = Array(remaining.prefix(count))
            remaining = remaining.dropFirst(bytes.count)
            return bytes
        }, onFragment: onFragment)
    }

    func forEachFragment(read: (Int) throws -> [UInt8], onFragment: (RawFragmentRecord) throws -> Void) throws {
        let isV2 = try readMagicHeader(read: read)
        var offset = RawFragmentFileStore.magicHeader.count
        while let fragment = try readFragment(read: read, isV2: isV2, offset: &offset) {
            try onFragment(fragment)
        }
    }

    func readMagicHeader(read: (Int) throws -> [UInt8]) throws -> Bool {
        let magic = try read(RawFragmentFileStore.magicHeader.count)
        guard hasMagicHeader(magic) else { throw RawFragmentFileParserError.invalidMagicHeader }
        return magic == RawFragmentFileStore.magicHeader
    }

    func readFragment(read: (Int) throws -> [UInt8], isV2: Bool, offset: inout Int) throws -> RawFragmentRecord? {
        let headerSize = isV2 ? Self.v2RecordHeaderSize : Self.v1RecordHeaderSize
        let header = try read(headerSize)
        guard !header.isEmpty else { return nil }
        guard header.count == headerSize else {
            throw RawFragmentFileParserError.truncatedRecordHeader(offset: offset)
        }
        let length = Self.decodeBigEndianInt32(header, at: isV2 ? 24 : 16)
        guard length > 0 else {
            throw RawFragmentFileParserError.invalidFragmentLength(length: length, offset: offset)
        }
        let bytes = try read(Int(length))
        guard bytes.count == Int(length) else {
            throw RawFragmentFileParserError.truncatedFragmentBody(offset: offset, expectedLength: Int(length))
        }
        offset += headerSize + bytes.count
        return RawFragmentRecord(
            sequence: Self.decodeBigEndianInt64(header, at: 0),
            receivedAtMillis: Self.decodeBigEndianInt64(header, at: 8),
            receivedAtMonotonicNs: isV2 ? Self.decodeBigEndianInt64(header, at: 16) : nil,
            bytes: bytes
        )
    }

    private static func decodeBigEndianInt64(_ bytes: [UInt8], at offset: Int) -> Int64 {
        var value: UInt64 = 0
        for index in offset..<(offset + 8) {
            value = (value << 8) | UInt64(bytes[index])
        }
        return Int64(bitPattern: value)
    }

    private static func decodeBigEndianInt32(_ bytes: [UInt8], at offset: Int) -> Int32 {
        var value: UInt32 = 0
        for index in offset..<(offset + 4) {
            value = (value << 8) | UInt32(bytes[index])
        }
        return Int32(bitPattern: value)
    }

    private static let v1RecordHeaderSize = 20
    private static let v2RecordHeaderSize = 28
}
