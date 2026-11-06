package com.example.myapplication.storage

import org.junit.Assert.assertEquals
import org.junit.Test
import java.nio.file.Files

class BleSessionCsvExporterTest {
    private val exporter = BleSessionCsvExporter(
        timestampFormatter = { millis -> "time-$millis" },
    )

    @Test
    fun timelineReader_distinguishesCleanEofFromEveryTruncatedRecord() {
        val directory = Files.createTempDirectory("timeline-eof").toFile()
        try {
            val file = directory.resolve("timeline.bin")
            file.writeBytes("BLETIME1".toByteArray())
            BlePacketTimelineReader(file).use { assertEquals(null, it.next()) }
            for (size in 1..43) {
                file.writeBytes("BLETIME1".toByteArray() + ByteArray(size))
                org.junit.Assert.assertThrows("partial bytes=$size", java.io.EOFException::class.java) {
                    BlePacketTimelineReader(file).use { it.next() }
                }
            }
        } finally { directory.deleteRecursively() }
    }

    @Test fun export_rejectsTimelineEndingAtWholeRowBoundary() = rejectTimeline(rows = 1)
    @Test fun export_rejectsHeaderOnlyTimeline() = rejectTimeline(rows = 0)
    @Test fun export_rejectsOneByteFinalRow() = rejectTimeline(rows = 1, tail = 1)
    @Test fun export_rejects43ByteFinalRow() = rejectTimeline(rows = 1, tail = 43)
    @Test fun export_rejectsExtraTimelineRow() = rejectTimeline(rows = 3)
    @Test fun export_rejectsExtraPartialTimelineRow() = rejectTimeline(rows = 2, tail = 1)
    @Test fun export_rejectsMissingSuppliedTimeline() = rejectTimeline(rows = -1)
    @Test fun export_rejectsMismatchedTimelineCounter() = rejectTimeline(rows = 2, counterOffset = 1)
    @Test fun export_rejectsMismatchedTimelinePacketLength() = rejectTimeline(rows = 2, byteOffset = 1)

    @Test fun export_rejectsMismatchedTimelineDeviceTimer() = rejectTimeline(rows = 2, timerOffset = 1)

    private fun rejectTimeline(
        rows: Int,
        tail: Int = 0,
        counterOffset: Int = 0,
        byteOffset: Int = 0,
        timerOffset: Int = 0,
    ) {
        val directory = Files.createTempDirectory("timeline-cardinality").toFile()
        try {
            val bytes = (0..1).map { index -> packet(index + 9, index + 50,
                listOf(sensorBlock(2, listOf(listOf(10))))) }
            val packets = directory.resolve("packets.bin").apply { writeBytes(bytes[0] + bytes[1]) }
            val timeline = directory.resolve("packet_timeline.bin")
            if (rows >= 0) {
                java.io.DataOutputStream(timeline.outputStream()).use { output ->
                    output.writeBytes("BLETIME1")
                    repeat(rows) { index ->
                        output.writeLong(index.toLong())
                        output.writeLong((index + 9 + counterOffset).toLong())
                        output.writeLong((index + 50 + timerOffset).toLong())
                        output.writeLong(2000)
                        output.writeLong(9000000000)
                        output.writeInt(bytes[0].size + byteOffset)
                    }
                    output.write(ByteArray(tail))
                }
            }
            org.junit.Assert.assertThrows(Exception::class.java) {
                exporter.export(packets, 1000, directory.resolve("channel.csv"), timeline)
            }
        } finally { directory.deleteRecursively() }
    }

    @Test
    fun export_duplicateBlocksAndEmptyPacketsKeepFallbackGolden() = duplicateAndEmptyGolden(false)

    @Test
    fun export_duplicateBlocksAndEmptyPacketsKeepTimelineGolden() = duplicateAndEmptyGolden(true)

    private fun duplicateAndEmptyGolden(withTimeline: Boolean) {
        val directory = Files.createTempDirectory("csv-duplicate-empty").toFile()
        try {
            val timers = listOf(500, 50, 800, 51)
            val blocks = listOf(
                listOf(sensorBlock(255, listOf(emptyList()))),
                listOf(
                    sensorBlock(2, listOf(listOf(10, 20), listOf(30, 40))),
                    sensorBlock(2, listOf(listOf(50))),
                ),
                listOf(sensorBlock(254, listOf(emptyList()))),
                listOf(sensorBlock(4, listOf(listOf(-1)))),
            )
            val packets = directory.resolve("packets.bin")
            val timeline = BlePacketTimelineFileStore(directory)
            packets.outputStream().use { output ->
                timers.forEachIndexed { index, timer ->
                    val bytes = packet(index, timer, blocks[index])
                    output.write(bytes)
                    timeline.append(index.toLong(), index.toLong(), timer.toLong(),
                        2000L + index * 100, 9_000_000_000L + index * 100_000_000L, bytes.size)
                }
            }
            timeline.close()
            val target = directory.resolve("out.csv")
            exporter.export(packets, 1000, target,
                directory.resolve("packet_timeline.bin").takeIf { withTimeline })
            val header = "estimated_utc,host_monotonic_ns,device_timer_millis,sample_timer_millis," +
                "axl_sensor_2_ch_1,axl_sensor_2_ch_2,mic_sensor_4_ch_1\n"
            val rows = if (withTimeline) {
                "time-2100,9100000000,50,50,10,30,\n" +
                    "time-2101,9101000000,50,51,20,40,\n" +
                    "time-2102,9102000000,50,52,50,,\n" +
                    "time-2302,9302000000,51,53,,,-1\n"
            } else {
                "time-1000,,50,50,10,30,\n" +
                    "time-1001,,50,51,20,40,\n" +
                    "time-1002,,50,52,50,,\n" +
                    "time-1003,,51,53,,,-1\n"
            }
            assertEquals(header + rows, target.readText())
        } finally { directory.deleteRecursively() }
    }

    @Test
    fun export_preservesAll256TypesAndLateChannel255() {
        val directory = Files.createTempDirectory("csv-all-types").toFile()
        try {
            val packets = directory.resolve("packets.bin")
            packets.outputStream().use { output ->
                for (type in 0..255) {
                    val channels = if (type == 255) 255 else 1
                    output.write(packet(type, 50 + type,
                        listOf(sensorBlock(type, List(channels) { listOf(type - it) }))))
                }
            }
            val target = directory.resolve("out.csv")
            exporter.export(packets, 1000, target)
            val columns = (0..255).flatMap { type ->
                (1..if (type == 255) 255 else 1).map { channel -> type to channel }
            }
            val expected = buildString {
                append("estimated_utc,host_monotonic_ns,device_timer_millis,sample_timer_millis")
                columns.forEach { (type, channel) ->
                    val prefix = when (type) { 1 -> "t"; 2 -> "axl"; 3 -> "gir"; 4 -> "mic"; else -> "unknown" }
                    append(",$prefix" + "_sensor_${type}_ch_$channel")
                }
                append('\n')
                for (type in 0..255) {
                    append("time-${1000 + type},,${50 + type},${50 + type}")
                    columns.forEach { (columnType, channel) ->
                        append(',')
                        if (columnType == type) append(type - channel + 1)
                    }
                    append('\n')
                }
            }
            assertEquals(expected, target.readText())
        } finally { directory.deleteRecursively() }
    }

    @Test
    fun export_emptyDumpWritesOnlyHeader() {
        val directory = Files.createTempDirectory("csv-empty").toFile()
        try {
            val packets = directory.resolve("packets.bin").apply { writeBytes(byteArrayOf()) }
            val target = directory.resolve("out.csv")
            exporter.export(packets, 1000, target)
            assertEquals("estimated_utc,host_monotonic_ns,device_timer_millis,sample_timer_millis\n", target.readText())
        } finally { directory.deleteRecursively() }
    }

    @Test
    fun export_propagatesWriterErrorsWithoutOverwritingParent() {
        val directory = Files.createTempDirectory("csv-write-error").toFile()
        try {
            val packets = directory.resolve("packets.bin").apply {
                writeBytes(packet(9, 50, listOf(sensorBlock(2, listOf(listOf(10))))))
            }
            val directoryTarget = directory.resolve("target-directory").apply { mkdirs() }
            val fileParent = directory.resolve("file-parent").apply { writeText("sentinel") }
            for (target in listOf(directoryTarget, fileParent.resolve("out.csv"))) {
                org.junit.Assert.assertThrows(java.io.IOException::class.java) {
                    exporter.export(packets, 1000, target)
                }
            }
            assertEquals("sentinel", fileParent.readText())
        } finally { directory.deleteRecursively() }
    }

    @Test
    fun export_writesTimeColumnAndOneColumnPerChannel() {
        val directory = Files.createTempDirectory("ble-session-csv").toFile()
        val packetFile = directory.resolve("capture.bin").apply {
            writeBytes(
                packet(
                    counter = 9,
                    timerMillis = 50,
                    blocks = listOf(
                        sensorBlock(
                            sensorType = 4,
                            channelSamples = listOf(
                                listOf(50, 60),
                            ),
                        ),
                    ),
                ) + packet(
                    counter = 10,
                    timerMillis = 60,
                    blocks = listOf(
                        sensorBlock(
                            sensorType = 2,
                            channelSamples = listOf(
                                listOf(10, 20),
                                listOf(30, 40),
                            ),
                        ),
                    ),
                ),
            )
        }
        val targetFile = directory.resolve("capture.csv")

        exporter.export(
            packetFile = packetFile,
            sessionStartMillis = 1_000L,
            targetFile = targetFile,
        )

        assertEquals(
            listOf(
                "estimated_utc,host_monotonic_ns,device_timer_millis,sample_timer_millis,axl_sensor_2_ch_1,axl_sensor_2_ch_2,mic_sensor_4_ch_1",
                "time-1000,,50,50,,,50",
                "time-1001,,50,51,,,60",
                "time-1010,,60,60,10,30,",
                "time-1011,,60,61,20,40,",
            ),
            targetFile.readLines(),
        )
    }

    @Test
    fun export_keepsSampleTimerMonotonicAcrossPackets() {
        val directory = Files.createTempDirectory("ble-session-csv-overlap").toFile()
        val packetFile = directory.resolve("capture-overlap.bin").apply {
            writeBytes(
                packet(
                    counter = 9,
                    timerMillis = 50,
                    blocks = listOf(
                        sensorBlock(
                            sensorType = 2,
                            channelSamples = listOf(
                                listOf(10, 20, 30, 40),
                            ),
                        ),
                    ),
                ) + packet(
                    counter = 10,
                    timerMillis = 52,
                    blocks = listOf(
                        sensorBlock(
                            sensorType = 2,
                            channelSamples = listOf(
                                listOf(50, 60),
                            ),
                        ),
                    ),
                ),
            )
        }
        val targetFile = directory.resolve("capture-overlap.csv")

        exporter.export(
            packetFile = packetFile,
            sessionStartMillis = 1_000L,
            targetFile = targetFile,
        )

        assertEquals(
            listOf(
                "estimated_utc,host_monotonic_ns,device_timer_millis,sample_timer_millis,axl_sensor_2_ch_1",
                "time-1000,,50,50,10",
                "time-1001,,50,51,20",
                "time-1002,,50,52,30",
                "time-1003,,50,53,40",
                "time-1004,,52,54,50",
                "time-1005,,52,55,60",
            ),
            targetFile.readLines(),
        )
    }

    @Test
    fun export_usesPersistedHostTimelineForUtcAndMonotonicColumns() {
        val directory = Files.createTempDirectory("ble-session-csv-timeline").toFile()
        val bytes = packet(
            counter = 9,
            timerMillis = 50,
            blocks = listOf(
                sensorBlock(sensorType = 2, channelSamples = listOf(listOf(10, 20))),
            ),
        )
        val packetFile = directory.resolve("packets.bin").apply { writeBytes(bytes) }
        val timelineStore = BlePacketTimelineFileStore(directory)
        timelineStore.append(
            sequence = 0,
            counter = 9,
            deviceTimerMillis = 50,
            hostWallClockMillis = 2_000,
            hostMonotonicNs = 9_000_000_000,
            packetBytes = bytes.size,
        )
        timelineStore.close()
        val target = directory.resolve("channel.csv")

        exporter.export(
            packetFile = packetFile,
            packetTimelineFile = directory.resolve("packet_timeline.bin"),
            sessionStartMillis = 1_000,
            targetFile = target,
        )

        assertEquals(
            listOf(
                "estimated_utc,host_monotonic_ns,device_timer_millis,sample_timer_millis,axl_sensor_2_ch_1",
                "time-2000,9000000000,50,50,10",
                "time-2001,9001000000,50,51,20",
            ),
            target.readLines(),
        )
    }
}

private fun packet(
    counter: Int,
    timerMillis: Int,
    blocks: List<ByteArray>,
): ByteArray {
    val payload = blocks.fold(ByteArray(0)) { acc, block -> acc + block }
    val length = 16 + payload.size
    return ByteArray(length).apply {
        this[0] = 0x33
        this[1] = 0x99.toByte()
        this[2] = 0xAA.toByte()
        this[3] = 0x55
        this[4] = (length and 0xFF).toByte()
        this[5] = ((length shr 8) and 0xFF).toByte()
        this[6] = blocks.size.toByte()
        this[7] = (counter and 0xFF).toByte()
        this[8] = ((counter shr 8) and 0xFF).toByte()
        this[9] = ((counter shr 16) and 0xFF).toByte()
        this[10] = ((counter shr 24) and 0xFF).toByte()
        this[11] = (timerMillis and 0xFF).toByte()
        this[12] = ((timerMillis shr 8) and 0xFF).toByte()
        this[13] = ((timerMillis shr 16) and 0xFF).toByte()
        this[14] = ((timerMillis shr 24) and 0xFF).toByte()

        System.arraycopy(payload, 0, this, 16, payload.size)
    }
}

private fun sensorBlock(
    sensorType: Int,
    channelSamples: List<List<Int>>,
): ByteArray {
    val channelCount = channelSamples.size
    val samplesPerChannel = channelSamples.firstOrNull()?.size ?: 0
    val payloadSize = channelCount * samplesPerChannel * 2

    return ByteArray(6 + payloadSize).apply {
        this[0] = sensorType.toByte()
        this[1] = channelCount.toByte()
        this[2] = (samplesPerChannel and 0xFF).toByte()
        this[3] = ((samplesPerChannel shr 8) and 0xFF).toByte()

        var offset = 6
        channelSamples.forEach { samples ->
            samples.forEach { sample ->
                this[offset] = (sample and 0xFF).toByte()
                this[offset + 1] = ((sample shr 8) and 0xFF).toByte()
                offset += 2
            }
        }
    }
}
