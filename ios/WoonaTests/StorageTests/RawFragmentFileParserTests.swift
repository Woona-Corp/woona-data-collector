import XCTest
@testable import Woona

final class RawFragmentFileParserTests: XCTestCase {
    private let parser = RawFragmentFileParser()

    func testRejectsOutOfBudgetSignedLengthsBeforeBodyReadForBothVersions() {
        for isV2 in [false, true] {
            for length in [Int32.min, -1, 0, Int32(RawFragmentFileParser.maximumFragmentLength + 1), Int32.max] {
                var header: [UInt8] = []
                header.appendBigEndianInt64(1); header.appendBigEndianInt64(2)
                if isV2 { header.appendBigEndianInt64(3) }
                header.appendBigEndianInt32(length)
                var reads = 0
                var offset = 8
                XCTAssertThrowsError(try parser.readFragment(read: { count in
                    reads += 1
                    XCTAssertEqual(reads, 1, "Oversized body must never be requested")
                    XCTAssertEqual(count, isV2 ? 28 : 20)
                    return header
                }, isV2: isV2, offset: &offset)) { error in
                    XCTAssertEqual(error as? RawFragmentFileParserError, .invalidFragmentLength(length: length, offset: 8))
                }
                XCTAssertEqual(reads, 1)
            }
        }
    }

    func testBudgetBoundaryAndLegacyHeadersRemainCompatible() throws {
        for isV2 in [false, true] {
            for size in [1, 512, 16_385, RawFragmentFileParser.maximumFragmentLength] {
                let body = [UInt8](repeating: 0xA5, count: size)
                var bytes = isV2 ? RawFragmentFileStore.magicHeader : RawFragmentFileStore.legacyMagicHeader
                bytes.appendBigEndianInt64(7); bytes.appendBigEndianInt64(8)
                if isV2 { bytes.appendBigEndianInt64(9) }
                bytes.appendBigEndianInt32(Int32(size)); bytes += body
                XCTAssertEqual(try parser.splitIntoFragments(bytes), [RawFragmentRecord(sequence: 7, receivedAtMillis: 8, receivedAtMonotonicNs: isV2 ? 9 : nil, bytes: body)])
                bytes.removeLast()
                XCTAssertThrowsError(try parser.splitIntoFragments(bytes)) { error in
                    XCTAssertEqual(error as? RawFragmentFileParserError, .truncatedFragmentBody(offset: 8, expectedLength: size))
                }
            }
        }
    }

    func testSplitIntoFragmentsReturnsStoredRecords() throws {
        let first: [UInt8] = [0x01, 0x02]
        let second: [UInt8] = [0x33, 0x99, 0xAA, 0x55]
        let fileBytes = RawFragmentFileStore.magicHeader
            + makeRawFragmentRecord(sequence: 10, receivedAtMillis: 1_000, bytes: first)
            + makeRawFragmentRecord(sequence: 11, receivedAtMillis: 1_015, bytes: second)

        let fragments = try parser.splitIntoFragments(fileBytes)

        XCTAssertEqual(
            fragments,
            [
                RawFragmentRecord(sequence: 10, receivedAtMillis: 1_000, receivedAtMonotonicNs: 0, bytes: first),
                RawFragmentRecord(sequence: 11, receivedAtMillis: 1_015, receivedAtMonotonicNs: 0, bytes: second)
            ]
        )
    }

    func testHasMagicHeaderIdentifiesRawFragmentFiles() {
        XCTAssertTrue(parser.hasMagicHeader(RawFragmentFileStore.magicHeader))
        XCTAssertTrue(parser.hasMagicHeader(RawFragmentFileStore.legacyMagicHeader))
        XCTAssertFalse(parser.hasMagicHeader([0x33, 0x99, 0xAA, 0x55]))
    }

    func testSplitIntoFragmentsRejectsInvalidMagicHeader() {
        XCTAssertThrowsError(try parser.splitIntoFragments([0x33, 0x99, 0xAA, 0x55])) { error in
            XCTAssertEqual(error as? RawFragmentFileParserError, .invalidMagicHeader)
        }
    }

    func testSplitIntoFragmentsRejectsTruncatedRecordHeader() {
        let fileBytes = RawFragmentFileStore.magicHeader + [0x00, 0x01]

        XCTAssertThrowsError(try parser.splitIntoFragments(fileBytes)) { error in
            XCTAssertEqual(
                error as? RawFragmentFileParserError,
                .truncatedRecordHeader(offset: RawFragmentFileStore.magicHeader.count)
            )
        }
    }

    func testSplitIntoFragmentsRejectsInvalidFragmentLength() {
        let fileBytes = RawFragmentFileStore.magicHeader
            + makeRawFragmentRecordHeader(sequence: 1, receivedAtMillis: 2, length: 0)

        XCTAssertThrowsError(try parser.splitIntoFragments(fileBytes)) { error in
            XCTAssertEqual(
                error as? RawFragmentFileParserError,
                .invalidFragmentLength(length: 0, offset: RawFragmentFileStore.magicHeader.count)
            )
        }
    }

    func testSplitIntoFragmentsRejectsTruncatedFragmentBody() {
        let fileBytes = RawFragmentFileStore.magicHeader
            + makeRawFragmentRecordHeader(sequence: 1, receivedAtMillis: 2, length: 3)
            + [0x01, 0x02]

        XCTAssertThrowsError(try parser.splitIntoFragments(fileBytes)) { error in
            XCTAssertEqual(
                error as? RawFragmentFileParserError,
                .truncatedFragmentBody(offset: RawFragmentFileStore.magicHeader.count, expectedLength: 3)
            )
        }
    }
}

private func makeRawFragmentRecord(sequence: Int64, receivedAtMillis: Int64, bytes: [UInt8]) -> [UInt8] {
    makeRawFragmentRecordHeader(sequence: sequence, receivedAtMillis: receivedAtMillis, length: Int32(bytes.count)) + bytes
}

private func makeRawFragmentRecordHeader(sequence: Int64, receivedAtMillis: Int64, length: Int32) -> [UInt8] {
    var bytes: [UInt8] = []
    bytes.appendBigEndianInt64(sequence)
    bytes.appendBigEndianInt64(receivedAtMillis)
    bytes.appendBigEndianInt64(0)
    bytes.appendBigEndianInt32(length)
    return bytes
}
