import Foundation

struct ValidatedPacket: Equatable {
    let bytes: [UInt8]
    let counter: UInt64
    let timerMillis: UInt64
    let measurementCount: Int
    let sensorBlocks: [SensorBlock]

    func channelSamples(sensorType: Int, channel: Int) -> [Float] {
        guard channel > 0 else { return [] }

        return sensorBlocks.flatMap { block -> [Float] in
            guard block.sensorType == sensorType, channel <= block.channelSamples.count else {
                return []
            }
            return block.channelSamples[channel - 1]
        }
    }
}

enum PacketValidationFailureReason: String, Equatable {
    case invalidStart = "Invalid packet start marker"
    case invalidLength = "Invalid packet length"
    case invalidMeasurementCount = "Invalid measurement count"
    case invalidSensorBlocks = "Invalid sensor block layout"
}

enum PacketValidationResult: Equatable {
    case accepted(ValidatedPacket)
    case rejected(PacketValidationFailureReason)
}

struct PacketValidator {
    private let sensorBlockParser: SensorBlockParser

    init(sensorBlockParser: SensorBlockParser = SensorBlockParser()) {
        self.sensorBlockParser = sensorBlockParser
    }

    func validate(_ packetBytes: [UInt8]) -> PacketValidationResult {
        validate(packetBytes, parseResult: sensorBlockParser.parseResult(packetBytes))
    }

    private func validate(
        _ packetBytes: [UInt8],
        parseResult: SensorBlockParseResult
    ) -> PacketValidationResult {
        guard packetBytes.count >= Self.minimumPacketSize else {
            return .rejected(.invalidLength)
        }

        guard Self.hasStartMarker(packetBytes, at: 0) else {
            return .rejected(.invalidStart)
        }

        let declaredLength = Self.decodeLength(packetBytes, at: 0)
        guard declaredLength == packetBytes.count,
              (Self.minimumPacketSize...Self.maximumPacketSize).contains(declaredLength) else {
            return .rejected(.invalidLength)
        }

        let measurementCount = Int(packetBytes[Self.measurementCountOffset])
        guard (1...Self.maximumMeasurementCount).contains(measurementCount) else {
            return .rejected(.invalidMeasurementCount)
        }

        guard isValidSensorBlockLayout(parseResult, measurementCount: measurementCount, packetLength: packetBytes.count) else {
            return .rejected(.invalidSensorBlocks)
        }

        return .accepted(
            ValidatedPacket(
                bytes: packetBytes,
                counter: Self.decodeCounter(packetBytes, at: 0),
                timerMillis: Self.decodeTimer(packetBytes, at: 0),
                measurementCount: measurementCount,
                sensorBlocks: parseResult.blocks
            )
        )
    }

    private func isValidSensorBlockLayout(
        _ parseResult: SensorBlockParseResult,
        measurementCount: Int,
        packetLength: Int
    ) -> Bool {
        guard parseResult.parsedBlockCount == measurementCount else { return false }
        guard parseResult.blocks.count == measurementCount else { return false }
        guard parseResult.blocks.allSatisfy({ !$0.channelSamples.isEmpty }) else { return false }

        let trailerByteCount = packetLength - parseResult.consumedBytes
        return (0...Self.maximumSensorBlockTrailerBytes).contains(trailerByteCount)
    }

    static func hasStartMarker(_ bytes: [UInt8], at offset: Int) -> Bool {
        guard offset >= 0, offset + startMarker.count <= bytes.count else { return false }
        return bytes[offset..<(offset + startMarker.count)].elementsEqual(startMarker)
    }

    static func decodeLength(_ bytes: [UInt8], at offset: Int = 0) -> Int {
        Int(bytes[offset + lengthOffset]) | (Int(bytes[offset + lengthOffset + 1]) << 8)
    }

    static func decodeCounter(_ bytes: [UInt8], at offset: Int = 0) -> UInt64 {
        UInt64(bytes[offset + counterOffset]) |
            (UInt64(bytes[offset + counterOffset + 1]) << 8) |
            (UInt64(bytes[offset + counterOffset + 2]) << 16) |
            (UInt64(bytes[offset + counterOffset + 3]) << 24)
    }

    static func decodeTimer(_ bytes: [UInt8], at offset: Int = 0) -> UInt64 {
        UInt64(bytes[offset + timerOffset]) |
            (UInt64(bytes[offset + timerOffset + 1]) << 8) |
            (UInt64(bytes[offset + timerOffset + 2]) << 16) |
            (UInt64(bytes[offset + timerOffset + 3]) << 24)
    }

    static let startMarker: [UInt8] = [0x33, 0x99, 0xAA, 0x55]
    static let minimumPacketSize = 16
    static let maximumPacketSize = 16_384
    static let maximumMeasurementCount = 4
    static let maximumSensorBlockTrailerBytes = 4
    static let lengthOffset = 4
    static let measurementCountOffset = 6
    static let counterOffset = 7
    static let timerOffset = 11
}
