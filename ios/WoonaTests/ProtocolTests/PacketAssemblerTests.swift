import XCTest
@testable import Woona

final class PacketAssemblerTests: XCTestCase {
    func testAppendEmitsPacketWhenWholePacketArrives() {
        let assembler = PacketAssembler()
        let packet = makeTestPacket(counter: 7)

        let packets = assembler.append(packet)

        XCTAssertEqual(packets.count, 1)
        guard case let .completed(completed) = packets.single else {
            return XCTFail("Expected completed packet")
        }
        XCTAssertEqual(completed.bytes, packet)
        XCTAssertEqual(completed.counter, 7)
        XCTAssertTrue(completed.sensorBlocks.isEmpty)
    }

    func testAppendReassemblesFragmentsAcrossChunks() {
        let assembler = PacketAssembler()
        let packet = makeTestPacket(counter: 42, payloadSize: 8)

        let firstHalf = assembler.append(Array(packet[0..<10]))
        let secondHalf = assembler.append(Array(packet[10..<packet.count]))

        XCTAssertTrue(firstHalf.isEmpty)
        XCTAssertEqual(secondHalf.count, 1)
        guard case let .completed(completed) = secondHalf.single else {
            return XCTFail("Expected completed packet")
        }
        XCTAssertEqual(completed.bytes, packet)
        XCTAssertEqual(completed.counter, 42)
    }

    func testAppendDiscardsLeadingGarbageBeforeHeader() {
        let assembler = PacketAssembler()
        let packet = makeTestPacket(counter: 99)
        let chunk: [UInt8] = [0x00, 0x11, 0x22] + packet

        let packets = assembler.append(chunk)

        XCTAssertEqual(packets.count, 1)
        guard case let .completed(completed) = packets.single else {
            return XCTFail("Expected completed packet")
        }
        XCTAssertEqual(completed.bytes, packet)
    }

    func testAppendEmitsMultiplePacketsFromSingleChunk() {
        let assembler = PacketAssembler()
        let first = makeTestPacket(counter: 1)
        let second = makeTestPacket(counter: 2, payloadSize: 4)

        let packets = assembler.append(first + second)

        XCTAssertEqual(packets.compactMap(\.completedPacket?.counter), [1, 2])
    }

    func testAppendSkipsMalformedLengthAndResynchronizes() {
        let assembler = PacketAssembler()
        let malformed: [UInt8] = [0x33, 0x99, 0xAA, 0x55, 0x01, 0x00] + Array(repeating: 0, count: 10)
        let valid = makeTestPacket(counter: 5)

        let packets = assembler.append(malformed + valid)

        XCTAssertEqual(packets.count, 1)
        guard case let .completed(completed) = packets.single else {
            return XCTFail("Expected completed packet")
        }
        XCTAssertEqual(completed.counter, 5)
        XCTAssertEqual(completed.bytes, valid)
    }

    func testAppendSkipsOversizedLengthAndResynchronizes() {
        let assembler = PacketAssembler()
        let oversizedLength = PacketValidator.maximumPacketSize + 1
        let malformed: [UInt8] = [
            0x33, 0x99, 0xAA, 0x55,
            UInt8(oversizedLength & 0xFF),
            UInt8((oversizedLength >> 8) & 0xFF)
        ] + Array(repeating: 0, count: 10)
        let valid = makeTestPacket(counter: 5)

        let packets = assembler.append(malformed + valid)

        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets.single?.completedPacket?.counter, 5)
        XCTAssertEqual(packets.single?.completedPacket?.bytes, valid)
    }

    func testAppendParsesSensorBlocksIntoCompletedPacket() {
        let assembler = PacketAssembler()
        let packet = makeTestPacket(
            counter: 12,
            measurementCount: 1,
            blocks: [
                makeSensorBlock(
                    sensorType: 2,
                    channelSamples: [
                        [10, 20],
                        [30, 40]
                    ]
                )
            ]
        )

        let packets = assembler.append(packet)

        guard case let .completed(completed) = packets.single else {
            return XCTFail("Expected completed packet")
        }
        XCTAssertEqual(completed.channelSamples(sensorType: 2, channel: 2), [30, 40])
        guard case .accepted(let retained)? = completed.validation else {
            return XCTFail("Assembler must retain accepted parse evidence for the processor")
        }
        XCTAssertEqual(retained.bytes, packet)
        XCTAssertEqual(retained.sensorBlocks, completed.sensorBlocks)
        XCTAssertEqual(retained.counter, completed.counter)
        // An arbitrary CompletedPacket cannot mint validation from supplied blocks.
        let untrusted = CompletedPacket(bytes: packet, counter: 12, sensorBlocks: [])
        XCTAssertNil(untrusted.validation)
    }

    func testResetDiscardsBufferedFragmentsFromPreviousSession() {
        let assembler = PacketAssembler()
        let packet = makeTestPacket(counter: 42, payloadSize: 8)

        let firstHalf = assembler.append(Array(packet[0..<10]))
        assembler.reset()
        let secondHalf = assembler.append(Array(packet[10..<packet.count]))

        XCTAssertTrue(firstHalf.isEmpty)
        XCTAssertTrue(secondHalf.isEmpty)
    }

    func testAppendHandlesPartialHeaderAcrossFragments() {
        let assembler = PacketAssembler()
        let packet = makeTestPacket(counter: 21)

        XCTAssertTrue(assembler.append([0x00, 0x33, 0x99]).isEmpty)
        let packets = assembler.append([0xAA, 0x55] + Array(packet[4..<packet.count]))

        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets.single?.completedPacket?.bytes, packet)
    }

    func testAppendRejectsOverlappingPacketStartAtChunkBoundary() {
        let assembler = PacketAssembler()
        let first = makeTestPacket(
            counter: 1,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 2, channelSamples: [[10, 20]])]
        )
        let second = makeTestPacket(
            counter: 2,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 2, channelSamples: [[30, 40]])]
        )

        let firstChunk = assembler.append(Array(first[0..<20]))
        let secondChunk = assembler.append(second)

        XCTAssertTrue(firstChunk.isEmpty)
        XCTAssertEqual(secondChunk.count, 2)
        XCTAssertEqual(secondChunk.first?.rejectionReason?.rawValue, PacketAssemblyFailureReason.overlappingPacketStart().rawValue)
        XCTAssertEqual(secondChunk.last?.completedPacket?.counter, 2)
        XCTAssertEqual(secondChunk.last?.completedPacket?.bytes, second)
    }

    func testAppendRejectsOverlappingPacketAfterShortBoundaryFragment() {
        let assembler = PacketAssembler()
        let first = makeTestPacket(
            counter: 1,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 2, channelSamples: [[10, 20]])]
        )
        let second = makeTestPacket(
            counter: 2,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 2, channelSamples: [[30, 40]])]
        )

        let firstChunk = assembler.append(Array(first[0..<20]))
        let overlapPrefix = assembler.append(Array(second[0..<8]))
        let overlapRemainder = assembler.append(Array(second[8..<second.count]))

        XCTAssertTrue(firstChunk.isEmpty)
        XCTAssertTrue(overlapPrefix.isEmpty)
        XCTAssertEqual(overlapRemainder.count, 2)
        XCTAssertEqual(overlapRemainder.first?.rejectionReason?.rawValue, PacketAssemblyFailureReason.overlappingPacketStart().rawValue)
        XCTAssertEqual(overlapRemainder.last?.completedPacket?.counter, 2)
        XCTAssertEqual(overlapRemainder.last?.completedPacket?.bytes, second)
    }

    func testAppendWaitsAndRecoversWhenNestedPacketStartAppearsBeforeExpectedLength() {
        let assembler = PacketAssembler()
        let first = makeTestPacket(
            counter: 1,
            timerMillis: 100,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 2, channelSamples: [[1, 2, 3, 4, 5, 6, 7, 8, 9, 10]])]
        )
        let second = makeTestPacket(
            counter: 2,
            timerMillis: 200,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 2, channelSamples: [[30, 40]])]
        )
        let firstMissingTail = 16
        let firstPrefix = Array(first.dropLast(firstMissingTail))
        let secondHeader = Array(second.prefix(PacketValidator.minimumPacketSize))

        XCTAssertEqual(firstPrefix.count + secondHeader.count, first.count)
        XCTAssertTrue(assembler.append(firstPrefix + secondHeader).isEmpty)

        let recovered = assembler.append(Array(second.dropFirst(PacketValidator.minimumPacketSize)))

        XCTAssertEqual(recovered.count, 2)
        XCTAssertEqual(recovered.first?.rejectionReason?.rawValue, PacketAssemblyFailureReason.overlappingPacketStart().rawValue)
        XCTAssertTrue(recovered.first?.rejectionReason?.diagnosticMessage.contains("missingBytes=16") == true)
        XCTAssertEqual(recovered.last?.completedPacket?.counter, 2)
        XCTAssertEqual(recovered.last?.completedPacket?.bytes, second)
    }

    func testAppendRecoversWhenNestedPacketCounterSkipsMissingPacket() {
        let assembler = PacketAssembler()
        let corrupted = makeTestPacket(
            counter: 2,
            timerMillis: 2_000,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 2, channelSamples: [[1, 2, 3, 4, 5, 6, 7, 8]])]
        )
        let recovered = makeTestPacket(
            counter: 4,
            timerMillis: 4_000,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 2, channelSamples: [[30, 40]])]
        )
        let corruptedPrefix = Array(corrupted.dropLast(PacketValidator.minimumPacketSize))
        let recoveredHeader = Array(recovered.prefix(PacketValidator.minimumPacketSize))

        XCTAssertEqual(corruptedPrefix.count + recoveredHeader.count, corrupted.count)
        XCTAssertTrue(assembler.append(corruptedPrefix + recoveredHeader).isEmpty)

        let results = assembler.append(Array(recovered.dropFirst(PacketValidator.minimumPacketSize)))

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first?.rejectionReason?.rawValue, PacketAssemblyFailureReason.overlappingPacketStart().rawValue)
        XCTAssertEqual(results.last?.completedPacket?.counter, 4)
        XCTAssertEqual(results.last?.completedPacket?.bytes, recovered)
    }

    func testAppendRecoversWhenNestedPacketCounterSkipsLargeLossBurst() {
        let assembler = PacketAssembler()
        let corrupted = makeTestPacket(
            counter: 10,
            timerMillis: 10_000,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 2, channelSamples: [[1, 2, 3, 4, 5, 6, 7, 8]])]
        )
        let recovered = makeTestPacket(
            counter: 35,
            timerMillis: 35_000,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 2, channelSamples: [[30, 40]])]
        )
        let corruptedPrefix = Array(corrupted.dropLast(PacketValidator.minimumPacketSize))
        let recoveredHeader = Array(recovered.prefix(PacketValidator.minimumPacketSize))

        XCTAssertEqual(corruptedPrefix.count + recoveredHeader.count, corrupted.count)
        XCTAssertTrue(assembler.append(corruptedPrefix + recoveredHeader).isEmpty)

        let results = assembler.append(Array(recovered.dropFirst(PacketValidator.minimumPacketSize)))

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first?.rejectionReason?.rawValue, PacketAssemblyFailureReason.overlappingPacketStart().rawValue)
        XCTAssertEqual(results.last?.completedPacket?.counter, 35)
        XCTAssertEqual(results.last?.completedPacket?.bytes, recovered)
    }

    func testAppendBroadScansInvalidCompletePacketForNestedStart() {
        let assembler = PacketAssembler()
        let recovered = makeTestPacket(
            counter: 2,
            timerMillis: 1_100,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 2, channelSamples: [[30, 40]])]
        )
        var corrupted = makeTestPacket(
            counter: 1,
            timerMillis: 100,
            measurementCount: 1,
            payloadBytes: Array(repeating: 0, count: 5_984)
        )
        let nestedStartIndex = 1_500
        corrupted.replaceSubrange(nestedStartIndex..<(nestedStartIndex + recovered.count), with: recovered)

        let results = assembler.append(corrupted)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first?.rejectionReason?.rawValue, PacketAssemblyFailureReason.overlappingPacketStart().rawValue)
        XCTAssertEqual(results.last?.completedPacket?.counter, 2)
        XCTAssertEqual(results.last?.completedPacket?.bytes, recovered)
    }

    func testAppendContinuesScanningAfterIncompleteNestedCandidate() {
        let assembler = PacketAssembler()
        var fakeIncompleteHeader = makeTestPacket(
            counter: 2,
            timerMillis: 1_100,
            measurementCount: 1
        )
        let fakeDeclaredLength = 10_000
        fakeIncompleteHeader[4] = UInt8(fakeDeclaredLength & 0xFF)
        fakeIncompleteHeader[5] = UInt8((fakeDeclaredLength >> 8) & 0xFF)
        let recovered = makeTestPacket(
            counter: 3,
            timerMillis: 2_100,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 2, channelSamples: [[30, 40]])]
        )
        var corrupted = makeTestPacket(
            counter: 1,
            timerMillis: 100,
            measurementCount: 1,
            payloadBytes: Array(repeating: 0, count: 5_984)
        )
        let fakeStartIndex = 600
        let recoveredStartIndex = 1_500
        corrupted.replaceSubrange(
            fakeStartIndex..<(fakeStartIndex + fakeIncompleteHeader.count),
            with: fakeIncompleteHeader
        )
        corrupted.replaceSubrange(
            recoveredStartIndex..<(recoveredStartIndex + recovered.count),
            with: recovered
        )

        let results = assembler.append(corrupted)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first?.rejectionReason?.rawValue, PacketAssemblyFailureReason.overlappingPacketStart().rawValue)
        XCTAssertEqual(results.last?.completedPacket?.counter, 3)
        XCTAssertEqual(results.last?.completedPacket?.bytes, recovered)
    }

    func testAppendDoesNotTreatDistantPayloadHeaderAsOverlap() {
        let assembler = PacketAssembler()
        let fakeNested = makeTestPacket(
            counter: 2,
            timerMillis: 1_100,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 2, channelSamples: [[11]])]
        )
        var samples = Array(repeating: UInt8(0), count: 1_600)
        samples.replaceSubrange(0..<fakeNested.count, with: fakeNested)
        let payload: [UInt8] = [0x02, 0x01, 0x20, 0x03, 0x00, 0x00] + samples
        let packet = makeTestPacket(
            counter: 1,
            timerMillis: 100,
            measurementCount: 1,
            payloadBytes: payload
        )

        let packets = assembler.append(packet)

        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets.single?.completedPacket?.counter, 1)
        XCTAssertEqual(packets.single?.completedPacket?.bytes, packet)
    }

    func testAppendEmitsCompleteValidPacketBeforeScanningPlausibleNestedPayloadHeader() {
        let assembler = PacketAssembler()
        let fakeNested = makeTestPacket(
            counter: 2,
            timerMillis: 200,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 2, channelSamples: [[11]])]
        )
        XCTAssertEqual(fakeNested.count % 2, 0)
        let sampleCount = fakeNested.count / 2
        let payload: [UInt8] = [
            0x02,
            0x01,
            UInt8(sampleCount & 0xFF),
            UInt8((sampleCount >> 8) & 0xFF),
            0x00,
            0x00
        ] + fakeNested
        let packet = makeTestPacket(
            counter: 1,
            timerMillis: 100,
            measurementCount: 1,
            payloadBytes: payload
        )

        let packets = assembler.append(packet)

        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets.single?.completedPacket?.counter, 1)
        XCTAssertEqual(packets.single?.completedPacket?.bytes, packet)
    }

    func testAppendKeepsIncompletePacketWhenBoundaryHeaderPrefixTurnsOutInvalid() {
        let assembler = PacketAssembler()
        let packet = makeTestPacket(
            counter: 3,
            measurementCount: 1,
            payloadBytes: [0x33, 0x99, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60]
        )

        XCTAssertTrue(assembler.append(Array(packet[0..<16])).isEmpty)
        XCTAssertTrue(assembler.append(Array(packet[16..<18])).isEmpty)
        let completedChunk = assembler.append(Array(packet[18..<packet.count]))

        XCTAssertEqual(completedChunk.count, 1)
        XCTAssertEqual(completedChunk.single?.completedPacket?.counter, 3)
        XCTAssertEqual(completedChunk.single?.completedPacket?.bytes, packet)
    }

    func testAppendKeepsIncompletePacketWhenBoundaryHeaderLacksValidSensorBlocks() {
        let assembler = PacketAssembler()
        let packet = makeTestPacket(
            counter: 4,
            measurementCount: 1,
            payloadBytes: [
                0x33, 0x99, 0xAA, 0x55,
                0x10, 0x00,
                0x01,
                0x01, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00
            ]
        )

        XCTAssertTrue(assembler.append(Array(packet[0..<16])).isEmpty)
        let candidateChunk = assembler.append(Array(packet[16..<packet.count]))

        XCTAssertEqual(candidateChunk.count, 1)
        XCTAssertEqual(candidateChunk.single?.completedPacket?.counter, 4)
        XCTAssertEqual(candidateChunk.single?.completedPacket?.bytes, packet)
    }

    func testAppendKeepsIncompletePacketWhenBoundaryHeaderDoesNotAdvanceCounterOrTimer() {
        let assembler = PacketAssembler()
        let nestedPacket = makeTestPacket(
            counter: 5,
            timerMillis: 100,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 2, channelSamples: [[10, 20]])]
        )
        let packet = makeTestPacket(
            counter: 5,
            timerMillis: 100,
            measurementCount: 1,
            payloadBytes: nestedPacket
        )

        XCTAssertTrue(assembler.append(Array(packet[0..<16])).isEmpty)
        let boundaryCandidate = assembler.append(Array(packet[16..<packet.count]))

        XCTAssertEqual(boundaryCandidate.count, 1)
        XCTAssertEqual(boundaryCandidate.single?.completedPacket?.counter, 5)
        XCTAssertEqual(boundaryCandidate.single?.completedPacket?.bytes, packet)
    }
}

private extension Array {
    var single: Element? {
        count == 1 ? self[0] : nil
    }
}

private extension PacketAssemblyResult {
    var completedPacket: CompletedPacket? {
        guard case let .completed(packet) = self else { return nil }
        return packet
    }

    var rejectionReason: PacketAssemblyFailureReason? {
        guard case let .rejected(reason) = self else { return nil }
        return reason
    }
}
