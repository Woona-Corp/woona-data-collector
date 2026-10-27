package com.example.myapplication

import android.content.Context
import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.example.myapplication.ble.BleDevice
import com.example.myapplication.ble.BleSessionController
import com.example.myapplication.ble.BleSessionListener
import com.example.myapplication.ble.BleSessionState
import com.example.myapplication.ble.BleTransportProfile
import com.example.myapplication.feature.device.DeviceUiStateHolder
import com.example.myapplication.feature.device.PacketCaptureController
import com.example.myapplication.feature.device.PacketSubmitResult
import com.example.myapplication.storage.FileShareIntentFactory
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID
import java.util.zip.ZipFile

@RunWith(AndroidJUnit4::class)
class DeviceFeatureSmokeTest {
    @Test
    fun postedPreviewEventsCannotChangeANewerConnection() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val source = File(context.cacheDir, "preview-events-${UUID.randomUUID()}.bin").apply { writeBytes(validPacket()) }
        lateinit var ble: FakeBleSessionController
        val controller = createDeviceFeatureController(context, context.filesDir, "${context.packageName}.provider",
            UUID.randomUUID(), UUID.randomUUID(), UUID.randomUUID(),
            packetCaptureControllerFactory = { _, _ -> FakePacketCaptureController(source) },
            bleSessionControllerFactory = { listener -> FakeBleSessionController(listener).also { ble = it } },
            fileShareIntentFactory = FakeFileShareIntentFactory())
        try {
            instrumentation.runOnMainSync {
                controller.onV2PreviewConnectRequested("OLD")
                Thread {
                    ble.listener.onV2LiveStarted(1, 3)
                    ble.listener.onStateChanged(BleSessionState.CONNECTED)
                    ble.listener.onError("Old connection failed", null)
                }.apply { start(); join(2_000); assertTrue(!isAlive) }
                controller.onDisconnectRequested()
                controller.onV2PreviewConnectRequested("NEW")
            }
            instrumentation.waitForIdleSync()
            assertEquals(com.example.myapplication.feature.device.V2PreviewStage.CONNECTING, controller.uiState.v2PreviewStage)
            org.junit.Assert.assertFalse(controller.uiState.v2LiveRunning)
            org.junit.Assert.assertFalse(controller.uiState.isConnected)
            org.junit.Assert.assertNull(controller.uiState.errorMessage)
        } finally { controller.close(); source.delete() }
    }

    @Test
    fun v2PreviewDoesNotCreateSessionOrChangePreviousFilesAndCannotReplaceActiveCapture() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.cacheDir, "preview-isolation-${UUID.randomUUID()}").apply { mkdirs() }
        val database = com.example.myapplication.data.WoonaDatabase(context, root)
        val packet = File(root, "previous-source.bin").apply { writeBytes(validPacket()) }
        val capture = FakePacketCaptureController(packet)
        val listener = object : BleSessionListener {
            override fun onDeviceFound(device: BleDevice) = Unit
            override fun onPacketReceived(packetFragment: ByteArray) = Unit
            override fun onDiagnosticMessage(message: String) = Unit
            override fun onCaptureReady() = Unit
            override fun onStateChanged(state: BleSessionState) = Unit
            override fun onError(message: String, throwable: Throwable?) = Unit
        }
        val ble = FakeBleSessionController(listener)
        val controller = com.example.myapplication.feature.device.DeviceFeatureController(
            ble, capture, FakeFileShareIntentFactory(), woonaDatabase = database)
        try {
            val profile = database.saveProfile(com.example.myapplication.data.DogQuestionnaire(
                schemaVersion = 2, animalId = "preview-test", numberOrName = "Synthetic preview animal"))
            val old = database.beginRecording(profile.id, com.example.myapplication.data.RecordingSource.REPLAY, null)
            database.finishRecording(old.id, com.example.myapplication.data.RecordingStatus.COMPLETED)
            val previous = database.recording(old.id)
            val bytes = packet.readBytes()
            controller.onV2PreviewConnectRequested("PREVIEW")
            controller.onCaptureReady() // No writer reset on the diagnostic route.
            controller.onTransportDiagnostic("Preview event")
            controller.onDisconnectRequested()
            assertEquals(1, database.recentRecordings(profile.id).size)
            assertEquals(previous, database.recording(old.id))
            assertArrayEquals(bytes, packet.readBytes())
            org.junit.Assert.assertFalse(capture.resetCalled)
            assertTrue(capture.recordedDiagnostics.isEmpty())
            val active = database.beginRecording(profile.id, com.example.myapplication.data.RecordingSource.LIVE, null)
            controller.beginRecordingSession(active)
            controller.onV2PreviewConnectRequested("MUST-NOT-CONNECT")
            assertEquals("PREVIEW", ble.connectedAddress)
            org.junit.Assert.assertFalse(controller.isV2PreviewConnection())
            assertTrue(controller.isCaptureActive())
            val oldCaptureGeneration = controller.captureIdentityGeneration()
            controller.onCaptureServiceFailure("capture_foreground_start_denied", "Synthetic OS refusal", SecurityException("denied"))
            assertEquals(com.example.myapplication.data.RecordingStatus.FAILED, database.recording(active.id)?.status)
            assertEquals("capture_foreground_start_denied", database.recording(active.id)?.captureErrorCode)
            assertArrayEquals(bytes, packet.readBytes())
            val next = database.beginRecording(profile.id, com.example.myapplication.data.RecordingSource.LIVE, null)
            controller.beginRecordingSession(next)
            controller.onCaptureServiceFailure("capture_foreground_start_denied", "Late error from previous capture", SecurityException("old"), oldCaptureGeneration)
            assertTrue(controller.isCaptureActive())
            assertEquals(com.example.myapplication.data.RecordingStatus.PREPARING, database.recording(next.id)?.status)
            org.junit.Assert.assertNull(database.recording(next.id)?.captureErrorCode)
        } finally { controller.close(); database.close(); root.deleteRecursively() }
    }

    @Test
    fun sessionZipRefusesPreparingAndOngoingCaptureWithoutStoppingVideoOrChangingRecording() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val root = File(context.cacheDir, "export-guard-${UUID.randomUUID()}").apply { mkdirs() }
        val database = com.example.myapplication.data.WoonaDatabase(context, root)
        val packet = File(root, "sensor-source.bin").apply { writeBytes(validPacket()) }
        val capture = FakePacketCaptureController(packet)
        val state = DeviceUiStateHolder()
        val listener = object : BleSessionListener {
            override fun onDeviceFound(device: BleDevice) = Unit
            override fun onPacketReceived(packetFragment: ByteArray) = Unit
            override fun onDiagnosticMessage(message: String) = Unit
            override fun onCaptureReady() = Unit
            override fun onStateChanged(state: BleSessionState) = Unit
            override fun onError(message: String, throwable: Throwable?) = Unit
        }
        val controller = com.example.myapplication.feature.device.DeviceFeatureController(
            FakeBleSessionController(listener), capture, FakeFileShareIntentFactory(), uiStateHolder = state, woonaDatabase = database)
        try {
            val profile = database.saveProfile(com.example.myapplication.data.DogQuestionnaire(schemaVersion = 2, animalId = "export-guard", numberOrName = "Synthetic guard animal"))
            val record = database.beginRecording(profile.id, com.example.myapplication.data.RecordingSource.LIVE,
                com.example.myapplication.data.SessionQuestionnaire(schemaVersion = 2, sessionLabel = "Guard", plannedActivities = listOf("Покой"), videoRequested = true))
            controller.beginRecordingSession(record)
            assertTrue(controller.isCaptureActive())
            val preparing = database.recording(record.id)
            org.junit.Assert.assertNull(controller.createSessionArchive(File(root, "out")))
            assertEquals(preparing, database.recording(record.id))
            state.videoReady()
            controller.startSynchronizedSession()
            state.videoStarted(0.0) // Synthetic camera callback; no camera API is used.
            capture.stopCaptureCalled = false
            val video = File(database.recordingDirectory(record.relativeDirectory), "video.mp4").apply { writeText("ongoing synthetic video") }
            val before = database.recording(record.id)
            val sync = File(video.parentFile, "sync.json").readBytes()
            val sourceBytes = packet.readBytes()
            assertTrue(controller.isCaptureActive())
            org.junit.Assert.assertFalse(controller.canShareAllFiles())
            assertTrue(controller.canSharePacketFile())
            org.junit.Assert.assertNull(controller.createSessionArchive(File(root, "out")))
            assertEquals(com.example.myapplication.feature.device.VideoCaptureState.RECORDING, controller.uiState.videoState)
            org.junit.Assert.assertFalse(capture.stopCaptureCalled)
            assertEquals(before, database.recording(record.id))
            assertArrayEquals(sync, File(video.parentFile, "sync.json").readBytes())
            assertArrayEquals(sourceBytes, packet.readBytes())
            assertEquals("ongoing synthetic video", video.readText())
            org.junit.Assert.assertFalse(File(root, "out").exists())
        } finally { controller.close(); database.close(); root.deleteRecursively() }
    }

    @Test
    fun initialTransportProfile_isRestoredIntoControllerAndBleSession() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        lateinit var bleSessionController: FakeBleSessionController

        val controller = createDeviceFeatureController(
            context = context,
            filesDir = context.filesDir,
            fileProviderAuthority = "${context.packageName}.provider",
            serviceUuid = UUID.randomUUID(),
            characteristicUuid = UUID.randomUUID(),
            descriptorUuid = UUID.randomUUID(),
            initialTransportProfile = BleTransportProfile.MAXIMUM_PERFORMANCE,
            packetCaptureControllerFactory = { _: DeviceUiStateHolder, _ ->
                FakePacketCaptureController(File(context.filesDir, "restore-profile.bin"))
            },
            bleSessionControllerFactory = { listener ->
                FakeBleSessionController(listener).also {
                    bleSessionController = it
                }
            },
            fileShareIntentFactory = FakeFileShareIntentFactory(),
        )

        assertEquals(BleTransportProfile.MAXIMUM_PERFORMANCE, controller.uiState.transportProfile)
        assertEquals(BleTransportProfile.MAXIMUM_PERFORMANCE, bleSessionController.currentTransportProfile())

        controller.close()
    }

    @Test
    fun fakeDrivenSmokePath_coversScanConnectCaptureAndShare() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val packetFile = File(context.filesDir, "smoke-share.bin").apply {
            writeBytes(validPacket())
        }
        val packetCaptureController = FakePacketCaptureController(packetFile)
        val fileShareIntentFactory = FakeFileShareIntentFactory()
        lateinit var bleSessionController: FakeBleSessionController

        val controller = createDeviceFeatureController(
            context = context,
            filesDir = context.filesDir,
            fileProviderAuthority = "${context.packageName}.provider",
            serviceUuid = UUID.randomUUID(),
            characteristicUuid = UUID.randomUUID(),
            descriptorUuid = UUID.randomUUID(),
            packetCaptureControllerFactory = { _: DeviceUiStateHolder, _ ->
                packetCaptureController
            },
            bleSessionControllerFactory = { listener ->
                FakeBleSessionController(listener).also {
                    bleSessionController = it
                }
            },
            fileShareIntentFactory = fileShareIntentFactory,
        )

        var permissionsRequested = false
        controller.onStartScanRequested(
            hasPermissions = { false },
            requestPermissions = { permissionsRequested = true },
        )

        assertTrue(permissionsRequested)

        controller.onPermissionsResult(allGranted = true)
        assertEquals(1, bleSessionController.startScanningCalls)

        bleSessionController.listener.onStateChanged(BleSessionState.SCANNING)
        bleSessionController.listener.onDeviceFound(
            BleDevice(
                name = "Demo",
                address = "AA:BB:CC:DD:EE:FF",
            ),
        )
        instrumentation.waitForIdleSync()

        assertTrue(controller.uiState.isScanning)
        assertEquals(1, controller.uiState.foundDevices.size)
        assertEquals("AA:BB:CC:DD:EE:FF", controller.uiState.foundDevices.single().address)

        controller.onConnectRequested("AA:BB:CC:DD:EE:FF")
        assertEquals(1, bleSessionController.stopScanningCalls)
        assertEquals("AA:BB:CC:DD:EE:FF", bleSessionController.connectedAddress)
        assertTrue(packetCaptureController.stopCaptureCalled)

        bleSessionController.listener.onDiagnosticMessage("BLE MTU changed: mtu=247 status=0")
        bleSessionController.listener.onStateChanged(BleSessionState.CONNECTED)
        bleSessionController.listener.onCaptureReady()
        bleSessionController.listener.onPacketReceived(byteArrayOf(0x10, 0x20, 0x30))
        instrumentation.waitForIdleSync()

        assertTrue(controller.uiState.isConnected)
        assertTrue(packetCaptureController.resetCalled)
        assertEquals(1, packetCaptureController.recordedDiagnostics.size)
        assertEquals(1, packetCaptureController.submittedFragments.size)
        assertArrayEquals(
            byteArrayOf(0x10, 0x20, 0x30),
            packetCaptureController.submittedFragments.single(),
        )

        val shareIntent = controller.createPacketShareIntent(context)
        val sharedFile = fileShareIntentFactory.sharedFile

        assertNotNull(shareIntent)
        assertTrue(packetCaptureController.flushCalled)
        assertNotNull(sharedFile)
        assertTrue(sharedFile!!.exists())
        assertTrue(sharedFile.absolutePath != packetFile.absolutePath)
        assertTrue(sharedFile.name.contains("_snapshot_packet"))
        assertArrayEquals(packetFile.readBytes(), sharedFile.readBytes())

        controller.close()
        assertTrue(bleSessionController.closeCalled)
        assertTrue(packetCaptureController.closeCalled)
    }

    @Test
    fun finishedSession_exportsRemainAvailableAfterDisconnect() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val packetFile = File(context.filesDir, "smoke-disconnect-packet.bin").apply {
            writeBytes(validPacket())
        }
        val rawFile = File(context.filesDir, "smoke-disconnect-raw.binlog").apply {
            writeText("raw-data")
        }
        val logFile = File(context.filesDir, "smoke-disconnect-log.log").apply {
            writeText("log-data")
        }
        val packetCaptureController = FakePacketCaptureController(
            packetFile = packetFile,
            rawFile = rawFile,
            logFile = logFile,
        )
        val fileShareIntentFactory = FakeFileShareIntentFactory()
        lateinit var bleSessionController: FakeBleSessionController

        val controller = createDeviceFeatureController(
            context = context,
            filesDir = context.filesDir,
            fileProviderAuthority = "${context.packageName}.provider",
            serviceUuid = UUID.randomUUID(),
            characteristicUuid = UUID.randomUUID(),
            descriptorUuid = UUID.randomUUID(),
            packetCaptureControllerFactory = { _: DeviceUiStateHolder, _ ->
                packetCaptureController
            },
            bleSessionControllerFactory = { listener ->
                FakeBleSessionController(listener).also {
                    bleSessionController = it
                }
            },
            fileShareIntentFactory = fileShareIntentFactory,
        )

        controller.onConnectRequested("AA:BB:CC:DD:EE:FF")
        bleSessionController.listener.onStateChanged(BleSessionState.CONNECTED)
        bleSessionController.listener.onCaptureReady()
        instrumentation.waitForIdleSync()

        controller.onDisconnectRequested()
        instrumentation.waitForIdleSync()

        assertTrue(controller.canSharePacketFile())
        assertTrue(controller.canShareCsvFile())
        assertTrue(controller.canShareRawFile())
        assertTrue(controller.canShareLogFile())
        assertTrue(controller.canShareAllFiles())

        assertNotNull(controller.createPacketShareIntent(context))
        assertTrue(requireNotNull(fileShareIntentFactory.sharedFile).name.contains("_snapshot_packet"))

        assertNotNull(controller.createRawShareIntent(context))
        assertTrue(requireNotNull(fileShareIntentFactory.sharedFile).name.contains("_snapshot_raw"))

        assertNotNull(controller.createLogShareIntent(context))
        assertTrue(requireNotNull(fileShareIntentFactory.sharedFile).name.contains("_snapshot_log"))

        assertNotNull(controller.createCsvShareIntent(context))
        val csvSnapshot = requireNotNull(fileShareIntentFactory.sharedFile)
        assertTrue(csvSnapshot.name.contains("_snapshot_csv"))
        assertTrue(
            csvSnapshot.readLines().first() ==
                "estimated_utc,host_monotonic_ns,device_timer_millis,sample_timer_millis,axl_sensor_2_ch_1",
        )

        assertNotNull(controller.createAllFilesShareIntent(context))
        val archiveFile = requireNotNull(fileShareIntentFactory.sharedFile)
        assertTrue(archiveFile.extension == "zip")
        ZipFile(archiveFile).use { archive ->
            assertEquals(
                listOf(
                    "manifest.json",
                    "smoke-disconnect-packet_snapshot_packet.bin",
                    "smoke-disconnect-packet_snapshot_csv.csv",
                    "smoke-disconnect-raw_snapshot_raw.binlog",
                    "smoke-disconnect-log_snapshot_log.log",
                ),
                archive.entries().asSequence().map { it.name }.toList(),
            )
        }

        controller.close()

        packetFile.delete()
        rawFile.delete()
        logFile.delete()
    }
}

private class FakeBleSessionController(
    val listener: BleSessionListener,
) : BleSessionController {
    var startScanningCalls = 0
    var stopScanningCalls = 0
    var connectedAddress: String? = null
    var closeCalled = false
    private var transportProfile = BleTransportProfile.COMPATIBILITY

    override fun currentState(): BleSessionState = BleSessionState.IDLE

    override fun currentTransportProfile(): BleTransportProfile = transportProfile

    override fun updateTransportProfile(profile: BleTransportProfile) {
        transportProfile = profile
    }

    override fun startScanning() {
        startScanningCalls++
    }

    override fun stopScanning() {
        stopScanningCalls++
    }

    override fun connect(address: String) {
        connectedAddress = address
    }

    override fun disconnect() = Unit

    override fun close() {
        closeCalled = true
    }
}

private class FakePacketCaptureController(
    private val packetFile: File,
    private val rawFile: File? = null,
    private val logFile: File? = null,
) : PacketCaptureController {
    val submittedFragments = mutableListOf<ByteArray>()
    var resetCalled = false
    var stopCaptureCalled = false
    var flushCalled = false
    var closeCalled = false
    val recordedDiagnostics = mutableListOf<String>()

    override fun submit(packetFragment: ByteArray): PacketSubmitResult {
        submittedFragments += packetFragment
        return PacketSubmitResult.ACCEPTED
    }

    override fun recordDiagnosticEvent(
        type: com.example.myapplication.feature.device.PacketDiagnosticType,
        message: String,
    ) {
        recordedDiagnostics += message
    }

    override fun stopCapture() {
        stopCaptureCalled = true
    }

    override fun updateSelection(sensorType: Int, channel: Int) = Unit

    override fun resetSession() {
        resetCalled = true
    }

    override fun flush() {
        flushCalled = true
    }

    override fun currentFile(): File = packetFile

    override fun currentPacketFile(): File = packetFile

    override fun currentRawFile(): File? = rawFile

    override fun currentLogFile(): File? = logFile

    override fun close() {
        closeCalled = true
    }
}

private class FakeFileShareIntentFactory : FileShareIntentFactory {
    var sharedFile: File? = null
    var sharedFiles: List<File>? = null

    override fun createChooserIntent(context: Context, file: File): Intent {
        sharedFile = file
        sharedFiles = listOf(file)
        return Intent("test-share")
    }

    override fun createChooserIntent(context: Context, files: List<File>): Intent {
        sharedFiles = files
        sharedFile = files.singleOrNull()
        return Intent("test-share")
    }
}

private fun validPacket(): ByteArray {
    return packet(
        counter = 1,
        timerMillis = 50,
        blocks = listOf(
            sensorBlock(sensorType = 2, channelSamples = listOf(listOf(10, 20))),
        ),
    )
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
