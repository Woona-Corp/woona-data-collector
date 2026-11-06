package com.example.myapplication.storage

import com.example.myapplication.protocol.PacketValidationResult
import com.example.myapplication.protocol.PacketValidator
import com.example.myapplication.protocol.RecordedPacketFileParser
import com.example.myapplication.protocol.SensorBlock
import java.io.BufferedWriter
import java.io.File
import java.io.FileWriter
import java.math.BigDecimal
import java.time.Instant

class BleSessionCsvExporter(
    private val packetFileParser: RecordedPacketFileParser = RecordedPacketFileParser(),
    private val packetValidator: PacketValidator = PacketValidator(),
    private val timestampFormatter: (Long) -> String = { millis ->
        Instant.ofEpochMilli(millis).toString()
    },
) {
    fun export(
        packetFile: File,
        sessionStartMillis: Long,
        targetFile: File,
        packetTimelineFile: File? = null,
    ): File {
        val columns = linkedSetOf<CsvColumnKey>()
        var firstSampleTimerMillis: Long? = null
        var previousSampleTimerMillis: Long? = null

        packetFileParser.forEachPacket(packetFile) { packetBytes ->
            when (val validation = packetValidator.validate(packetBytes)) {
                is PacketValidationResult.Accepted -> {
                    val packetRows = buildRows(
                        sensorBlocks = validation.packet.sensorBlocks,
                        packetDeviceTimeMillis = validation.packet.timerMillis,
                        previousSampleTimerMillis = previousSampleTimerMillis,
                    )
                    packetRows.forEach { row ->
                        columns += row.values.keys
                        if (firstSampleTimerMillis == null) {
                            firstSampleTimerMillis = row.sampleTimerMillis
                        }
                    }
                    previousSampleTimerMillis = packetRows.lastOrNull()?.sampleTimerMillis ?: previousSampleTimerMillis
                }

                is PacketValidationResult.Rejected -> {
                    throw IllegalArgumentException(
                        "Packet dump contains an invalid packet: ${validation.reason}",
                    )
                }
            }
        }

        val orderedColumns = columns.sortedWith(
            compareBy<CsvColumnKey> { it.sensorType }
                .thenBy { it.channel },
        )
        targetFile.parentFile?.mkdirs()
        BufferedWriter(FileWriter(targetFile, false), BUFFER_SIZE_BYTES).use { writer ->
            writeHeader(writer, orderedColumns)
            previousSampleTimerMillis = null
            packetTimelineFile?.let(::BlePacketTimelineReader)
                .use { timeline ->
                    packetFileParser.forEachPacket(packetFile) { packetBytes ->
                        when (val validation = packetValidator.validate(packetBytes)) {
                            is PacketValidationResult.Accepted -> {
                                val timelineEntry = timeline?.next()
                                require(
                                    timeline == null || timelineEntry != null &&
                                        timelineEntry.counter == validation.packet.counter &&
                                        timelineEntry.deviceTimerMillis == validation.packet.timerMillis &&
                                        timelineEntry.packetBytes == packetBytes.size,
                                ) { "Packet timeline does not match packet dump" }
                                val packetRows = buildRows(
                                    sensorBlocks = validation.packet.sensorBlocks,
                                    packetDeviceTimeMillis = validation.packet.timerMillis,
                                    previousSampleTimerMillis = previousSampleTimerMillis,
                                )
                                packetRows.forEach { row ->
                                    val baselineSampleTimerMillis = firstSampleTimerMillis ?: row.sampleTimerMillis
                                    val sampleDeltaFromPacketMs =
                                        row.sampleTimerMillis - validation.packet.timerMillis
                                    val derivedTimeMillis = timelineEntry?.let {
                                        it.hostWallClockMillis + sampleDeltaFromPacketMs
                                    } ?: (
                                        sessionStartMillis +
                                            (row.sampleTimerMillis - baselineSampleTimerMillis)
                                        )
                                    writer.append(timestampFormatter(derivedTimeMillis))
                                    writer.append(CSV_SEPARATOR)
                                    timelineEntry?.let {
                                        writer.append(
                                            (it.hostMonotonicNs + sampleDeltaFromPacketMs * 1_000_000L)
                                                .toString(),
                                        )
                                    }
                                    writer.append(CSV_SEPARATOR)
                                    writer.append(row.packetDeviceTimeMillis.toString())
                                    writer.append(CSV_SEPARATOR)
                                    writer.append(row.sampleTimerMillis.toString())
                                    orderedColumns.forEach { column ->
                                        writer.append(CSV_SEPARATOR)
                                        row.values[column]?.let { value ->
                                            writer.append(formatNumericValue(value))
                                        }
                                    }
                                    writer.append('\n')
                                }
                                previousSampleTimerMillis =
                                    packetRows.lastOrNull()?.sampleTimerMillis ?: previousSampleTimerMillis
                            }

                            is PacketValidationResult.Rejected -> {
                                throw IllegalArgumentException(
                                    "Packet dump contains an invalid packet: ${validation.reason}",
                                )
                            }
                        }
                    }
                    require(timeline?.next() == null) { "Packet timeline has extra rows" }
                }
        }
        return targetFile
    }

    private fun writeHeader(
        writer: BufferedWriter,
        columns: List<CsvColumnKey>,
    ) {
        writer.append(COLUMN_ESTIMATED_UTC)
        writer.append(CSV_SEPARATOR)
        writer.append(COLUMN_HOST_MONOTONIC_NS)
        writer.append(CSV_SEPARATOR)
        writer.append(COLUMN_DEVICE_TIMER_MILLIS)
        writer.append(CSV_SEPARATOR)
        writer.append(COLUMN_SAMPLE_TIMER_MILLIS)
        columns.forEach { column ->
            writer.append(CSV_SEPARATOR)
            writer.append(column.headerName())
        }
        writer.append('\n')
    }

    private fun buildRows(
        sensorBlocks: List<SensorBlock>,
        packetDeviceTimeMillis: Long,
        previousSampleTimerMillis: Long?,
    ): List<CsvRow> {
        val samplesByStream = linkedMapOf<CsvColumnKey, MutableList<Float>>()
        sensorBlocks.forEach { sensorBlock ->
            sensorBlock.channelSamples.forEachIndexed { channelIndex, samples ->
                if (samples.isEmpty()) return@forEachIndexed

                val column = CsvColumnKey(
                    sensorType = sensorBlock.sensorType,
                    channel = channelIndex + 1,
                )
                samplesByStream.getOrPut(column) { mutableListOf() }.addAll(samples)
            }
        }

        val rowCount = samplesByStream.values.maxOfOrNull(List<Float>::size) ?: 0
        val packetStartSampleTimerMillis = maxOf(
            packetDeviceTimeMillis,
            (previousSampleTimerMillis ?: Long.MIN_VALUE) + 1,
        )
        return List(rowCount) { sampleIndex ->
            CsvRow(
                packetDeviceTimeMillis = packetDeviceTimeMillis,
                sampleTimerMillis = packetStartSampleTimerMillis + sampleIndex,
                values = buildMap {
                    samplesByStream.forEach { (column, values) ->
                        values.getOrNull(sampleIndex)?.let { put(column, it) }
                    }
                },
            )
        }
    }

    private fun formatNumericValue(value: Float): String {
        return BigDecimal.valueOf(value.toDouble())
            .stripTrailingZeros()
            .toPlainString()
    }

    private data class CsvColumnKey(
        val sensorType: Int,
        val channel: Int,
    ) {
        fun headerName(): String = "${sensorNamePrefix(sensorType)}_sensor_${sensorType}_ch_$channel"
    }

    private data class CsvRow(
        val packetDeviceTimeMillis: Long,
        val sampleTimerMillis: Long,
        val values: Map<CsvColumnKey, Float>,
    )

    private companion object {
        const val BUFFER_SIZE_BYTES = 65_536
        const val COLUMN_ESTIMATED_UTC = "estimated_utc"
        const val COLUMN_HOST_MONOTONIC_NS = "host_monotonic_ns"
        const val COLUMN_DEVICE_TIMER_MILLIS = "device_timer_millis"
        const val COLUMN_SAMPLE_TIMER_MILLIS = "sample_timer_millis"
        const val CSV_SEPARATOR = ','
        fun sensorNamePrefix(sensorType: Int): String {
            return when (sensorType) {
                1 -> "t"
                2 -> "axl"
                3 -> "gir"
                4 -> "mic"
                else -> "unknown"
            }
        }
    }
}
