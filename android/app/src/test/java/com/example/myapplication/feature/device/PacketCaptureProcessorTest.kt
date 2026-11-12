package com.example.myapplication.feature.device

import com.example.myapplication.storage.BlePacketFileStore
import com.example.myapplication.storage.BleRawFragmentFileStore
import com.example.myapplication.storage.BleDiagnosticLogFileStore
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class PacketCaptureProcessorTest {
    @Test
    fun finishCapture_freezesSessionDiagnosticsButPreservesLaterTransportEvents() {
        val directory = Files.createTempDirectory("packet-processor-final-diagnostics").toFile()
        val session = File(directory, "session")
        val processor = PacketCaptureProcessor(
            packetFileStore = BlePacketFileStore(directory),
            rawFragmentFileStore = BleRawFragmentFileStore(directory),
            diagnosticLogFileStore = BleDiagnosticLogFileStore(directory),
            onPacketProcessed = {},
            onError = { message, throwable -> throw AssertionError(message, throwable) },
        )
        try {
            processor.useSessionDirectory(session)
            processor.recordDiagnosticEvent(PacketDiagnosticType.INFO, "capture event")
            assertEquals(PacketSubmitResult.ACCEPTED, processor.submit(validPacket(counter = 10, timerMillis = 50)))
            assertTrue(processor.finishCapture(2_000))
            val log = requireNotNull(processor.currentLogFile())
            val frozen = log.readBytes()
            assertTrue(log.readText().contains("Accepted packet"))
            val declaredSha = java.security.MessageDigest.getInstance("SHA-256").digest(frozen)

            // Disconnect callbacks arrive after the terminal transaction/manifest.
            processor.recordDiagnosticEvent(PacketDiagnosticType.INFO, "BLE disconnected after capture")
            processor.flush()
            assertTrue(processor.finishCapture(2_000)) // Finalization retry is idempotent.
            assertEquals(log, processor.currentLogFile())
            assertArrayEquals(frozen, log.readBytes())
            assertArrayEquals(declaredSha, java.security.MessageDigest.getInstance("SHA-256").digest(log.readBytes()))
            assertTrue(directory.listFiles().orEmpty().filter { it.isFile && it.extension == "log" }
                .any { it.readText().contains("BLE disconnected after capture") })

            val nextSession = File(directory, "next-session")
            processor.useSessionDirectory(nextSession)
            processor.resetSession()
            processor.recordDiagnosticEvent(PacketDiagnosticType.INFO, "next capture event")
            assertTrue(processor.finishCapture(2_000))
            assertEquals(File(nextSession, "diagnostics.log"), processor.currentLogFile())
            assertTrue(requireNotNull(processor.currentLogFile()).readText().contains("next capture event"))
            assertArrayEquals(frozen, log.readBytes())
        } finally {
            processor.close()
            directory.deleteRecursively()
        }
    }

    @Test
    fun submit_writesOnlyValidatedPackets() {
        val directory = Files.createTempDirectory("packet-processor-valid").toFile()
        val updates = mutableListOf<PacketProcessingUpdate>()
        val latch = CountDownLatch(1)
        val processor = PacketCaptureProcessor(
            packetFileStore = BlePacketFileStore(directory = directory, timestampProvider = { 1L }),
            rawFragmentFileStore = BleRawFragmentFileStore(directory = directory, timestampProvider = { 11L }),
            diagnosticLogFileStore = BleDiagnosticLogFileStore(directory = directory, timestampProvider = { 111L }),
            onPacketProcessed = {
                updates += it
                latch.countDown()
            },
            onError = { message, throwable -> throw AssertionError(message, throwable) },
        )

        processor.submit(validPacket(counter = 10, timerMillis = 50))

        assertTrue(latch.await(1, TimeUnit.SECONDS))
        processor.close()

        val file = requireNotNull(processor.currentFile())
        assertArrayEquals(validPacket(counter = 10, timerMillis = 50), file.readBytes())
        assertEquals(0L, updates.single().packetsRejected)
        assertEquals(1L, updates.single().fragmentsReceived)
        assertEquals(validPacket(counter = 10, timerMillis = 50).size.toLong(), updates.single().rawBytesReceived)
        assertTrue(updates.single().chartSamplesByStream.isEmpty())
        assertEquals(1, updates.single().diagnosticEvents.size)
        assertTrue(updates.single().diagnosticEvents.single().message.contains("Accepted packet counter=10"))
        assertNotNull(directory.listFiles()?.firstOrNull { it.name.startsWith("ble_raw_") })
        val logFile = directory.listFiles()?.firstOrNull { it.name.startsWith("ble_log_") }
        assertNotNull(logFile)
        assertTrue(requireNotNull(logFile).readText().contains("Accepted packet counter=10"))
    }

    @Test
    fun submit_rejectsPacketsWithInvalidMeasurementCount() {
        val directory = Files.createTempDirectory("packet-processor-invalid").toFile()
        val updates = mutableListOf<PacketProcessingUpdate>()
        val latch = CountDownLatch(1)
        val processor = PacketCaptureProcessor(
            packetFileStore = BlePacketFileStore(directory = directory, timestampProvider = { 2L }),
            rawFragmentFileStore = BleRawFragmentFileStore(directory = directory, timestampProvider = { 22L }),
            diagnosticLogFileStore = BleDiagnosticLogFileStore(directory = directory, timestampProvider = { 222L }),
            onPacketProcessed = {
                updates += it
                latch.countDown()
            },
            onError = { message, throwable -> throw AssertionError(message, throwable) },
        )

        processor.submit(invalidPacket(counter = 10, timerMillis = 50))

        assertTrue(latch.await(1, TimeUnit.SECONDS))
        processor.close()

        assertNull(processor.currentFile())
        assertEquals(1L, updates.single().packetsRejected)
        assertEquals("Invalid measurement count", updates.single().lastPacketIssue)
        assertEquals(
            "Rejected packet: reason=Invalid measurement count, len=16, counter=10, timer=50",
            updates.single().diagnosticEvents.single().message,
        )
    }

    @Test
    fun submit_logsValidatorMetadataForRejectedSensorBlock() {
        val directory = Files.createTempDirectory("packet-processor-invalid-block").toFile()
        val updates = mutableListOf<PacketProcessingUpdate>()
        val latch = CountDownLatch(1)
        val processor = PacketCaptureProcessor(
            packetFileStore = BlePacketFileStore(directory = directory, timestampProvider = { 2L }),
            rawFragmentFileStore = BleRawFragmentFileStore(directory = directory, timestampProvider = { 22L }),
            diagnosticLogFileStore = BleDiagnosticLogFileStore(directory = directory, timestampProvider = { 222L }),
            onPacketProcessed = {
                updates += it
                latch.countDown()
            },
            onError = { message, throwable -> throw AssertionError(message, throwable) },
        )
        val invalid = packet(
            counter = 10,
            timerMillis = 50,
            measurementCount = 3,
            blocks = listOf(
                sensorBlock(sensorType = 2, channelSamples = listOf(listOf(10, 20))),
                ByteArray(4),
            ),
        )

        processor.submit(invalid)

        assertTrue(latch.await(1, TimeUnit.SECONDS))
        processor.close()

        assertEquals(1L, updates.single().packetsRejected)
        assertEquals("Invalid sensor block layout", updates.single().lastPacketIssue)
        assertEquals(
            "Rejected packet: reason=Invalid sensor block layout, len=30, counter=10, timer=50, " +
                "parsedBlockCount=1, consumedBytes=26, trailingBytes=4, failedBlockIndex=1",
            updates.single().diagnosticEvents.single().message,
        )
    }

    @Test
    fun recordDiagnosticEvent_persistsInfoEventWithoutChangingPacketStats() {
        val directory = Files.createTempDirectory("packet-processor-info").toFile()
        val updates = mutableListOf<PacketProcessingUpdate>()
        val latch = CountDownLatch(1)
        val processor = PacketCaptureProcessor(
            packetFileStore = BlePacketFileStore(directory = directory, timestampProvider = { 21L }),
            rawFragmentFileStore = BleRawFragmentFileStore(directory = directory, timestampProvider = { 221L }),
            diagnosticLogFileStore = BleDiagnosticLogFileStore(directory = directory, timestampProvider = { 2221L }),
            onPacketProcessed = {
                updates += it
                latch.countDown()
            },
            onError = { message, throwable -> throw AssertionError(message, throwable) },
        )

        processor.recordDiagnosticEvent(
            type = PacketDiagnosticType.INFO,
            message = "BLE MTU changed: mtu=247 status=0",
        )

        assertTrue(latch.await(1, TimeUnit.SECONDS))
        processor.close()

        val update = updates.single()
        assertEquals(0L, update.packetsReceived)
        assertEquals(0L, update.packetsRejected)
        assertEquals(PacketDiagnosticType.INFO, update.diagnosticEvents.single().type)
        assertTrue(update.diagnosticEvents.single().message.contains("BLE MTU changed"))
        val logFile = directory.listFiles()?.firstOrNull { it.name.startsWith("ble_log_") }
        assertNotNull(logFile)
        assertTrue(requireNotNull(logFile).readText().contains("INFO"))
        assertTrue(requireNotNull(logFile).readText().contains("BLE MTU changed: mtu=247 status=0"))
    }

    @Test
    fun submit_persistsResyncInfoWithoutSensorValuesOrPacketMetricChanges() {
        val directory = Files.createTempDirectory("packet-processor-resync-info").toFile()
        val updates = mutableListOf<PacketProcessingUpdate>()
        val latch = CountDownLatch(2)
        val processor = PacketCaptureProcessor(
            packetFileStore = BlePacketFileStore(directory = directory, timestampProvider = { 25L }),
            rawFragmentFileStore = BleRawFragmentFileStore(directory = directory, timestampProvider = { 225L }),
            diagnosticLogFileStore = BleDiagnosticLogFileStore(directory = directory, timestampProvider = { 2225L }),
            onPacketProcessed = {
                updates += it
                latch.countDown()
            },
            onError = { message, throwable -> throw AssertionError(message, throwable) },
        )
        val packet = validPacket(
            counter = 10,
            timerMillis = 50,
            blocks = listOf(sensorBlock(2, listOf(listOf(31_000, 32_000)))),
        )

        processor.submit(byteArrayOf(0x11, 0x22, 0x33) + packet)

        assertTrue(latch.await(1, TimeUnit.SECONDS))
        processor.close()

        val resyncUpdate = updates.first()
        assertEquals(0L, resyncUpdate.packetsReceived)
        assertEquals(0L, resyncUpdate.packetsLost)
        assertEquals(0L, resyncUpdate.packetsRejected)
        val event = resyncUpdate.diagnosticEvents.single()
        assertEquals(PacketDiagnosticType.INFO, event.type)
        assertEquals("Packet resync: reason=LEADING_GARBAGE, discardedBytes=3", event.message)
        assertTrue(!event.message.contains("31000"))
        assertTrue(!event.message.contains("32000"))
        assertEquals(1L, updates.last().packetsReceived)
        assertEquals(0L, updates.last().packetsLost)
        assertEquals(0L, updates.last().packetsRejected)
        val logFile = directory.listFiles()?.firstOrNull { it.name.startsWith("ble_log_") }
        val log = requireNotNull(logFile).readText()
        assertTrue(log.contains("INFO"))
        assertTrue(log.contains("Packet resync: reason=LEADING_GARBAGE, discardedBytes=3"))
    }

    @Test
    fun resetSession_startsFreshDiagnosticLog() {
        val directory = Files.createTempDirectory("packet-processor-reset-info").toFile()
        val updates = mutableListOf<PacketProcessingUpdate>()
        val latch = CountDownLatch(2)
        var diagnosticTimestamp = 2_224L
        val processor = PacketCaptureProcessor(
            packetFileStore = BlePacketFileStore(directory = directory, timestampProvider = { 24L }),
            rawFragmentFileStore = BleRawFragmentFileStore(directory = directory, timestampProvider = { 224L }),
            diagnosticLogFileStore = BleDiagnosticLogFileStore(
                directory = directory,
                timestampProvider = { diagnosticTimestamp++ },
            ),
            onPacketProcessed = {
                updates += it
                latch.countDown()
            },
            onError = { message, throwable -> throw AssertionError(message, throwable) },
        )

        processor.recordDiagnosticEvent(
            type = PacketDiagnosticType.INFO,
            message = "BLE MTU changed: mtu=247 status=0",
        )
        val firstLogFile = processor.currentLogFile()
        processor.resetSession()
        processor.recordDiagnosticEvent(
            type = PacketDiagnosticType.INFO,
            message = "BLE PHY updated: txPhy=2 rxPhy=2 status=0",
        )

        assertTrue(latch.await(1, TimeUnit.SECONDS))
        processor.close()

        assertNotNull(firstLogFile)
        assertEquals(2, updates.size)
        assertEquals(0L, updates.last().diagnosticEvents.single().id)
        val logFiles = directory.listFiles()?.filter { it.name.startsWith("ble_log_") }.orEmpty()
        assertEquals(2, logFiles.size)
        val latestLogFile = requireNotNull(processor.currentLogFile())
        assertTrue(latestLogFile != firstLogFile)
        assertTrue(requireNotNull(firstLogFile).readText().contains("BLE MTU changed: mtu=247 status=0"))
        assertTrue(!requireNotNull(firstLogFile).readText().contains("BLE PHY updated: txPhy=2 rxPhy=2 status=0"))
        assertTrue(latestLogFile.readText().contains("BLE PHY updated: txPhy=2 rxPhy=2 status=0"))
    }

    @Test
    fun submit_rejectsOverlappingPacketStartAtFragmentBoundary() {
        val directory = Files.createTempDirectory("packet-processor-overlap").toFile()
        val updates = mutableListOf<PacketProcessingUpdate>()
        val latch = CountDownLatch(2)
        val processor = PacketCaptureProcessor(
            packetFileStore = BlePacketFileStore(directory = directory, timestampProvider = { 23L }),
            rawFragmentFileStore = BleRawFragmentFileStore(directory = directory, timestampProvider = { 223L }),
            diagnosticLogFileStore = BleDiagnosticLogFileStore(directory = directory, timestampProvider = { 2223L }),
            onPacketProcessed = {
                updates += it
                latch.countDown()
            },
            onError = { message, throwable -> throw AssertionError(message, throwable) },
        )

        val firstPacket = validPacket(counter = 10, timerMillis = 50, blocks = listOf(sensorBlock(2, listOf(listOf(10, 20)))))
        val secondPacket = validPacket(counter = 11, timerMillis = 60, blocks = listOf(sensorBlock(2, listOf(listOf(30, 40)))))
        processor.submit(firstPacket.copyOfRange(0, 20))
        processor.submit(secondPacket)

        assertTrue(latch.await(1, TimeUnit.SECONDS))
        processor.close()

        assertEquals(1L, updates.first().packetsRejected)
        assertTrue(
            requireNotNull(updates.first().lastPacketIssue).startsWith(
                "New packet start marker found before previous packet completed",
            ),
        )
        assertTrue(
            updates.first().diagnosticEvents.single().message.contains(
                "reason=New packet start marker found before previous packet completed",
            ),
        )
        val acceptedUpdate = updates.last()
        assertEquals(1L, acceptedUpdate.packetsReceived)
        assertEquals(1L, acceptedUpdate.packetsRejected)
        assertTrue(acceptedUpdate.diagnosticEvents.last().message.contains("Accepted packet counter=11"))
        assertNotNull(processor.currentFile())
    }

    @Test
    fun submit_reportsGapBeforeAcceptedPacket() {
        val directory = Files.createTempDirectory("packet-processor-gap").toFile()
        val updates = mutableListOf<PacketProcessingUpdate>()
        val latch = CountDownLatch(2)
        val processor = PacketCaptureProcessor(
            packetFileStore = BlePacketFileStore(directory = directory, timestampProvider = { 3L }),
            rawFragmentFileStore = BleRawFragmentFileStore(directory = directory, timestampProvider = { 33L }),
            diagnosticLogFileStore = BleDiagnosticLogFileStore(directory = directory, timestampProvider = { 333L }),
            onPacketProcessed = {
                updates += it
                latch.countDown()
            },
            onError = { message, throwable -> throw AssertionError(message, throwable) },
        )

        processor.submit(validPacket(counter = 10, timerMillis = 50))
        processor.submit(validPacket(counter = 12, timerMillis = 60))

        assertTrue(latch.await(1, TimeUnit.SECONDS))
        processor.close()

        val secondUpdate = updates.last()
        assertEquals(1L, secondUpdate.packetsLost)
        assertEquals(2, secondUpdate.diagnosticEvents.size)
        assertTrue(secondUpdate.diagnosticEvents.first().message.contains("Gap detected"))
        assertTrue(secondUpdate.diagnosticEvents.last().message.contains("Accepted packet counter=12"))
        assertTrue(secondUpdate.chartSamplesByStream.isEmpty())
    }

    @Test
    fun submit_gapPacketStartsNewSegmentWithoutBackfillingMissingInterval() {
        val directory = Files.createTempDirectory("packet-processor-gap-chart").toFile()
        val updates = mutableListOf<PacketProcessingUpdate>()
        val latch = CountDownLatch(2)
        val processor = PacketCaptureProcessor(
            packetFileStore = BlePacketFileStore(directory = directory, timestampProvider = { 31L }),
            rawFragmentFileStore = BleRawFragmentFileStore(directory = directory, timestampProvider = { 331L }),
            diagnosticLogFileStore = BleDiagnosticLogFileStore(directory = directory, timestampProvider = { 3331L }),
            onPacketProcessed = {
                updates += it
                latch.countDown()
            },
            onError = { message, throwable -> throw AssertionError(message, throwable) },
        )

        processor.submit(
            validPacket(
                counter = 10,
                timerMillis = 50,
                blocks = listOf(
                    sensorBlock(sensorType = 2, channelSamples = listOf(listOf(10, 20))),
                ),
            ),
        )
        processor.submit(
            validPacket(
                counter = 12,
                timerMillis = 90,
                blocks = listOf(
                    sensorBlock(sensorType = 2, channelSamples = listOf(listOf(30, 40))),
                ),
            ),
        )

        assertTrue(latch.await(1, TimeUnit.SECONDS))
        processor.close()

        val chartPoints = updates.last().chartSamplesByStream.getValue(
            ChartStreamKey(sensorType = 2, channel = 1),
        )
        assertEquals(listOf(90L, 90L), chartPoints.map { it.timeMillis })
        assertTrue(chartPoints.first().startsNewSegment)
    }

    @Test
    fun submit_firstAcceptedPacketDoesNotInventSampleSpacing() {
        val directory = Files.createTempDirectory("packet-processor-first-chart").toFile()
        val updates = mutableListOf<PacketProcessingUpdate>()
        val latch = CountDownLatch(1)
        val processor = PacketCaptureProcessor(
            packetFileStore = BlePacketFileStore(directory = directory, timestampProvider = { 41L }),
            rawFragmentFileStore = BleRawFragmentFileStore(directory = directory, timestampProvider = { 441L }),
            diagnosticLogFileStore = BleDiagnosticLogFileStore(directory = directory, timestampProvider = { 4441L }),
            onPacketProcessed = {
                updates += it
                latch.countDown()
            },
            onError = { message, throwable -> throw AssertionError(message, throwable) },
        )

        processor.submit(
            validPacket(
                counter = 10,
                timerMillis = 50,
                blocks = listOf(
                    sensorBlock(sensorType = 2, channelSamples = listOf(listOf(10, 20))),
                ),
            ),
        )

        assertTrue(latch.await(1, TimeUnit.SECONDS))
        processor.close()

        val chartPoints = updates.single().chartSamplesByStream.getValue(
            ChartStreamKey(sensorType = 2, channel = 1),
        )
        assertEquals(listOf(50L, 50L), chartPoints.map { it.timeMillis })
    }

    @Test
    fun submit_emitsTimestampedSamplesForAllStreams() {
        val directory = Files.createTempDirectory("packet-processor-streams").toFile()
        val updates = mutableListOf<PacketProcessingUpdate>()
        val latch = CountDownLatch(2)
        val processor = PacketCaptureProcessor(
            packetFileStore = BlePacketFileStore(directory = directory, timestampProvider = { 4L }),
            rawFragmentFileStore = BleRawFragmentFileStore(directory = directory, timestampProvider = { 44L }),
            diagnosticLogFileStore = BleDiagnosticLogFileStore(directory = directory, timestampProvider = { 444L }),
            onPacketProcessed = {
                updates += it
                latch.countDown()
            },
            onError = { message, throwable -> throw AssertionError(message, throwable) },
        )

        processor.submit(
            validPacket(
                counter = 10,
                timerMillis = 50,
                blocks = listOf(
                    sensorBlock(sensorType = 2, channelSamples = listOf(listOf(10, 20), listOf(30, 40))),
                    sensorBlock(sensorType = 4, channelSamples = listOf(listOf(50, 60))),
                ),
            ),
        )
        processor.submit(
            validPacket(
                counter = 11,
                timerMillis = 70,
                blocks = listOf(
                    sensorBlock(sensorType = 2, channelSamples = listOf(listOf(11, 21), listOf(31, 41))),
                    sensorBlock(sensorType = 4, channelSamples = listOf(listOf(51, 61))),
                ),
            ),
        )

        assertTrue(latch.await(1, TimeUnit.SECONDS))
        processor.close()

        val secondUpdate = updates.last()
        assertEquals(setOf(
            ChartStreamKey(sensorType = 2, channel = 1),
            ChartStreamKey(sensorType = 2, channel = 2),
            ChartStreamKey(sensorType = 4, channel = 1),
        ), secondUpdate.chartSamplesByStream.keys)
        assertEquals(listOf(60L, 70L), secondUpdate.chartSamplesByStream.getValue(
            ChartStreamKey(sensorType = 2, channel = 1),
        ).map { it.timeMillis })
    }

    @Test
    fun submit_logsQueuePressureWhenBacklogCrossesThreshold() {
        val directory = Files.createTempDirectory("packet-processor-queue-pressure").toFile()
        val updates = mutableListOf<PacketProcessingUpdate>()
        val processor = PacketCaptureProcessor(
            packetFileStore = BlePacketFileStore(directory = directory, timestampProvider = { 5L }),
            rawFragmentFileStore = BleRawFragmentFileStore(directory = directory, timestampProvider = { 55L }),
            diagnosticLogFileStore = BleDiagnosticLogFileStore(directory = directory, timestampProvider = { 555L }),
            onPacketProcessed = { updates += it },
            onError = { message, throwable -> throw AssertionError(message, throwable) },
            maxPendingFragments = 1,
        )

        repeat(12) { counter ->
            processor.submit(validPacket(counter = counter + 1, timerMillis = 100 + counter))
        }
        processor.close()

        assertTrue(updates.any { update ->
            update.diagnosticEvents.any { it.message.contains("Capture queue pressure") }
        })
    }

    @Test
    fun submit_overflowIsNonBlockingAndReportedSeparatelyFromPersistedFragments() {
        val directory = Files.createTempDirectory("packet-processor-overflow").toFile()
        val firstUpdateEntered = CountDownLatch(1)
        val releaseFirstUpdate = CountDownLatch(1)
        val updates = mutableListOf<PacketProcessingUpdate>()
        val processor = PacketCaptureProcessor(
            packetFileStore = BlePacketFileStore(directory = directory, timestampProvider = { 51L }),
            rawFragmentFileStore = BleRawFragmentFileStore(directory = directory, timestampProvider = { 551L }),
            diagnosticLogFileStore = BleDiagnosticLogFileStore(directory = directory, timestampProvider = { 5551L }),
            onPacketProcessed = {
                synchronized(updates) { updates += it }
                firstUpdateEntered.countDown()
                releaseFirstUpdate.await(2, TimeUnit.SECONDS)
            },
            onError = { message, throwable -> throw AssertionError(message, throwable) },
            maxPendingFragments = 1,
        )

        try {
            assertEquals(PacketSubmitResult.ACCEPTED, processor.submit(validPacket(counter = 1, timerMillis = 10)))
            assertTrue(firstUpdateEntered.await(1, TimeUnit.SECONDS))
            assertEquals(PacketSubmitResult.ACCEPTED, processor.submit(validPacket(counter = 2, timerMillis = 20)))
            assertEquals(PacketSubmitResult.OVERFLOW, processor.submit(validPacket(counter = 3, timerMillis = 30)))
            assertEquals(1L, processor.droppedFragments())
            releaseFirstUpdate.countDown()
            assertTrue(processor.finishCapture(2_000))
            assertEquals(1L, processor.droppedFragments())
            processor.useSessionDirectory(File(directory, "next").apply { mkdirs() })
            assertEquals("Overflow from the preceding capture must not taint the next", 0L, processor.droppedFragments())
        } finally {
            releaseFirstUpdate.countDown()
            processor.close()
        }

        val snapshot = synchronized(updates) { updates.toList() }
        assertTrue(snapshot.any { it.fragmentsDropped > 0L })
        assertTrue(snapshot.any { it.diagnosticEvents.any { event -> event.message.contains("dropped=") } })
        assertTrue(snapshot.any { it.fragmentsPersisted >= 1L })
    }

    @Test
    fun submit_logsPeriodicCaptureSummary() {
        val directory = Files.createTempDirectory("packet-processor-summary").toFile()
        val updates = mutableListOf<PacketProcessingUpdate>()
        var now = 1_000L
        val latch = CountDownLatch(3)
        val processor = PacketCaptureProcessor(
            packetFileStore = BlePacketFileStore(directory = directory, timestampProvider = { 6L }),
            rawFragmentFileStore = BleRawFragmentFileStore(directory = directory, timestampProvider = { 66L }),
            diagnosticLogFileStore = BleDiagnosticLogFileStore(directory = directory, timestampProvider = { 666L }),
            onPacketProcessed = {
                updates += it
                latch.countDown()
            },
            onError = { message, throwable -> throw AssertionError(message, throwable) },
            wallClockMillisProvider = { now },
            summaryIntervalMillis = 1_000L,
        )

        processor.submit(validPacket(counter = 10, timerMillis = 50))
        now = 2_500L
        processor.submit(validPacket(counter = 11, timerMillis = 60))

        assertTrue(latch.await(1, TimeUnit.SECONDS))
        processor.close()

        assertTrue(updates.any { update ->
            update.diagnosticEvents.any { it.message.contains("Capture summary:") }
        })
    }

    @Test
    fun finishCapture_drainsQueuedPacketsAndRejectsNewFragments() {
        val directory = Files.createTempDirectory("packet-processor-finish").toFile()
        val firstPacket = validPacket(counter = 10, timerMillis = 50)
        val processor = PacketCaptureProcessor(
            packetFileStore = BlePacketFileStore(directory = directory, timestampProvider = { 7L }),
            rawFragmentFileStore = BleRawFragmentFileStore(directory = directory, timestampProvider = { 77L }),
            diagnosticLogFileStore = BleDiagnosticLogFileStore(directory = directory, timestampProvider = { 777L }),
            onPacketProcessed = {},
            onError = { message, throwable -> throw AssertionError(message, throwable) },
        )

        assertEquals(PacketSubmitResult.ACCEPTED, processor.submit(firstPacket))
        assertTrue(processor.finishCapture(timeoutMillis = 1_000L))
        assertEquals(
            PacketSubmitResult.REJECTED,
            processor.submit(validPacket(counter = 11, timerMillis = 60)),
        )
        processor.close()

        val file = requireNotNull(processor.currentPacketFile())
        assertArrayEquals(firstPacket, file.readBytes())
    }

    @Test
    fun stopCapture_preservesQueuedFragmentsDuringDrain() {
        val directory = Files.createTempDirectory("packet-stop-queued").toFile()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val first = validPacket(counter = 10, timerMillis = 50)
        val second = validPacket(counter = 11, timerMillis = 60)
        val processor = PacketCaptureProcessor(
            packetFileStore = BlePacketFileStore(directory),
            rawFragmentFileStore = BleRawFragmentFileStore(directory),
            diagnosticLogFileStore = BleDiagnosticLogFileStore(directory),
            onPacketProcessed = {},
            onAcceptedPacketTimestamp = { _, _, _ -> entered.countDown(); release.await(2, TimeUnit.SECONDS) },
            onError = { message, throwable -> throw AssertionError(message, throwable) },
        )
        try {
            assertEquals(PacketSubmitResult.ACCEPTED, processor.submit(first))
            assertTrue(entered.await(1, TimeUnit.SECONDS))
            assertEquals(PacketSubmitResult.ACCEPTED, processor.submit(second))
            processor.stopCapture()
            assertEquals(false, processor.finishCapture(20))
            release.countDown()
            assertTrue(processor.finishCapture(1_000))
            assertArrayEquals(first + second, requireNotNull(processor.currentPacketFile()).readBytes())
        } finally {
            release.countDown()
            processor.close()
        }
    }

    @Test
    fun finishCapture_doesNotDeadlockWithTimestampCallbackInFlight() {
        val directory = Files.createTempDirectory("packet-processor-stop-race").toFile()
        val callbackEntered = CountDownLatch(1)
        val releaseCallback = CountDownLatch(1)
        val processor = PacketCaptureProcessor(
            packetFileStore = BlePacketFileStore(directory = directory, timestampProvider = { 8L }),
            rawFragmentFileStore = BleRawFragmentFileStore(directory = directory, timestampProvider = { 88L }),
            diagnosticLogFileStore = BleDiagnosticLogFileStore(directory = directory, timestampProvider = { 888L }),
            onPacketProcessed = {},
            onAcceptedPacketTimestamp = { _, _, _ ->
                callbackEntered.countDown()
                releaseCallback.await(2, TimeUnit.SECONDS)
            },
            onError = { message, throwable -> throw AssertionError(message, throwable) },
        )
        val executor = Executors.newSingleThreadExecutor()
        try {
            processor.submit(validPacket(counter = 10, timerMillis = 50))
            assertTrue(callbackEntered.await(1, TimeUnit.SECONDS))
            val finish = executor.submit<Boolean> { processor.finishCapture(timeoutMillis = 50L) }
            assertEquals(false, finish.get(1, TimeUnit.SECONDS))
        } finally {
            releaseCallback.countDown()
            processor.close()
            executor.shutdownNow()
        }
    }

    @Test
    fun corruptHeaderIsQuarantinedWithoutPoisoningNormalPacketsAndRawIsPreserved() {
        val directory = Files.createTempDirectory("packet-poison-regression").toFile()
        val updates = mutableListOf<PacketProcessingUpdate>()
        val processor = PacketCaptureProcessor(
            packetFileStore = BlePacketFileStore(directory),
            rawFragmentFileStore = BleRawFragmentFileStore(directory),
            diagnosticLogFileStore = BleDiagnosticLogFileStore(directory),
            onPacketProcessed = updates::add,
            onError = { message, exception -> throw AssertionError(message, exception) },
        )
        val first = validPacket(counter = 644, timerMillis = 658674)
        val corrupt = validPacket(counter = 3_222_815_366L.toInt(), timerMillis = 974731800)
        val normal = validPacket(counter = 648, timerMillis = 662678)
        processor.submit(first)
        processor.submit(corrupt)
        processor.submit(normal)
        assertTrue(processor.finishCapture(2_000))
        processor.close()
        assertEquals(2L, updates.last().packetsReceived)
        assertEquals(3L, updates.last().packetsLost)
        assertEquals(1L, updates.last().packetsRejected)
        assertEquals(0L, updates.last().timerRegressionRejects)
        assertArrayEquals(first + normal, requireNotNull(processor.currentPacketFile()).readBytes())
        val raw = requireNotNull(processor.currentRawFile()).readBytes()
        assertTrue(raw.asList().windowed(corrupt.size).any { it == corrupt.asList() })
        assertTrue(updates.any { it.lastPacketIssue?.contains("quarantined") == true })
    }

    @Test
    fun rolloverAndConfirmedResetPreserveCaptureAndExposeNewClockSegment() {
        val cases = listOf(
            Triple(listOf(4_294_967_294L to 4_294_967_290L, 1L to 5L), 2L, "rollover"),
            Triple(listOf(100L to 1000L, 1L to 5L, 2L to 6L), 0L, "continuity unknown"),
            Triple(listOf(10L to 100L, 100010L to 200L, 100011L to 201L), 100000L, "confirmed"),
        )
        cases.forEach { (headers, expectedLost, issue) ->
            val directory = Files.createTempDirectory("packet-clock-transition").toFile()
            val updates = mutableListOf<PacketProcessingUpdate>()
            val processor = PacketCaptureProcessor(
                packetFileStore = BlePacketFileStore(directory),
                rawFragmentFileStore = BleRawFragmentFileStore(directory),
                diagnosticLogFileStore = BleDiagnosticLogFileStore(directory),
                onPacketProcessed = updates::add,
                onError = { message, exception -> throw AssertionError(message, exception) },
            )
            headers.forEach { (counter, timer) ->
                processor.submit(validPacket(counter.toInt(), timer.toInt(), listOf(sensorBlock(2, listOf(listOf(10, 20))))))
            }
            assertTrue(processor.finishCapture(2_000))
            processor.close()
            val last = updates.last()
            assertEquals(2L, last.packetsReceived)
            assertEquals(expectedLost, last.packetsLost)
            assertEquals(if (headers.size == 2) 0L else 1L, last.packetsRejected)
            assertTrue(requireNotNull(last.lastPacketIssue).contains(issue))
            assertTrue(last.chartSamplesByStream.values.flatten().first().startsNewSegment)
        }
    }

    @Test
    fun rawWriteFailureRetainsAdmittedQueueAndPreventsSuccessOrReset() {
        val directory = Files.createTempDirectory("packet-write-failure").toFile()
        val notDirectory = java.io.File(directory, "not-a-directory").apply { writeText("x") }
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val processor = PacketCaptureProcessor(
            packetFileStore = BlePacketFileStore(directory),
            rawFragmentFileStore = BleRawFragmentFileStore(notDirectory, timestampProvider = {
                entered.countDown()
                release.await(2, TimeUnit.SECONDS)
                1L
            }),
            diagnosticLogFileStore = BleDiagnosticLogFileStore(directory),
            onPacketProcessed = {},
            onError = { _, _ -> },
            maxPendingFragments = 2,
        )
        try {
            assertEquals(PacketRecoveryResult.NoFailure, processor.recoverPendingFragments(directory))
            assertEquals(PacketSubmitResult.ACCEPTED, processor.submit(byteArrayOf(1), 11, 111))
            assertTrue(entered.await(1, TimeUnit.SECONDS))
            assertEquals(PacketSubmitResult.ACCEPTED, processor.submit(byteArrayOf(2), 22, 222))
            assertEquals(PacketSubmitResult.ACCEPTED, processor.submit(byteArrayOf(3), 33, 333))
            release.countDown()
            try {
                processor.finishCapture(2_000)
                org.junit.Assert.fail("failure must be reported")
            } catch (_: IllegalStateException) { }
            try {
                processor.resetSession()
                org.junit.Assert.fail("failed session must not be reset")
            } catch (_: IllegalStateException) { }
            assertEquals(PacketSubmitResult.REJECTED, processor.submit(byteArrayOf(4)))
            // Inspect the bounded retained queue: neither admitted tail was discarded.
            val field = processor.javaClass.getDeclaredField("queue").apply { isAccessible = true }
            assertEquals(2, (field.get(processor) as java.util.Queue<*>).size)
            val failed = processor.javaClass.getDeclaredField("failedFragment").apply { isAccessible = true }
            assertTrue(failed.get(processor) != null)
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2)
            var result: PacketRecoveryResult
            do {
                result = processor.recoverPendingFragments(notDirectory)
                if (result == PacketRecoveryResult.Busy) Thread.yield()
            } while (result == PacketRecoveryResult.Busy && System.nanoTime() < deadline)
            assertEquals(PacketRecoveryResult.Failed, result)
            assertEquals(2, (field.get(processor) as java.util.Queue<*>).size)
            assertTrue(failed.get(processor) != null)
            assertEquals("x", notDirectory.readText())

            val recovered = processor.recoverPendingFragments(directory) as PacketRecoveryResult.Recovered
            assertEquals(directory.canonicalFile, requireNotNull(recovered.file.parentFile).canonicalFile)
            java.io.DataInputStream(recovered.file.inputStream()).use { input ->
                val magic = ByteArray(8).also(input::readFully)
                assertArrayEquals(byteArrayOf(87, 80, 82, 69, 67, 79, 86, 0), magic)
                assertEquals(1, input.readInt())
                assertEquals(3, input.readInt())
                listOf(Triple(11L, 111L, 1), Triple(22L, 222L, 2), Triple(33L, 333L, 3)).forEach { (wall, mono, byte) ->
                    assertEquals(wall, input.readLong())
                    assertEquals(mono, input.readLong())
                    assertEquals(1, input.readInt())
                    assertEquals(byte, input.readUnsignedByte())
                }
                assertEquals(-1, input.read())
            }
            assertEquals(0, (field.get(processor) as java.util.Queue<*>).size)
            assertNull(failed.get(processor))
            assertEquals(recovered, processor.recoverPendingFragments(directory))
            assertEquals("x", notDirectory.readText())
            try {
                processor.finishCapture(100)
                org.junit.Assert.fail("recovery must not mark the capture successful")
            } catch (_: IllegalStateException) { }
            try {
                processor.resetSession()
                org.junit.Assert.fail("recovery must not reopen a failed session")
            } catch (_: IllegalStateException) { }
        } finally {
            release.countDown()
            processor.close()
        }
    }

    @Test
    fun rawFlushFailureRecoversBoundedBatchAndQueuedFragmentsOnce() {
        val directory = Files.createTempDirectory("packet-flush-failure").toFile()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val raw = BleRawFragmentFileStore(directory)
        val processor = PacketCaptureProcessor(
            packetFileStore = BlePacketFileStore(directory),
            rawFragmentFileStore = raw,
            diagnosticLogFileStore = BleDiagnosticLogFileStore(directory),
            onPacketProcessed = {},
            onError = { _, _ -> },
            flushRaw = {
                entered.countDown()
                release.await(2, TimeUnit.SECONDS)
                throw java.io.IOException("injected raw flush failure")
            },
        )
        try {
            for (i in 1..64) {
                assertEquals(PacketSubmitResult.ACCEPTED, processor.submit(byteArrayOf(i.toByte()), i.toLong(), i * 10L))
            }
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            val batch = processor.javaClass.getDeclaredField("unflushedFragments").apply { isAccessible = true }
            assertEquals(64, (batch.get(processor) as List<*>).size)
            assertEquals(PacketSubmitResult.ACCEPTED, processor.submit(byteArrayOf(65), 65, 650))
            release.countDown()
            try {
                processor.finishCapture(2_000)
                org.junit.Assert.fail("flush failure must not succeed")
            } catch (_: IllegalStateException) { }
            processor.close()
            val recovery = processor.recoverPendingFragments(directory) as PacketRecoveryResult.Recovered
            java.io.DataInputStream(recovery.file.inputStream()).use { input ->
                input.skipBytes(8)
                assertEquals(1, input.readInt())
                assertEquals(65, input.readInt())
                for (i in 1..65) {
                    assertEquals(i.toLong(), input.readLong())
                    assertEquals(i * 10L, input.readLong())
                    assertEquals(1, input.readInt())
                    assertEquals(i, input.readUnsignedByte())
                }
                assertEquals(-1, input.read())
            }
            assertEquals(PacketSubmitResult.REJECTED, processor.submit(byteArrayOf(1)))
        } finally {
            release.countDown()
            processor.close()
        }
    }

    @Test
    fun recoveryWaitsForFailedInFlightFragmentAndWorksAfterClose() {
        val directory = Files.createTempDirectory("packet-recovery-inflight").toFile()
        val invalid = java.io.File(directory, "not-a-directory").apply { writeText("original") }
        val failed = CountDownLatch(1)
        val release = CountDownLatch(1)
        val processor = PacketCaptureProcessor(
            packetFileStore = BlePacketFileStore(directory),
            rawFragmentFileStore = BleRawFragmentFileStore(invalid),
            diagnosticLogFileStore = BleDiagnosticLogFileStore(directory),
            onPacketProcessed = {},
            onError = { _, _ -> failed.countDown(); release.await(2, TimeUnit.SECONDS) },
        )
        try {
            assertEquals(PacketSubmitResult.ACCEPTED, processor.submit(byteArrayOf(42), 10, 20))
            assertTrue(failed.await(2, TimeUnit.SECONDS))
            assertEquals(PacketRecoveryResult.Busy, processor.recoverPendingFragments(directory))
            release.countDown()
            processor.close()
            val recovery = processor.recoverPendingFragments(directory) as PacketRecoveryResult.Recovered
            java.io.DataInputStream(recovery.file.inputStream()).use { input ->
                input.skipBytes(8)
                assertEquals(1, input.readInt())
                assertEquals(1, input.readInt())
                assertEquals(10L, input.readLong())
                assertEquals(20L, input.readLong())
                assertEquals(1, input.readInt())
                assertEquals(42, input.readUnsignedByte())
            }
            assertEquals("original", invalid.readText())
        } finally {
            release.countDown()
            processor.close()
        }
    }

    @Test
    fun resetRejectsUndrainedCaptureWithoutDiscardingFragments() {
        val directory = Files.createTempDirectory("packet-reset-pending").toFile()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val processor = PacketCaptureProcessor(
            packetFileStore = BlePacketFileStore(directory),
            rawFragmentFileStore = BleRawFragmentFileStore(directory),
            diagnosticLogFileStore = BleDiagnosticLogFileStore(directory),
            onPacketProcessed = { entered.countDown(); release.await(2, TimeUnit.SECONDS) },
            onError = { _, _ -> },
        )
        try {
            processor.submit(validPacket(1, 1))
            assertTrue(entered.await(1, TimeUnit.SECONDS))
            processor.submit(validPacket(2, 2))
            try {
                processor.resetSession()
                org.junit.Assert.fail("reset must reject an in-flight fragment")
            } catch (_: IllegalStateException) { }
            release.countDown()
            assertTrue(processor.finishCapture(2_000))
            assertArrayEquals(validPacket(1, 1) + validPacket(2, 2), requireNotNull(processor.currentPacketFile()).readBytes())
        } finally {
            release.countDown()
            processor.close()
        }
    }

    private fun validPacket(
        counter: Int,
        timerMillis: Int,
        blocks: List<ByteArray> = emptyList(),
    ): ByteArray = packet(
        counter = counter,
        timerMillis = timerMillis,
        measurementCount = if (blocks.isEmpty()) 1 else blocks.size,
        blocks = if (blocks.isEmpty()) {
            listOf(sensorBlock(sensorType = 1, channelSamples = listOf(emptyList())))
        } else {
            blocks
        },
    )

    private fun invalidPacket(
        counter: Int,
        timerMillis: Int,
    ): ByteArray = packet(
        counter = counter,
        timerMillis = timerMillis,
        measurementCount = 0,
    )

    private fun packet(
        counter: Int,
        timerMillis: Int,
        measurementCount: Int,
        blocks: List<ByteArray> = emptyList(),
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
            this[6] = measurementCount.toByte()
            this[7] = (counter and 0xFF).toByte()
            this[8] = ((counter shr 8) and 0xFF).toByte()
            this[9] = ((counter shr 16) and 0xFF).toByte()
            this[10] = ((counter shr 24) and 0xFF).toByte()
            this[11] = (timerMillis and 0xFF).toByte()
            this[12] = ((timerMillis shr 8) and 0xFF).toByte()
            this[13] = ((timerMillis shr 16) and 0xFF).toByte()
            this[14] = ((timerMillis shr 24) and 0xFF).toByte()

            if (payload.isNotEmpty()) {
                System.arraycopy(payload, 0, this, 16, payload.size)
            }
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
}
