package com.example.myapplication.video

import android.Manifest
import android.graphics.Bitmap
import android.content.pm.PackageManager
import android.graphics.SurfaceTexture
import android.media.MediaMetadataRetriever
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Log
import android.view.PixelCopy
import android.view.Surface
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.ViewGroup
import androidx.activity.ComponentActivity
import androidx.core.content.ContextCompat
import androidx.test.ext.junit.rules.ActivityScenarioRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.example.myapplication.createDeviceFeatureController
import com.example.myapplication.ble.BleSessionController
import com.example.myapplication.ble.BleSessionListener
import com.example.myapplication.ble.BleSessionState
import com.example.myapplication.ble.BleTransportProfile
import com.example.myapplication.data.ArtifactType
import com.example.myapplication.data.DogQuestionnaire
import com.example.myapplication.data.RecordingSource
import com.example.myapplication.data.RecordingStatus
import com.example.myapplication.data.SessionQuestionnaire
import com.example.myapplication.data.WoonaDatabase
import com.example.myapplication.data.artifactFile
import com.example.myapplication.data.hashPendingArtifacts
import com.example.myapplication.data.recordingSyncRecord
import com.example.myapplication.feature.device.VideoCaptureState
import com.example.myapplication.sync.ServerApiClient
import com.example.myapplication.sync.ServerSettings
import java.io.File
import java.time.Instant
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.After
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AndroidVideoRecorderDeviceTest {
    @get:Rule
    val activityRule = ActivityScenarioRule(ComponentActivity::class.java)

    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private lateinit var texture: SurfaceTexture
    private lateinit var surface: Surface
    private lateinit var recorder: AndroidVideoRecorder
    private lateinit var output: File

    @Before
    fun setUp() {
        InstrumentationRegistry.getInstrumentation().uiAutomation.grantRuntimePermission(
            context.packageName,
            Manifest.permission.CAMERA,
        )
        assertTrue(
            "Grant CAMERA before running the physical camera test",
            ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) ==
                PackageManager.PERMISSION_GRANTED,
        )
        texture = SurfaceTexture(0).apply { setDefaultBufferSize(1280, 720) }
        surface = Surface(texture)
        recorder = AndroidVideoRecorder(context)
        output = File(context.cacheDir, "physical-camera-smoke.mp4").apply { delete() }
    }

    @After
    fun tearDown() {
        if (::recorder.isInitialized) recorder.close()
        if (::surface.isInitialized) surface.release()
        if (::texture.isInitialized) texture.release()
        if (::output.isInitialized) output.delete()
    }

    @Test
    fun previewStartStop_producesReadableMp4() {
        val visiblePreview = attachPreview()
        val started = CountDownLatch(1)
        val failure = AtomicReference<String?>()
        recorder.setPreviewSurface(visiblePreview.holder.surface)

        assertTrue(
            recorder.start(
                file = output,
                onStarted = { started.countDown() },
                onError = { message, throwable ->
                    failure.set("$message: ${throwable?.stackTraceToString().orEmpty()}")
                    started.countDown()
                },
            ),
        )
        assertTrue("Camera did not start: ${failure.get()}", started.await(15, TimeUnit.SECONDS))
        assertNull("Camera failed to start", failure.get())
        Thread.sleep(2_000)
        assertVisibleCameraFrame(visiblePreview)

        val stopInfo = recorder.stop(8_000)
        assertNotNull("MediaRecorder did not produce a readable video", stopInfo)
        assertTrue(output.isFile)
        assertTrue(output.length() > 0L)
        assertVideoMatchesPreviewAspectRatio(output)
    }

    @Test
    fun prepareFailureThenRetry_releasesCameraAndRecorder() {
        val visiblePreview = attachPreview()
        recorder.setPreviewSurface(visiblePreview.holder.surface)
        val failed = CountDownLatch(1)
        val unexpectedStart = AtomicReference<AndroidVideoStartInfo?>()
        recorder.start(File("/proc/woona-prepare-failure.mp4"),
            onStarted = { unexpectedStart.set(it); failed.countDown() },
            onError = { _, _ -> failed.countDown() })
        assertTrue("Expected an unwritable output failure", failed.await(15, TimeUnit.SECONDS))
        assertNull(unexpectedStart.get())
        assertTrue("Failed recorder must release its active state", !recorder.isActive())
        val started = CountDownLatch(1)
        val error = AtomicReference<String?>()
        assertTrue(recorder.start(output,
            onStarted = { started.countDown() },
            onError = { message, _ -> error.set(message); started.countDown() }))
        assertTrue(started.await(15, TimeUnit.SECONDS))
        assertNull(error.get())
        Thread.sleep(1_000)
        assertNotNull(recorder.stop(8_000))
        assertVideoMatchesPreviewAspectRatio(output)
    }

    @Test
    fun consecutiveCaptures_produceTwoReadableVideos() {
        previewStartStop_producesReadableMp4()
        output.delete()
        previewStartStop_producesReadableMp4()
    }

    @Test
    fun replacingPreviewSurface_whileRecording_restoresVisiblePreview() {
        val firstPreview = attachPreview()
        val started = CountDownLatch(1)
        val failure = AtomicReference<String?>()
        recorder.setPreviewSurface(firstPreview.holder.surface)
        assertTrue(
            recorder.start(
                file = output,
                onStarted = { started.countDown() },
                onError = { message, throwable ->
                    failure.set("$message: ${throwable?.stackTraceToString().orEmpty()}")
                    started.countDown()
                },
            ),
        )
        assertTrue("Camera did not start: ${failure.get()}", started.await(15, TimeUnit.SECONDS))
        assertNull("Camera failed to start", failure.get())

        recorder.setPreviewSurface(null)
        val replacementPreview = attachPreview()
        recorder.setPreviewSurface(replacementPreview.holder.surface)
        Thread.sleep(2_000)

        assertVisibleCameraFrame(replacementPreview)
        assertNotNull("Recording failed after replacing preview", recorder.stop(8_000))
        assertTrue(output.isFile && output.length() > 0L)
    }

    private fun attachPreview(): SurfaceView {
        val surfaceReady = CountDownLatch(1)
        val lastSurfaceEvent = AtomicReference("No surface callback")
        lateinit var preview: SurfaceView
        activityRule.scenario.onActivity { activity ->
            preview = SurfaceView(activity).apply {
                holder.addCallback(
                    object : SurfaceHolder.Callback {
                        override fun surfaceCreated(holder: SurfaceHolder) {
                            lastSurfaceEvent.set("created: ${holder.surfaceFrame}")
                            recorder.setPreviewSurface(holder.surface)
                        }
                        override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                            lastSurfaceEvent.set("changed: ${width}x$height, valid=${holder.surface.isValid}")
                            recorder.setPreviewSurface(holder.surface)
                            if (holder.surface.isValid && width > 0 && height > 0 &&
                                isAttachedToWindow && isShown && this@apply.width > 0 && this@apply.height > 0) {
                                surfaceReady.countDown()
                            }
                        }
                        override fun surfaceDestroyed(holder: SurfaceHolder) {
                            lastSurfaceEvent.set("destroyed: ${holder.surfaceFrame}")
                            recorder.setPreviewSurface(null)
                        }
                    },
                )
            }
            activity.setContentView(
                preview,
                ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT),
            )
        }
        val ready = surfaceReady.await(10, TimeUnit.SECONDS)
        assertTrue("Visible camera preview was not ready: ${lastSurfaceEvent.get()}", ready)
        return preview
    }

    private fun assertVisibleCameraFrame(preview: SurfaceView) {
        lateinit var bitmap: Bitmap
        val copied = CountDownLatch(1)
        val result = AtomicReference<Int>()
        InstrumentationRegistry.getInstrumentation().runOnMainSync {
            val state = "attached=${preview.isAttachedToWindow}, shown=${preview.isShown}, " +
                "size=${preview.width}x${preview.height}, valid=${preview.holder.surface.isValid}, " +
                "frame=${preview.holder.surfaceFrame}"
            assertTrue("Preview lost readiness before PixelCopy: $state",
                preview.isAttachedToWindow && preview.isShown && preview.width > 0 &&
                    preview.height > 0 && preview.holder.surface.isValid)
            bitmap = Bitmap.createBitmap(preview.width, preview.height, Bitmap.Config.ARGB_8888)
            PixelCopy.request(
                preview,
                bitmap,
                { copyResult ->
                    result.set(copyResult)
                    copied.countDown()
                },
                Handler(Looper.getMainLooper()),
            )
        }
        assertTrue("Timed out copying the visible camera preview", copied.await(10, TimeUnit.SECONDS))
        assertEquals(PixelCopy.SUCCESS, result.get())

        val colors = mutableSetOf<Int>()
        val xStep = (bitmap.width / 32).coerceAtLeast(1)
        val yStep = (bitmap.height / 32).coerceAtLeast(1)
        for (y in 0 until bitmap.height step yStep) {
            for (x in 0 until bitmap.width step xStep) colors += bitmap.getPixel(x, y) and 0x00ffffff
        }
        assertTrue("Camera preview stayed blank", colors.size > 8)

        val screenshot = File(requireNotNull(context.getExternalFilesDir(null)), "physical-camera-preview.png")
        screenshot.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        ParcelFileDescriptor.AutoCloseInputStream(
            InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(
                "cp ${screenshot.absolutePath} /sdcard/Download/physical-camera-preview.png",
            ),
        ).use { it.readBytes() }
    }

    private fun assertVideoMatchesPreviewAspectRatio(file: File) {
        val retriever = MediaMetadataRetriever()
        val (width, height) = try {
            retriever.setDataSource(file.absolutePath)
            requireNotNull(retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)).toInt() to
                requireNotNull(retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)).toInt()
        } finally {
            retriever.release()
        }
        assertEquals("Video does not match the 16:9 preview", width * 9, height * 16)
    }

    @Test
    fun mockBleSignalAndPhysicalCamera_completeSynchronizedRecording() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val recordingDurationMillis = InstrumentationRegistry.getArguments()
            .getString("recordingDurationMillis")
            ?.toLongOrNull()
            ?.coerceIn(2_000L, TimeUnit.MINUTES.toMillis(30))
            ?: 2_000L
        val root = File(context.cacheDir, "physical-capture-${System.nanoTime()}")
        val database = WoonaDatabase(context, root)
        lateinit var mockBle: MockBleSessionController
        val controller = createDeviceFeatureController(
            context = context,
            filesDir = root,
            fileProviderAuthority = "${context.packageName}.provider",
            serviceUuid = UUID.randomUUID(),
            characteristicUuid = UUID.randomUUID(),
            descriptorUuid = UUID.randomUUID(),
            bleSessionControllerFactory = { listener ->
                MockBleSessionController(listener).also { mockBle = it }
            },
            woonaDatabase = database,
        )
        try {
            val profile = database.saveProfile(completeDog())
            val recording = database.beginRecording(
                profileId = profile.id,
                source = RecordingSource.LIVE,
                questionnaire = completeSession(),
            )
            controller.beginRecordingSession(recording)
            controller.setVideoPreviewSurface(surface)
            controller.onConnectRequested(MOCK_ADDRESS)
            mockBle.listener.onStateChanged(BleSessionState.CONNECTED)
            mockBle.listener.onCaptureReady()
            instrumentation.waitForIdleSync()

            controller.startSynchronizedSession()
            mockBle.listener.onPacketReceived(
                validPacket(counter = 1, timerMillis = 50),
                System.currentTimeMillis(),
                android.os.SystemClock.elapsedRealtimeNanos(),
            )
            waitUntil("Camera did not enter RECORDING: ${controller.uiState}") {
                controller.uiState.videoState == VideoCaptureState.RECORDING
            }
            val deadline = android.os.SystemClock.elapsedRealtime() + recordingDurationMillis
            var counter = 2
            var timerMillis = 150
            while (android.os.SystemClock.elapsedRealtime() < deadline) {
                Thread.sleep(100)
                mockBle.listener.onPacketReceived(
                    validPacket(counter = counter++, timerMillis = timerMillis),
                    System.currentTimeMillis(),
                    android.os.SystemClock.elapsedRealtimeNanos(),
                )
                timerMillis += 100
            }

            Log.i(TEST_LOG_TAG, "capture complete; finalizing local artifacts")
            controller.onDisconnectRequested()
            Log.i(TEST_LOG_TAG, "local artifacts finalized; verifying server round-trip")
            val completed = requireNotNull(database.recording(recording.id))
            assertTrue(completed.status == RecordingStatus.COMPLETED)
            assertEquals(
                setOf(
                    ArtifactType.PACKET,
                    ArtifactType.PACKET_TIMELINE,
                    ArtifactType.RAW,
                    ArtifactType.DIAGNOSTIC,
                    ArtifactType.VIDEO,
                    ArtifactType.SYNC,
                ),
                completed.artifacts.mapTo(mutableSetOf()) { it.type },
            )
            assertTrue(completed.artifacts.filter { it.type != ArtifactType.DIAGNOSTIC }.all { it.sizeBytes > 0L })
            verifyServerRoundTripIfConfigured(database, recording.id, root)
        } finally {
            controller.close()
            database.close()
            root.deleteRecursively()
        }
    }

    @Test
    fun immediateCameraStop_persistsCameraFailure() {
        val root = File(context.cacheDir, "immediate-camera-stop-${System.nanoTime()}")
        val database = WoonaDatabase(context, root)
        lateinit var mockBle: MockBleSessionController
        val controller = createDeviceFeatureController(
            context = context,
            filesDir = root,
            fileProviderAuthority = "${context.packageName}.provider",
            serviceUuid = UUID.randomUUID(),
            characteristicUuid = UUID.randomUUID(),
            descriptorUuid = UUID.randomUUID(),
            bleSessionControllerFactory = { listener ->
                MockBleSessionController(listener).also { mockBle = it }
            },
            woonaDatabase = database,
        )
        try {
            val profile = database.saveProfile(completeDog())
            val recording = database.beginRecording(
                profileId = profile.id,
                source = RecordingSource.LIVE,
                questionnaire = completeSession(),
            )
            controller.beginRecordingSession(recording)
            controller.setVideoPreviewSurface(surface)
            controller.onConnectRequested(MOCK_ADDRESS)
            mockBle.listener.onStateChanged(BleSessionState.CONNECTED)
            mockBle.listener.onCaptureReady()
            InstrumentationRegistry.getInstrumentation().waitForIdleSync()

            controller.startSynchronizedSession()
            mockBle.listener.onPacketReceived(
                validPacket(counter = 1, timerMillis = 50),
                System.currentTimeMillis(),
                android.os.SystemClock.elapsedRealtimeNanos(),
            )
            val partialVideo = File(database.recordingDirectory(recording.relativeDirectory), "video.mp4")
            val videoExistedBeforeStop = partialVideo.exists()
            controller.onDisconnectRequested()

            val completed = requireNotNull(database.recordingSyncRecord(recording.id))
            assertEquals("camera_failed", completed.captureErrorCode)
            if (videoExistedBeforeStop) assertTrue(partialVideo.isFile)
            val videoArtifact = completed.artifacts.singleOrNull { it.type == ArtifactType.VIDEO.value }
            if (partialVideo.isFile) {
                assertNotNull(videoArtifact)
                val artifact = requireNotNull(videoArtifact)
                assertEquals("${recording.relativeDirectory}/video.mp4", artifact.relativePath)
                assertEquals(partialVideo.length(), artifact.sizeBytes)
                val hash = java.security.MessageDigest.getInstance("SHA-256").digest(partialVideo.readBytes()).joinToString("") { "%02x".format(it) }
                assertEquals(hash, artifact.sha256)
            } else {
                assertNull(videoArtifact)
            }
        } finally {
            controller.close()
            database.close()
            root.deleteRecursively()
        }
    }

    private fun verifyServerRoundTripIfConfigured(database: WoonaDatabase, recordingId: String, root: File) {
        val arguments = InstrumentationRegistry.getArguments()
        val baseUrl = arguments.getString("serverBaseUrl") ?: return
        val token = arguments.getString("serverToken") ?: "change-me-local-token"
        Log.i(TEST_LOG_TAG, "hashing local artifacts")
        database.hashPendingArtifacts()
        val local = requireNotNull(database.recordingSyncRecord(recordingId))
        assertTrue(local.sync.firstSensorPacketMonotonicNs != null)
        assertTrue(local.sync.videoFirstFrameMonotonicNs != null)
        assertEquals(
            local.sync.videoFirstFrameMonotonicNs!! - local.sync.firstSensorPacketMonotonicNs!!,
            local.sync.videoOffsetFromSensorNs,
        )
        assertTrue(requireNotNull(local.sync.videoFirstSamplePtsUs) >= 0L)

        val client = ServerApiClient(
            ServerSettings(
                baseUrl = baseUrl,
                token = token,
                deviceId = "physical-e2e",
                wifiOnly = false,
            ),
        )
        Log.i(TEST_LOG_TAG, "uploading profile")
        client.uploadProfile(local.profile)
        Log.i(TEST_LOG_TAG, "uploading recording and artifacts")
        client.uploadRecording(
            record = local,
            fileForArtifact = { id -> database.artifactFile(requireNotNull(local.artifacts.find { it.id == id })) },
            onProgress = { _, _, _ -> },
        )

        Log.i(TEST_LOG_TAG, "restoring server metadata")
        val remote = requireNotNull(client.fetchRestoreSnapshot().recordings.find { it.id == recordingId })
        assertEquals("completed", remote.captureStatus)
        assertEquals(Instant.parse(local.sync.sessionZeroAtUtc), Instant.parse(remote.sync.sessionZeroAtUtc))
        assertEquals(local.sync, remote.sync.copy(sessionZeroAtUtc = local.sync.sessionZeroAtUtc))
        assertEquals(
            local.artifacts.associate { it.type to Triple(it.sizeBytes, it.sha256, it.fileName) },
            remote.artifacts.associate { it.type to Triple(it.sizeBytes, it.sha256, it.fileName) },
        )
        val remoteVideo = requireNotNull(remote.artifacts.find { it.type == ArtifactType.VIDEO.value })
        val downloadedVideo = File(root, "server-video.mp4")
        Log.i(TEST_LOG_TAG, "downloading server video")
        client.downloadArtifact(remoteVideo.id, remoteVideo.sizeBytes, remoteVideo.sha256, downloadedVideo)
        assertEquals(remoteVideo.sizeBytes, downloadedVideo.length())
        Log.i(TEST_LOG_TAG, "server round-trip complete")
    }

    private fun waitUntil(message: String, predicate: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(15)
        while (!predicate() && System.nanoTime() < deadline) Thread.sleep(50)
        assertTrue(message, predicate())
    }

    private fun completeDog() = DogQuestionnaire(
        numberOrName = "Mock BLE dog",
        shelterOrPlace = "Device test",
        breedStatus = "unknown",
        size = "medium",
        ageStatus = "unknown",
        ageSource = "unknown",
        sex = "unknown",
        sterilizationStatus = "unknown",
        weightStatus = "unknown",
        bodyConditionStatus = "unable",
        muscleMass = "unable",
        neckCircumferenceStatus = "not_measured",
        coatLength = "unknown",
        undercoat = "unknown",
        shavedAreasStatus = "unknown",
        observedSigns = listOf("none"),
        diagnosesStatus = "unknown",
        housing = "unknown",
        walksStatus = "unknown",
        cohabitants = "unknown",
        shelterPermission = "unknown",
        notesStatus = "none",
    )

    private fun completeSession() = SessionQuestionnaire(
        sessionLabel = "Physical camera with mock BLE",
        operatorName = "Instrumentation",
        activityGroup = "stationary",
        activityType = "rest",
        location = "indoors",
        surface = "concrete",
        airTemperatureStatus = "not_measured",
        sensorPosition = "dorsal_neck",
        collarTightness = "snug",
        preMeasurementState = "rest",
        pulseStatus = "not_measured",
        respirationStatus = "not_measured",
        bodyTemperatureStatus = "not_measured",
        videoRequested = true,
    )

    private fun validPacket(counter: Int, timerMillis: Int): ByteArray {
        val block = byteArrayOf(
            2, 1, 2, 0, 0, 0,
            10, 0, 20, 0,
        )
        val length = 16 + block.size
        return ByteArray(length).apply {
            this[0] = 0x33
            this[1] = 0x99.toByte()
            this[2] = 0xAA.toByte()
            this[3] = 0x55
            this[4] = length.toByte()
            this[6] = 1
            this[7] = (counter and 0xFF).toByte()
            this[8] = ((counter shr 8) and 0xFF).toByte()
            this[9] = ((counter shr 16) and 0xFF).toByte()
            this[10] = ((counter shr 24) and 0xFF).toByte()
            this[11] = (timerMillis and 0xFF).toByte()
            this[12] = ((timerMillis shr 8) and 0xFF).toByte()
            this[13] = ((timerMillis shr 16) and 0xFF).toByte()
            this[14] = ((timerMillis shr 24) and 0xFF).toByte()
            System.arraycopy(block, 0, this, 16, block.size)
        }
    }

    private companion object {
        const val MOCK_ADDRESS = "00:11:22:33:44:55"
        const val TEST_LOG_TAG = "WOONA_PHYSICAL_E2E"
    }
}

private class MockBleSessionController(
    val listener: BleSessionListener,
) : BleSessionController {
    private var profile = BleTransportProfile.COMPATIBILITY

    override fun currentState(): BleSessionState = BleSessionState.CONNECTED
    override fun currentTransportProfile(): BleTransportProfile = profile
    override fun updateTransportProfile(profile: BleTransportProfile) {
        this.profile = profile
    }
    override fun startScanning() = Unit
    override fun stopScanning() = Unit
    override fun connect(address: String) = Unit
    override fun disconnect() = Unit
    override fun close() = Unit
}
