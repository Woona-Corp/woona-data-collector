package com.example.myapplication.feature.device

import android.content.Context
import android.content.Intent
import android.content.ContextWrapper
import com.example.myapplication.ble.BleTransportProfile
import com.example.myapplication.ble.BleSessionController
import com.example.myapplication.ble.BleSessionState
import com.example.myapplication.storage.BleSessionCsvExporter
import com.example.myapplication.storage.FileShareIntentFactory
import com.example.myapplication.storage.SessionArchiveExporter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.zip.ZipFile

class DeviceFeatureControllerTest {
    @Test
    fun previewConnectNeverStartsPersistentCaptureAndDisconnectsWhenBackgrounded() {
        val ble = FakeBleSessionController()
        val capture = FakePacketCaptureController()
        val state = DeviceUiStateHolder()
        val controller = DeviceFeatureController(ble, capture, FakeFileShareIntentFactory(), uiStateHolder = state)
        controller.onV2PreviewConnectRequested("AA:BB")
        assertEquals("AA:BB", ble.connectedAddress)
        assertEquals(1, ble.previewConnectCalls)
        assertTrue(controller.isV2PreviewConnection())
        assertFalse(controller.isCaptureActive())
        assertFalse(capture.resetCalled)
        assertFalse(capture.finishCaptureCalled)
        controller.onTransportDiagnostic("preview diagnostic must not be appended to an old file")
        assertTrue(capture.recordedDiagnostics.isEmpty())
        controller.startSynchronizedSession()
        assertFalse(capture.resetCalled)
        controller.onPause()
        assertEquals(1, ble.disconnectCalls)
        assertFalse(controller.isV2PreviewConnection())
        assertFalse(capture.finishCaptureCalled)
    }

    @Test
    fun operationFailureKeepsExceptionDetailsWithoutStoppingCapture() {
        val ble = FakeBleSessionController()
        val capture = FakePacketCaptureController()
        val controller = createController(bleSessionController = ble, packetCaptureController = capture)
        controller.showErrorOnMainThread("Download failed", java.io.IOException("read timed out"))

        assertEquals("Download failed: java.io.IOException: read timed out", controller.uiState.errorMessage)
        assertEquals(0, ble.disconnectCalls)
        assertFalse(capture.stopCaptureCalled)
    }

    @Test
    fun onPermissionsResult_withDeniedPermissionsShowsError() {
        val controller = createController()

        controller.onPermissionsResult(allGranted = false)

        assertEquals(DeviceFeatureController.PERMISSION_REQUIRED_MESSAGE, controller.uiState.errorMessage)
    }

    @Test
    fun onStartScanRequested_withGrantedPermissionsStartsScanningImmediately() {
        val ble = FakeBleSessionController()
        val controller = createController(bleSessionController = ble)
        var permissionsRequested = false

        controller.onStartScanRequested(
            hasPermissions = { true },
            requestPermissions = { permissionsRequested = true },
        )

        assertEquals(1, ble.startScanningCalls)
        assertTrue(!permissionsRequested)
    }

    @Test
    fun onStartScanRequested_withoutPermissionsRequestsThemInsteadOfStartingScan() {
        val ble = FakeBleSessionController()
        val controller = createController(bleSessionController = ble)
        var permissionsRequested = false

        controller.onStartScanRequested(
            hasPermissions = { false },
            requestPermissions = { permissionsRequested = true },
        )

        assertEquals(0, ble.startScanningCalls)
        assertTrue(permissionsRequested)
    }

    @Test
    fun onConnectRequested_stopsCurrentCaptureAndStartsConnection() {
        val ble = FakeBleSessionController()
        val packetCapture = FakePacketCaptureController()
        val controller = createController(
            bleSessionController = ble,
            packetCaptureController = packetCapture,
        )

        controller.onConnectRequested("AA:BB")

        assertTrue(packetCapture.stopCaptureCalled)
        assertTrue(!packetCapture.resetCalled)
        assertEquals("AA:BB", ble.connectedAddress)
        assertEquals(1, ble.stopScanningCalls)
    }

    @Test
    fun onPause_doesNotStopCaptureOrDisconnectBle() {
        val ble = FakeBleSessionController()
        val packetCapture = FakePacketCaptureController()
        val controller = createController(
            bleSessionController = ble,
            packetCaptureController = packetCapture,
        )

        controller.onPause()

        assertFalse(packetCapture.stopCaptureCalled)
        assertEquals(0, ble.disconnectCalls)
    }

    @Test
    fun onCaptureReady_resetsCaptureSessionAndFlushesBufferedTransportDiagnostics() {
        val packetCapture = FakePacketCaptureController()
        val controller = createController(packetCaptureController = packetCapture)

        controller.onConnectRequested("AA:BB")
        controller.onTransportDiagnostic("BLE MTU changed: mtu=247 status=0")
        controller.onTransportDiagnostic("BLE PHY updated: txPhy=2 rxPhy=2 status=0")
        controller.onCaptureReady()

        assertTrue(packetCapture.resetCalled)
        assertEquals(
            listOf(
                "BLE MTU changed: mtu=247 status=0",
                "BLE PHY updated: txPhy=2 rxPhy=2 status=0",
            ),
            packetCapture.recordedDiagnostics.map { it.message },
        )
    }

    @Test
    fun onTransportDiagnostic_recordsImmediatelyWhenSessionIsActive() {
        val packetCapture = FakePacketCaptureController()
        val controller = createController(packetCaptureController = packetCapture)

        controller.onTransportDiagnostic("BLE PHY updated: txPhy=2 rxPhy=2 status=0")

        assertEquals(1, packetCapture.recordedDiagnostics.size)
    }

    @Test
    fun onSessionError_flushesBufferedTransportDiagnosticsBeforeShowingError() {
        val packetCapture = FakePacketCaptureController()
        val controller = createController(packetCaptureController = packetCapture)

        controller.onConnectRequested("AA:BB")
        controller.onTransportDiagnostic("BLE MTU changed: mtu=247 status=0")
        controller.onTransportDiagnostic("BLE transport snapshot: profile=Maximum performance, mtu=247, phy=?, interval=n/a, latency=n/a, timeout=n/a")
        controller.onSessionError("Service discovery failed: 133")

        assertEquals(
            listOf(
                "BLE MTU changed: mtu=247 status=0",
                "BLE transport snapshot: profile=Maximum performance, mtu=247, phy=?, interval=n/a, latency=n/a, timeout=n/a",
            ),
            packetCapture.recordedDiagnostics.map { it.message },
        )
        assertEquals("Service discovery failed: 133", controller.uiState.errorMessage)
    }

    @Test
    fun onSensorSelected_updatesCaptureSelection() {
        val packetCapture = FakePacketCaptureController()
        val controller = createController(packetCaptureController = packetCapture)

        controller.onSensorSelected(4)

        assertEquals(4, controller.uiState.selectedSensorType)
        assertEquals(1, controller.uiState.selectedChannel)
        assertEquals(4, packetCapture.selectedSensorType)
        assertEquals(1, packetCapture.selectedChannel)
    }

    @Test
    fun onTransportProfileSelected_updatesUiAndBleSessionController() {
        val ble = FakeBleSessionController()
        val packetCapture = FakePacketCaptureController()
        val controller = createController(
            bleSessionController = ble,
            packetCaptureController = packetCapture,
        )

        controller.onTransportProfileSelected(BleTransportProfile.COMPATIBILITY)

        assertEquals(BleTransportProfile.COMPATIBILITY, controller.uiState.transportProfile)
        assertEquals(BleTransportProfile.COMPATIBILITY, ble.transportProfile)
        assertEquals(0, packetCapture.recordedDiagnostics.size)
    }

    @Test
    fun chartControls_updateUiViewportState() {
        val controller = createController()

        controller.onChartWindowSelected(ChartWindowPreset.FIVE_MINUTES)
        controller.onFollowLiveChanged(enabled = false)

        assertEquals(ChartWindowPreset.FIVE_MINUTES, controller.uiState.chart.windowPreset)
        assertTrue(!controller.uiState.chart.isFollowingLive)
    }

    @Test
    fun onTabSelected_updatesVisibleCaptureTabOnly() {
        val controller = createController()

        controller.onTabSelected(DeviceCaptureTab.CHART)

        assertEquals(DeviceCaptureTab.CHART, controller.uiState.selectedTab)
    }

    @Test
    fun chartZoomActions_updateViewportState() {
        val controller = createController()

        controller.onChartZoomChanged(scaleFactor = 0.5f)
        controller.onChartPanned(deltaFraction = 0.25f)
        controller.onChartZoomResetRequested()

        assertEquals(ChartWindowPreset.THIRTY_SECONDS, controller.uiState.chart.windowPreset)
    }

    @Test
    fun startReplay_resetsCaptureOnlyAfterReplayIsPrepared() {
        val ble = FakeBleSessionController()
        val packetCapture = FakePacketCaptureController()
        val replayController = FakePacketReplayController()
        val controller = createController(
            bleSessionController = ble,
            packetCaptureController = packetCapture,
            packetReplayController = replayController,
        )

        controller.startReplay(byteArrayOf(0x01, 0x02))

        assertTrue(replayController.started)
        assertFalse(replayController.stopped)
        assertFalse(packetCapture.resetCalled)
        assertEquals(0, ble.closeCalls)
        assertFalse(controller.uiState.isReplayRunning)

        controller.onReplayPreparing()

        assertTrue(controller.uiState.isReplayPreparing)
        assertFalse(packetCapture.resetCalled)
        assertEquals(0, ble.closeCalls)
        assertEquals(1, ble.stopScanningCalls)

        controller.onReplayStarted()

        assertTrue(packetCapture.resetCalled)
        assertEquals(1, ble.closeCalls)
        assertTrue(controller.uiState.showCaptureUi)
        assertFalse(controller.uiState.isReplayPreparing)
        assertTrue(controller.uiState.isReplayRunning)
    }

    @Test
    fun cancelReplayPreparation_stopsReplayWithoutResettingCapture() {
        val packetCapture = FakePacketCaptureController()
        val replayController = FakePacketReplayController()
        val controller = createController(
            packetCaptureController = packetCapture,
            packetReplayController = replayController,
        )
        controller.onReplayPreparing()

        controller.cancelReplayPreparation()
        controller.onReplayStopped()

        assertTrue(replayController.stopped)
        assertFalse(packetCapture.resetCalled)
        assertFalse(controller.uiState.isReplayPreparing)
    }

    @Test
    fun createPacketShareIntent_sharesPacketFile() {
        val packetFile = File("/tmp/share-packet.bin")
        packetFile.writeText("packet")
        val shareFactory = FakeFileShareIntentFactory()
        val controller = DeviceFeatureController(
            bleSessionController = FakeBleSessionController(),
            packetCaptureController = FakePacketCaptureController(
                currentFile = packetFile,
                currentPacketFile = packetFile,
            ),
            fileShareIntentFactory = shareFactory,
        )

        val intent = controller.createPacketShareIntent(ContextWrapper(null))

        assertNotNull(intent)
        assertNotNull(shareFactory.sharedFile)
        assertEquals("packet", requireNotNull(shareFactory.sharedFile).readText())

        packetFile.delete()
        shareFactory.sharedFile?.delete()
    }

    @Test
    fun createRawShareIntent_sharesRawFile() {
        val rawFile = File("/tmp/share-raw.binlog")
        rawFile.writeText("raw")
        val shareFactory = FakeFileShareIntentFactory()
        val controller = DeviceFeatureController(
            bleSessionController = FakeBleSessionController(),
            packetCaptureController = FakePacketCaptureController(
                currentRawFile = rawFile,
            ),
            fileShareIntentFactory = shareFactory,
        )

        val intent = controller.createRawShareIntent(ContextWrapper(null))

        assertNotNull(intent)
        assertNotNull(shareFactory.sharedFile)
        assertEquals("raw", requireNotNull(shareFactory.sharedFile).readText())

        rawFile.delete()
        shareFactory.sharedFile?.delete()
    }

    @Test
    fun createLogShareIntent_sharesLogFile() {
        val logFile = File("/tmp/share-log.log")
        logFile.writeText("log")
        val shareFactory = FakeFileShareIntentFactory()
        val controller = DeviceFeatureController(
            bleSessionController = FakeBleSessionController(),
            packetCaptureController = FakePacketCaptureController(
                currentLogFile = logFile,
            ),
            fileShareIntentFactory = shareFactory,
        )

        val intent = controller.createLogShareIntent(ContextWrapper(null))

        assertNotNull(intent)
        assertNotNull(shareFactory.sharedFile)
        assertEquals("log", requireNotNull(shareFactory.sharedFile).readText())

        logFile.delete()
        shareFactory.sharedFile?.delete()
    }

    @Test
    fun createCsvShareIntent_generatesChannelCsvFromPacketDump() {
        val packetFile = File("/tmp/share-csv.bin").apply {
            writeBytes(
                packet(
                    counter = 10,
                    timerMillis = 50,
                    blocks = listOf(
                        sensorBlock(sensorType = 2, channelSamples = listOf(listOf(10, 20), listOf(30, 40))),
                    ),
                ),
            )
        }
        val shareFactory = FakeFileShareIntentFactory()
        val controller = DeviceFeatureController(
            bleSessionController = FakeBleSessionController(),
            packetCaptureController = FakePacketCaptureController(
                currentFile = packetFile,
                currentPacketFile = packetFile,
            ),
            fileShareIntentFactory = shareFactory,
            sessionCsvExporter = testSessionCsvExporter(),
            wallClockMillisProvider = { 1_000L },
        )

        val intent = controller.createCsvShareIntent(ContextWrapper(null))

        assertNotNull(intent)
        assertNotNull(shareFactory.sharedFile)
        assertEquals(
            listOf(
                "estimated_utc,host_monotonic_ns,device_timer_millis,sample_timer_millis,axl_sensor_2_ch_1,axl_sensor_2_ch_2",
                "time-1000,,50,50,10,30",
                "time-1001,,50,51,20,40",
            ),
            requireNotNull(shareFactory.sharedFile).readLines(),
        )

        packetFile.delete()
        shareFactory.sharedFile?.delete()
    }

    @Test
    fun createCsvShareIntent_usesCaptureReadyTimeInsteadOfConnectTapTime() {
        val packetFile = File("/tmp/share-csv-capture-ready.bin").apply {
            writeBytes(
                packet(
                    counter = 10,
                    timerMillis = 50,
                    blocks = listOf(
                        sensorBlock(sensorType = 2, channelSamples = listOf(listOf(10, 20))),
                    ),
                ),
            )
        }
        var now = 1_000L
        val shareFactory = FakeFileShareIntentFactory()
        val controller = DeviceFeatureController(
            bleSessionController = FakeBleSessionController(),
            packetCaptureController = FakePacketCaptureController(
                currentFile = packetFile,
                currentPacketFile = packetFile,
            ),
            fileShareIntentFactory = shareFactory,
            sessionCsvExporter = testSessionCsvExporter(),
            wallClockMillisProvider = { now },
        )

        controller.onConnectRequested("AA:BB")
        now = 2_000L
        controller.onCaptureReady()
        val intent = controller.createCsvShareIntent(ContextWrapper(null))

        assertNotNull(intent)
        assertEquals(
            listOf(
                "estimated_utc,host_monotonic_ns,device_timer_millis,sample_timer_millis,axl_sensor_2_ch_1",
                "time-2000,,50,50,10",
                "time-2001,,50,51,20",
            ),
            requireNotNull(shareFactory.sharedFile).readLines(),
        )

        packetFile.delete()
        shareFactory.sharedFile?.delete()
    }

    @Test
    fun createCsvShareIntent_preservesSessionTimeBaseAfterDisconnect() {
        val packetFile = File("/tmp/share-csv-disconnect.bin").apply {
            writeBytes(
                packet(
                    counter = 10,
                    timerMillis = 50,
                    blocks = listOf(
                        sensorBlock(sensorType = 2, channelSamples = listOf(listOf(10, 20))),
                    ),
                ),
            )
        }
        var now = 1_000L
        val shareFactory = FakeFileShareIntentFactory()
        val controller = DeviceFeatureController(
            bleSessionController = FakeBleSessionController(),
            packetCaptureController = FakePacketCaptureController(
                currentFile = packetFile,
                currentPacketFile = packetFile,
            ),
            fileShareIntentFactory = shareFactory,
            sessionCsvExporter = testSessionCsvExporter(),
            wallClockMillisProvider = { now },
        )

        controller.onConnectRequested("AA:BB")
        now = 2_000L
        controller.onCaptureReady()
        controller.onDisconnectRequested()
        now = 9_000L
        val intent = controller.createCsvShareIntent(ContextWrapper(null))

        assertNotNull(intent)
        assertEquals(
            listOf(
                "estimated_utc,host_monotonic_ns,device_timer_millis,sample_timer_millis,axl_sensor_2_ch_1",
                "time-2000,,50,50,10",
                "time-2001,,50,51,20",
            ),
            requireNotNull(shareFactory.sharedFile).readLines(),
        )

        packetFile.delete()
        shareFactory.sharedFile?.delete()
    }

    @Test
    fun createAllFilesShareIntent_sharesAllAvailableSessionArtifacts() {
        val packetFile = File("/tmp/share-all-packet.bin").apply {
            writeBytes(
                packet(
                    counter = 10,
                    timerMillis = 50,
                    blocks = listOf(
                        sensorBlock(sensorType = 2, channelSamples = listOf(listOf(10, 20))),
                    ),
                ),
            )
        }
        val rawFile = File("/tmp/share-all-raw.binlog").apply { writeText("raw") }
        val logFile = File("/tmp/share-all-log.log").apply { writeText("log") }
        val shareFactory = FakeFileShareIntentFactory()
        val controller = DeviceFeatureController(
            bleSessionController = FakeBleSessionController(),
            packetCaptureController = FakePacketCaptureController(
                currentFile = packetFile,
                currentPacketFile = packetFile,
                currentRawFile = rawFile,
                currentLogFile = logFile,
            ),
            fileShareIntentFactory = shareFactory,
            sessionCsvExporter = testSessionCsvExporter(),
            sessionArchiveExporter = SessionArchiveExporter(
                archiveTimestampFormatter = { "test-session" },
            ),
            wallClockMillisProvider = { 1_000L },
        )

        val intent = controller.createAllFilesShareIntent(ContextWrapper(null))

        assertNotNull(intent)
        val archiveFile = requireNotNull(shareFactory.sharedFile)
        assertEquals("woona_test-session.zip", archiveFile.name)
        ZipFile(archiveFile).use { archive ->
            assertEquals(
                listOf(
                    "manifest.json",
                    "share-all-packet_snapshot_packet.bin",
                    "share-all-packet_snapshot_csv.csv",
                    "share-all-raw_snapshot_raw.binlog",
                    "share-all-log_snapshot_log.log",
                ),
                archive.entries().asSequence().map { it.name }.toList(),
            )
        }

        packetFile.delete()
        rawFile.delete()
        logFile.delete()
        archiveFile.delete()
        listOf(
            "share-all-packet_snapshot_packet.bin",
            "share-all-packet_snapshot_csv.csv",
            "share-all-raw_snapshot_raw.binlog",
            "share-all-log_snapshot_log.log",
        ).forEach { File("/tmp", it).delete() }
    }

    @Test
    fun sessionZipCannotStopAnOngoingVideoButSingleFileSnapshotsRemainAvailable() {
        val root = kotlin.io.path.createTempDirectory("woona-live-export").toFile()
        try {
            val packet = File(root, "packets.bin").apply { writeBytes(byteArrayOf(1, 2, 3)) }
            val state = DeviceUiStateHolder()
            val capture = FakePacketCaptureController(currentFile = packet)
            val ble = FakeBleSessionController()
            val controller = DeviceFeatureController(ble, capture, FakeFileShareIntentFactory(), uiStateHolder = state)
            for (phase in listOf(VideoCaptureState.STARTING, VideoCaptureState.RECORDING, VideoCaptureState.STOPPING)) {
                when (phase) {
                    VideoCaptureState.STARTING -> state.videoStarting()
                    VideoCaptureState.RECORDING -> state.videoStarted(0.0)
                    else -> state.videoStopping()
                }
                val original = packet.readBytes()
                assertFalse(controller.canShareAllFiles())
                assertTrue(controller.canSharePacketFile())
                org.junit.Assert.assertNull(controller.createSessionArchive(File(root, "out")))
                assertEquals(phase, controller.uiState.videoState)
                org.junit.Assert.assertArrayEquals(original, packet.readBytes())
                assertFalse(capture.stopCaptureCalled)
                assertFalse(capture.flushCalled)
                assertEquals(0, ble.disconnectCalls)
                assertFalse(File(root, "out").exists())
            }
        } finally { root.deleteRecursively() }
    }

    @Test
    fun createSessionArchive_packagesAllAvailableSessionArtifacts() {
        val packetFile = File("/tmp/archive-packet.bin").apply {
            writeBytes(
                packet(
                    counter = 10,
                    timerMillis = 50,
                    blocks = listOf(
                        sensorBlock(sensorType = 2, channelSamples = listOf(listOf(10, 20))),
                    ),
                ),
            )
        }
        val rawFile = File("/tmp/archive-raw.binlog").apply { writeText("raw") }
        val logFile = File("/tmp/archive-log.log").apply { writeText("log") }
        val archiveDirectory = File("/tmp/woona-archive-test").apply { mkdirs() }
        val controller = DeviceFeatureController(
            bleSessionController = FakeBleSessionController(),
            packetCaptureController = FakePacketCaptureController(
                currentFile = packetFile,
                currentPacketFile = packetFile,
                currentRawFile = rawFile,
                currentLogFile = logFile,
            ),
            fileShareIntentFactory = FakeFileShareIntentFactory(),
            sessionCsvExporter = testSessionCsvExporter(),
            sessionArchiveExporter = SessionArchiveExporter(
                archiveTimestampFormatter = { "test-session" },
            ),
            wallClockMillisProvider = { 1_000L },
        )

        val archiveFile = controller.createSessionArchive(archiveDirectory)

        assertNotNull(archiveFile)
        ZipFile(requireNotNull(archiveFile)).use { archive ->
            val entryNames = archive.entries().asSequence().map { it.name }.toList()
            assertEquals(
                listOf(
                    "manifest.json",
                    "archive-packet_snapshot_packet.bin",
                    "archive-packet_snapshot_csv.csv",
                    "archive-raw_snapshot_raw.binlog",
                    "archive-log_snapshot_log.log",
                ),
                entryNames,
            )
            assertTrue(
                archive.getInputStream(archive.getEntry("manifest.json"))
                    .bufferedReader()
                    .use { it.readText() }
                    .contains("\"sessionStartMillis\": null"),
            )
        }

        packetFile.delete()
        rawFile.delete()
        logFile.delete()
        archiveDirectory.listFiles().orEmpty().forEach(File::delete)
        archiveDirectory.delete()
    }

    @Test
    fun canShareFiles_remainAvailableAfterDisconnectForCompletedSession() {
        val packetFile = File("/tmp/share-disconnect-packet.bin").apply { writeText("packet") }
        val rawFile = File("/tmp/share-disconnect-raw.binlog").apply { writeText("raw") }
        val logFile = File("/tmp/share-disconnect-log.log").apply { writeText("log") }
        val controller = DeviceFeatureController(
            bleSessionController = FakeBleSessionController(),
            packetCaptureController = FakePacketCaptureController(
                currentFile = packetFile,
                currentPacketFile = packetFile,
                currentRawFile = rawFile,
                currentLogFile = logFile,
            ),
            fileShareIntentFactory = FakeFileShareIntentFactory(),
        )

        controller.onDisconnectRequested()

        assertTrue(controller.canSharePacketFile())
        assertTrue(controller.canShareCsvFile())
        assertTrue(controller.canShareRawFile())
        assertTrue(controller.canShareLogFile())
        assertTrue(controller.canShareAllFiles())

        packetFile.delete()
        rawFile.delete()
        logFile.delete()
    }

    @Test
    fun disconnectRequested_stopsCaptureWithoutFlushingOnCallingThread() {
        val ble = FakeBleSessionController()
        val capture = FakePacketCaptureController()
        val controller = createController(
            bleSessionController = ble,
            packetCaptureController = capture,
        )

        controller.onDisconnectRequested()

        assertTrue(capture.stopCaptureCalled)
        assertFalse(capture.flushCalled)
        assertEquals(1, ble.disconnectCalls)
    }

    @Test
    fun finishCaptureForExport_drainsCaptureWithoutResettingSession() {
        val capture = FakePacketCaptureController()
        val controller = createController(packetCaptureController = capture)

        assertTrue(controller.finishCaptureForExport())

        assertTrue(capture.finishCaptureCalled)
        assertEquals(2_000L, capture.finishCaptureTimeoutMillis)
        assertTrue(capture.flushCalled)
    }

    @Test
    fun shareIntents_useSingleFrozenSnapshotAcrossFiles() {
        val packetFile = File("/tmp/share-snapshot-packet.bin").apply { writeText("packet-v1") }
        val rawFile = File("/tmp/share-snapshot-raw.binlog").apply { writeText("raw-v1") }
        val logFile = File("/tmp/share-snapshot-log.log").apply { writeText("log-v1") }
        val shareFactory = FakeFileShareIntentFactory()
        val controller = DeviceFeatureController(
            bleSessionController = FakeBleSessionController(),
            packetCaptureController = FakePacketCaptureController(
                currentFile = packetFile,
                currentPacketFile = packetFile,
                currentRawFile = rawFile,
                currentLogFile = logFile,
            ),
            fileShareIntentFactory = shareFactory,
        )

        controller.createPacketShareIntent(ContextWrapper(null))
        val packetSnapshot = requireNotNull(shareFactory.sharedFile)
        assertEquals("packet-v1", packetSnapshot.readText())

        packetFile.writeText("packet-v2")
        rawFile.writeText("raw-v2")
        logFile.writeText("log-v2")

        controller.createRawShareIntent(ContextWrapper(null))
        val rawSnapshot = requireNotNull(shareFactory.sharedFile)
        assertEquals("raw-v1", rawSnapshot.readText())

        controller.createLogShareIntent(ContextWrapper(null))
        val logSnapshot = requireNotNull(shareFactory.sharedFile)
        assertEquals("log-v1", logSnapshot.readText())

        packetFile.delete()
        rawFile.delete()
        logFile.delete()
        packetSnapshot.delete()
        rawSnapshot.delete()
        logSnapshot.delete()
    }

    @Test
    fun disconnectRequested_deletesExistingSnapshotFiles() {
        val packetFile = File("/tmp/share-cleanup-packet.bin").apply { writeText("packet-v1") }
        val shareFactory = FakeFileShareIntentFactory()
        val controller = DeviceFeatureController(
            bleSessionController = FakeBleSessionController(),
            packetCaptureController = FakePacketCaptureController(
                currentFile = packetFile,
                currentPacketFile = packetFile,
            ),
            fileShareIntentFactory = shareFactory,
        )

        controller.createPacketShareIntent(ContextWrapper(null))
        val packetSnapshot = requireNotNull(shareFactory.sharedFile)
        assertTrue(packetSnapshot.exists())

        controller.onDisconnectRequested()

        assertTrue(!packetSnapshot.exists())

        packetFile.delete()
    }

    private fun createController(
        bleSessionController: FakeBleSessionController = FakeBleSessionController(),
        packetCaptureController: FakePacketCaptureController = FakePacketCaptureController(),
        packetReplayController: FakePacketReplayController? = null,
    ): DeviceFeatureController {
        return DeviceFeatureController(
            bleSessionController = bleSessionController,
            packetCaptureController = packetCaptureController,
            fileShareIntentFactory = FakeFileShareIntentFactory(),
            packetReplayController = packetReplayController,
        )
    }

    private fun testSessionCsvExporter(): BleSessionCsvExporter {
        return BleSessionCsvExporter(
            timestampFormatter = { millis -> "time-$millis" },
        )
    }
}

private fun packet(
    counter: Int,
    timerMillis: Int,
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
        this[6] = blocks.size.coerceAtLeast(1).toByte()
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

private class FakeBleSessionController : BleSessionController {
    var previewConnectCalls = 0
    var startScanningCalls = 0
    var stopScanningCalls = 0
    var disconnectCalls = 0
    var connectedAddress: String? = null
    var closeCalls = 0
    var transportProfile = BleTransportProfile.COMPATIBILITY

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

    override fun connectForV2Preview(address: String) {
        previewConnectCalls++
        connectedAddress = address
    }

    override fun disconnect() {
        disconnectCalls++
    }

    override fun close() {
        closeCalls++
    }
}

private class FakePacketCaptureController(
    private val submitResult: PacketSubmitResult = PacketSubmitResult.ACCEPTED,
    private val currentFile: File? = File("/tmp/non-existent-share.bin"),
    private val currentPacketFile: File? = currentFile,
    private val currentRawFile: File? = null,
    private val currentLogFile: File? = null,
) : PacketCaptureController {
    var resetCalled = false
    var stopCaptureCalled = false
    var selectedSensorType: Int? = null
    var selectedChannel: Int? = null
    var finishCaptureCalled = false
    var finishCaptureTimeoutMillis: Long? = null
    var finishCaptureResult = true
    var flushCalled = false
    var closeCalled = false
    val recordedDiagnostics = mutableListOf<PacketDiagnosticEvent>()

    override fun submit(packetFragment: ByteArray): PacketSubmitResult = submitResult

    override fun recordDiagnosticEvent(type: PacketDiagnosticType, message: String) {
        recordedDiagnostics += PacketDiagnosticEvent(
            id = recordedDiagnostics.size.toLong(),
            type = type,
            message = message,
        )
    }

    override fun stopCapture() {
        stopCaptureCalled = true
    }

    override fun finishCapture(timeoutMillis: Long): Boolean {
        finishCaptureCalled = true
        finishCaptureTimeoutMillis = timeoutMillis
        flush()
        return finishCaptureResult
    }

    override fun updateSelection(sensorType: Int, channel: Int) {
        selectedSensorType = sensorType
        selectedChannel = channel
    }

    override fun resetSession() {
        resetCalled = true
    }

    override fun flush() {
        flushCalled = true
    }

    override fun currentFile(): File? = currentFile

    override fun currentPacketFile(): File? = currentPacketFile

    override fun currentRawFile(): File? = currentRawFile

    override fun currentLogFile(): File? = currentLogFile

    override fun close() {
        closeCalled = true
    }
}

private class FakePacketReplayController : PacketReplayController {
    var started = false
    var stopped = false

    override fun startReplay(source: ReplayInputSource) {
        started = source.open(ReplayCancellationToken())?.use { inputStream ->
            inputStream.read() != -1
        } == true
    }

    override fun stop() {
        stopped = true
    }

    override fun close() = Unit
}

private class FakeFileShareIntentFactory : FileShareIntentFactory {
    var sharedFile: File? = null
    var sharedFiles: List<File>? = null

    override fun createChooserIntent(context: Context, file: File): Intent {
        sharedFile = file
        sharedFiles = listOf(file)
        return Intent("test")
    }

    override fun createChooserIntent(context: Context, files: List<File>): Intent {
        sharedFiles = files
        sharedFile = files.singleOrNull()
        return Intent("test")
    }
}
