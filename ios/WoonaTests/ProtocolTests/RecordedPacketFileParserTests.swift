import XCTest
@testable import Woona

final class RecordedPacketFileParserTests: XCTestCase {
    private let parser = RecordedPacketFileParser()

    func testSplitIntoPacketsReturnsSequentialPacketsFromDump() throws {
        let first = makeTestPacket(counter: 1, measurementCount: 1)
        let second = makeTestPacket(counter: 2, payloadSize: 2, measurementCount: 1)

        let packets = try parser.splitIntoPackets(first + second)

        XCTAssertEqual(packets.count, 2)
        XCTAssertEqual(packets[0], first)
        XCTAssertEqual(packets[1], second)
    }

    func testSplitIntoPacketsReturnsEmptyListForEmptyDump() throws {
        XCTAssertEqual(try parser.splitIntoPackets([]), [])
    }

    func testSplitIntoPacketsRejectsTruncatedPacketHeader() {
        XCTAssertThrowsError(try parser.splitIntoPackets([0x33, 0x99])) { error in
            XCTAssertEqual(error as? RecordedPacketFileParserError, .truncatedPacketHeader(offset: 0))
        }
    }

    func testSplitIntoPacketsRejectsInvalidStartMarker() {
        var packet = makeTestPacket(counter: 1, measurementCount: 1)
        packet[0] = 0x00

        XCTAssertThrowsError(try parser.splitIntoPackets(packet)) { error in
            XCTAssertEqual(error as? RecordedPacketFileParserError, .invalidPacketStartMarker(offset: 0))
        }
    }

    func testSplitIntoPacketsRejectsInvalidPacketLength() {
        var packet = makeTestPacket(counter: 1, measurementCount: 1)
        packet[4] = 0x0F
        packet[5] = 0x00

        XCTAssertThrowsError(try parser.splitIntoPackets(packet)) { error in
            XCTAssertEqual(error as? RecordedPacketFileParserError, .invalidPacketLength(length: 15, offset: 0))
        }
    }

    func testSplitIntoPacketsRejectsOversizedPacketLength() {
        var packet = makeTestPacket(counter: 1, measurementCount: 1)
        let oversizedLength = PacketValidator.maximumPacketSize + 1
        packet[4] = UInt8(oversizedLength & 0xFF)
        packet[5] = UInt8((oversizedLength >> 8) & 0xFF)

        XCTAssertThrowsError(try parser.splitIntoPackets(packet)) { error in
            XCTAssertEqual(error as? RecordedPacketFileParserError, .invalidPacketLength(length: oversizedLength, offset: 0))
        }
    }

    func testSplitIntoPacketsRejectsTruncatedPacketBody() {
        let packet = Array(makeTestPacket(counter: 1, payloadSize: 2, measurementCount: 1).dropLast())

        XCTAssertThrowsError(try parser.splitIntoPackets(packet)) { error in
            XCTAssertEqual(error as? RecordedPacketFileParserError, .truncatedPacketBody(offset: 0, expectedLength: 18))
        }
    }

    func testForEachPacketStreamsSequentialPackets() throws {
        let first = makeTestPacket(counter: 1, measurementCount: 1)
        let second = makeTestPacket(counter: 2, payloadSize: 2, measurementCount: 1)
        var packets: [[UInt8]] = []

        try parser.forEachPacket(first + second) { packetBytes in
            packets.append(packetBytes)
        }

        XCTAssertEqual(packets, [first, second])
    }

    func testFileAndArrayReportTheSameTruncatedTailOffset() throws {
        let prefix = makeTestPacket(counter: 1, measurementCount: 1)
        let bytes = prefix + [0x33, 0x99]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(bytes).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let expected = RecordedPacketFileParserError.truncatedPacketHeader(offset: prefix.count)
        XCTAssertThrowsError(try parser.forEachPacket(bytes) { _ in }) { error in
            XCTAssertEqual(error as? RecordedPacketFileParserError, expected)
        }
        XCTAssertThrowsError(try parser.forEachPacket(in: file) { _ in }) { error in
            XCTAssertEqual(error as? RecordedPacketFileParserError, expected)
        }
    }
}
