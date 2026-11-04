import Foundation

enum CsvExporterError: Error, Equatable {
    case invalidPacket(PacketValidationFailureReason)
}

struct CsvExporter {
    private let packetValidator: PacketValidator
    private let timestampFormatter: (Int64) -> String

    init(
        packetValidator: PacketValidator = PacketValidator(),
        timestampFormatter: @escaping (Int64) -> String = CsvExporter.defaultTimestampFormatter
    ) {
        self.packetValidator = packetValidator
        self.timestampFormatter = timestampFormatter
    }

    @discardableResult
    func export(
        packetFile: URL,
        sessionStartMillis: Int64,
        targetFile: URL
    ) throws -> URL {
        var columns = Set<CsvColumnKey>()
        var firstSampleTimerMillis: Int64?
        var previousSampleTimerMillis: Int64?

        try RecordedPacketFileParser().forEachPacket(in: packetFile) { packetBytes in
            switch packetValidator.validate(packetBytes) {
            case let .accepted(packet):
                let rows = buildRows(
                    sensorBlocks: packet.sensorBlocks,
                    packetDeviceTimeMillis: Int64(packet.timerMillis),
                    previousSampleTimerMillis: previousSampleTimerMillis
                )
                for row in rows {
                    columns.formUnion(row.values.keys)
                    if firstSampleTimerMillis == nil {
                        firstSampleTimerMillis = row.sampleTimerMillis
                    }
                }
                previousSampleTimerMillis = rows.last?.sampleTimerMillis ?? previousSampleTimerMillis
            case let .rejected(reason):
                throw CsvExporterError.invalidPacket(reason)
            }
        }

        let orderedColumns = columns.sorted {
            ($0.sensorType, $0.channel) < ($1.sensorType, $1.channel)
        }

        try FileManager.default.createDirectory(
            at: targetFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if FileManager.default.fileExists(atPath: targetFile.path) {
            try Data().write(to: targetFile)
        } else {
            FileManager.default.createFile(atPath: targetFile.path, contents: nil)
        }

        let output = try FileHandle(forWritingTo: targetFile)
        defer {
            try? output.close()
        }

        try output.write(contentsOf: Data(header(columns: orderedColumns).utf8))
        previousSampleTimerMillis = nil

        try RecordedPacketFileParser().forEachPacket(in: packetFile) { packetBytes in
            switch packetValidator.validate(packetBytes) {
            case let .accepted(packet):
                let rows = buildRows(
                    sensorBlocks: packet.sensorBlocks,
                    packetDeviceTimeMillis: Int64(packet.timerMillis),
                    previousSampleTimerMillis: previousSampleTimerMillis
                )
                for row in rows {
                    let baselineSampleTimerMillis = firstSampleTimerMillis ?? row.sampleTimerMillis
                    let derivedTimeMillis = sessionStartMillis + (row.sampleTimerMillis - baselineSampleTimerMillis)
                    var line = timestampFormatter(derivedTimeMillis)
                    line.append(",")
                    line.append(String(row.packetDeviceTimeMillis))
                    line.append(",")
                    line.append(String(row.sampleTimerMillis))
                    for column in orderedColumns {
                        line.append(",")
                        if let value = row.values[column] {
                            line.append(Self.formatNumericValue(value))
                        }
                    }
                    line.append("\n")
                    try output.write(contentsOf: Data(line.utf8))
                }
                previousSampleTimerMillis = rows.last?.sampleTimerMillis ?? previousSampleTimerMillis
            case let .rejected(reason):
                throw CsvExporterError.invalidPacket(reason)
            }
        }

        try output.synchronize()
        return targetFile
    }

    private func header(columns: [CsvColumnKey]) -> String {
        let base = "estimated_time,device_timer_millis,sample_timer_millis"
        let dynamicColumns = columns.map(\.headerName)
        return ([base] + dynamicColumns).joined(separator: ",") + "\n"
    }

    private func buildRows(
        sensorBlocks: [SensorBlock],
        packetDeviceTimeMillis: Int64,
        previousSampleTimerMillis: Int64?
    ) -> [CsvRow] {
        var samplesByStream: [CsvColumnKey: [Float]] = [:]

        for sensorBlock in sensorBlocks {
            for (channelIndex, samples) in sensorBlock.channelSamples.enumerated() where !samples.isEmpty {
                let column = CsvColumnKey(sensorType: sensorBlock.sensorType, channel: channelIndex + 1)
                samplesByStream[column, default: []].append(contentsOf: samples)
            }
        }

        let rowCount = samplesByStream.values.map(\.count).max() ?? 0
        let packetStartSampleTimerMillis = max(
            packetDeviceTimeMillis,
            (previousSampleTimerMillis ?? Int64.min) + 1
        )

        return (0..<rowCount).map { sampleIndex in
            var values: [CsvColumnKey: Float] = [:]
            for (column, samples) in samplesByStream {
                if sampleIndex < samples.count {
                    values[column] = samples[sampleIndex]
                }
            }

            return CsvRow(
                packetDeviceTimeMillis: packetDeviceTimeMillis,
                sampleTimerMillis: packetStartSampleTimerMillis + Int64(sampleIndex),
                values: values
            )
        }
    }

    private static func formatNumericValue(_ value: Float) -> String {
        guard value.isFinite else { return String(describing: value) }
        if value.rounded() == value {
            return String(Int64(value))
        }

        var text = String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
        while text.last == "0" {
            text.removeLast()
        }
        if text.last == "." {
            text.removeLast()
        }
        return text
    }

    private static func defaultTimestampFormatter(_ millis: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(millis) / 1_000)
        return defaultDateFormatter.string(from: date)
    }

    private static let defaultDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private struct CsvColumnKey: Hashable {
        let sensorType: Int
        let channel: Int

        var headerName: String {
            "\(Self.sensorNamePrefix(sensorType))_sensor_\(sensorType)_ch_\(channel)"
        }

        private static func sensorNamePrefix(_ sensorType: Int) -> String {
            switch sensorType {
            case 1:
                "t"
            case 2:
                "axl"
            case 3:
                "gir"
            case 4:
                "mic"
            default:
                "unknown"
            }
        }
    }

    private struct CsvRow {
        let packetDeviceTimeMillis: Int64
        let sampleTimerMillis: Int64
        let values: [CsvColumnKey: Float]
    }
}
