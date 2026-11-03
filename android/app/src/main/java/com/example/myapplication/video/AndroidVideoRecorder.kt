package com.example.myapplication.video

import android.annotation.SuppressLint
import android.content.Context
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.display.DisplayManager
import android.hardware.SensorManager
import android.media.MediaRecorder
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Range
import android.util.Size
import android.view.Display
import android.view.OrientationEventListener
import android.view.Surface
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

data class AndroidVideoStartInfo(
    val mediaRecorderStartedMonotonicNs: Long,
    val firstFrameMonotonicNs: Long,
    val firstFrameCameraTimestampNs: Long,
    val firstFrameCallbackMonotonicNs: Long,
    val cameraTimestampSource: String,
    val synchronizationQuality: String,
    val cameraId: String,
    val lensFacing: String,
    val width: Int,
    val height: Int,
    val frameRate: Int,
    val rotationDegrees: Int,
)

data class AndroidVideoStopInfo(
    val stoppedMonotonicNs: Long,
    val durationNs: Long?,
    val firstVideoSamplePtsUs: Long,
    val startInfo: AndroidVideoStartInfo? = null,
)

/** Stop has not been observed to finish; retry stop before starting another recording. */
class VideoStopPendingException(message: String, cause: Throwable? = null) :
    IllegalStateException(message, cause)

class AndroidVideoRecorder(
    context: Context,
    private val monotonicNanos: () -> Long = SystemClock::elapsedRealtimeNanos,
) : AutoCloseable {
    private val display = context.getSystemService(DisplayManager::class.java)
        ?.getDisplay(Display.DEFAULT_DISPLAY)
    private val appContext = context.applicationContext
    private val cameraManager = appContext.getSystemService(CameraManager::class.java)
    private val cameraThread = HandlerThread("woona-video").apply { start() }
    private val cameraHandler = Handler(cameraThread.looper)
    private val mainHandler = Handler(appContext.mainLooper)
    private val lock = Any()
    @Volatile
    private var deviceOrientationDegrees: Int? = null
    private val orientationListener = object : OrientationEventListener(appContext, SensorManager.SENSOR_DELAY_NORMAL) {
        override fun onOrientationChanged(orientation: Int) {
            if (orientation != ORIENTATION_UNKNOWN) {
                deviceOrientationDegrees = ((orientation + 45) / 90 * 90) % 360
            }
        }
    }

    init {
        if (orientationListener.canDetectOrientation()) orientationListener.enable()
    }

    @Volatile
    private var active = false
    @Volatile
    private var stopRequested = false
    private var camera: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var previewSurface: Surface? = null
    private var recorder: MediaRecorder? = null
    private var outputFile: File? = null
    private var firstFrameMonotonicNs: Long? = null
    @Volatile private var firstFrameInfo: AndroidVideoStartInfo? = null
    private class StopOperation {
        val latch = CountDownLatch(1)
        var result: AndroidVideoStopInfo? = null
        var failure: Throwable? = null
    }
    // Guarded by lock; the operation remains available until a caller observes completion.
    private var pendingStop: StopOperation? = null
    @Volatile
    private var recorderStarted = false
    private var mediaRecorderStartedMonotonicNs: Long? = null
    @Volatile
    private var startGeneration = 0L
    private var sessionGeneration = 0L
    private var cameraOpening = false
    private var cameraGeneration = 0L
    private var onStarted: ((AndroidVideoStartInfo) -> Unit)? = null
    private var onError: ((String, Throwable?) -> Unit)? = null
    private var lastFailure: Pair<String, Throwable?>? = null

    fun start(
        file: File,
        onStarted: (AndroidVideoStartInfo) -> Unit,
        onError: (String, Throwable?) -> Unit,
    ): Boolean {
        synchronized(lock) {
            if (active || pendingStop != null) return false
            active = true
            stopRequested = false
            outputFile = file
            firstFrameMonotonicNs = null
            firstFrameInfo = null
            recorderStarted = false
            mediaRecorderStartedMonotonicNs = null
            lastFailure = null
            startGeneration++
            this.onStarted = onStarted
            this.onError = onError
        }
        file.parentFile?.mkdirs()
        if (file.exists() && file.length() > 0L) {
            synchronized(lock) {
                active = false
                lastFailure = "Video file already exists; start a new recording" to null
            }
            onError.invoke("Video file already exists; start a new recording", null)
            return false
        }
        if (!cameraHandler.post {
            val openedCamera = camera
            if (openedCamera == null) {
                openCamera()
            } else {
                session?.close()
                session = null
                configureRecordingSession(openedCamera, selectCameraId())
            }
        }) {
            synchronized(lock) {
                active = false
                lastFailure = "Unable to schedule camera start" to null
            }
            onError.invoke("Unable to schedule camera start", null)
            return false
        }
        val generation = synchronized(lock) { startGeneration }
        cameraHandler.postDelayed(
            {
                if (active && firstFrameMonotonicNs == null && startGeneration == generation) {
                    fail("Camera start timed out", null)
                }
            },
            START_TIMEOUT_MILLIS,
        )
        return true
    }

    fun setPreviewSurface(surface: Surface?) {
        synchronized(lock) {
            previewSurface = surface
        }
        cameraHandler.post {
            if (active) {
                val openedCamera = camera
                if (openedCamera != null && recorderStarted) {
                    configureRecordingSession(openedCamera, selectCameraId(), startRecorder = false)
                }
                return@post
            }
            if (surface == null || !surface.isValid) {
                releaseSession()
            } else {
                val openedCamera = camera
                if (openedCamera == null) openCamera() else configurePreviewSession(openedCamera)
            }
        }
    }

    fun stop(timeoutMillis: Long = 4_000L): AndroidVideoStopInfo? {
        val operation = synchronized(lock) {
            pendingStop ?: run {
                if (!active) return null
                stopRequested = true
                val created = StopOperation()
                pendingStop = created
                // Post while holding the lock so no other caller can observe an unposted operation.
                val posted = try {
                    cameraHandler.post {
                        try {
                            created.result = stopOnCameraThread()
                        } catch (failure: Throwable) {
                            created.failure = failure
                        } finally {
                            created.latch.countDown()
                        }
                    }
                } catch (failure: RuntimeException) {
                    pendingStop = null
                    stopRequested = false
                    throw VideoStopPendingException("Unable to post camera stop; retry stop", failure)
                }
                if (!posted) {
                    pendingStop = null
                    stopRequested = false
                    throw VideoStopPendingException("Unable to post camera stop; retry stop")
                }
                created
            }
        }
        val completed = try {
            operation.latch.await(timeoutMillis, TimeUnit.MILLISECONDS)
        } catch (interrupted: InterruptedException) {
            Thread.currentThread().interrupt()
            throw VideoStopPendingException("Interrupted while waiting for camera stop; retry stop", interrupted)
        }
        if (!completed) throw VideoStopPendingException("Camera stop is still pending; retry stop")
        // An unexpected stop exception leaves camera/file state unknown. Keep
        // the failed operation latched rather than allowing a later call to
        // interpret inactive as a successful stop.
        operation.failure?.let { throw IllegalStateException("Camera stop failed unexpectedly", it) }
        synchronized(lock) {
            if (pendingStop === operation) pendingStop = null
        }
        return operation.result
    }

    fun isActive(): Boolean = active

    /** The current recording's asynchronous camera failure, retained until the next start. */
    fun currentFailure(): Pair<String, Throwable?>? = synchronized(lock) { lastFailure }

    /** True until a stop result (including null) has been observed by stop(). */
    fun hasPendingStop(): Boolean = synchronized(lock) { pendingStop != null }

    @SuppressLint("MissingPermission")
    private fun openCamera() {
        if (cameraOpening || camera != null) return
        cameraOpening = true
        val generation = ++cameraGeneration
        try {
            val cameraId = selectCameraId()
            cameraManager.openCamera(
                cameraId,
                object : CameraDevice.StateCallback() {
                    override fun onOpened(device: CameraDevice) {
                        if (generation != cameraGeneration) { device.close(); return }
                        cameraOpening = false
                        if (stopRequested) {
                            device.close()
                            return
                        }
                        camera = device
                        if (active) {
                            configureRecordingSession(device, cameraId)
                        } else if (synchronized(lock) { previewSurface }?.isValid == true) {
                            configurePreviewSession(device)
                        } else {
                            device.close()
                            camera = null
                        }
                    }

                    override fun onDisconnected(device: CameraDevice) {
                        if (generation != cameraGeneration) { device.close(); return }
                        cameraOpening = false
                        device.close()
                        fail("Camera disconnected", null)
                    }

                    override fun onError(device: CameraDevice, error: Int) {
                        if (generation != cameraGeneration) { device.close(); return }
                        cameraOpening = false
                        device.close()
                        fail("Camera error $error", null)
                    }
                },
                cameraHandler,
            )
        } catch (exception: Exception) {
            cameraOpening = false
            fail("Unable to open camera", exception)
        }
    }

    private fun configurePreviewSession(device: CameraDevice) {
        val surface = synchronized(lock) { previewSurface }?.takeIf(Surface::isValid) ?: return
        val generation = ++sessionGeneration
        try {
            session?.close()
            device.createCaptureSession(
                listOf(surface),
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(captureSession: CameraCaptureSession) {
                        if (generation != sessionGeneration || active) {
                            captureSession.close()
                            return
                        }
                        try {
                            session = captureSession
                            val request = device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                                addTarget(surface)
                                set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
                            }.build()
                            captureSession.setRepeatingRequest(request, null, cameraHandler)
                        } catch (exception: Exception) {
                            fail("Unable to start camera preview", exception)
                        }
                    }

                    override fun onConfigureFailed(captureSession: CameraCaptureSession) {
                        if (generation == sessionGeneration) {
                            fail("Unable to configure camera preview", null)
                        }
                    }
                },
                cameraHandler,
            )
        } catch (exception: Exception) {
            fail("Unable to start camera preview", exception)
        }
    }

    private fun configureRecordingSession(
        device: CameraDevice,
        cameraId: String,
        startRecorder: Boolean = true,
    ) {
        val generation = ++sessionGeneration
        val recordingGeneration = synchronized(lock) { startGeneration }
        try {
            val characteristics = cameraManager.getCameraCharacteristics(cameraId)
            val size = selectVideoSize(characteristics)
            val frameRate = selectFrameRate(characteristics)
            val rotation = videoRotation(characteristics)
            val mediaRecorder = if (startRecorder) {
                MediaRecorder(appContext).also { recorder = it }.apply {
                    setVideoSource(MediaRecorder.VideoSource.SURFACE)
                    setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                    setOutputFile(requireNotNull(outputFile).absolutePath)
                    setVideoEncodingBitRate(6_000_000)
                    setVideoFrameRate(frameRate.upper)
                    setVideoSize(size.width, size.height)
                    setVideoEncoder(MediaRecorder.VideoEncoder.H264)
                    setOrientationHint(rotation)
                    prepare()
                }
            } else {
                recorder ?: return
            }
            val recorderSurface = mediaRecorder.surface
            val preview = synchronized(lock) { previewSurface }?.takeIf(Surface::isValid)
            val surfaces = listOfNotNull(recorderSurface, preview)
            session?.close()
            session = null
            device.createCaptureSession(
                surfaces,
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(captureSession: CameraCaptureSession) {
                        if (generation != sessionGeneration) {
                            captureSession.close()
                            return
                        }
                        if (stopRequested) {
                            captureSession.close()
                            return
                        }
                        session = captureSession
                        try {
                            val request = device.createCaptureRequest(CameraDevice.TEMPLATE_RECORD).apply {
                                addTarget(recorderSurface)
                                preview?.let(::addTarget)
                                set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO)
                                set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, frameRate)
                            }.build()
                            captureSession.setRepeatingRequest(
                                request,
                                if (startRecorder) {
                                    firstFrameCallback(cameraId, characteristics, size, frameRate, rotation, recordingGeneration)
                                } else {
                                    null
                                },
                                cameraHandler,
                            )
                            if (startRecorder) {
                                mediaRecorder.start()
                                mediaRecorderStartedMonotonicNs = monotonicNanos()
                                recorderStarted = true
                            }
                        } catch (exception: Exception) {
                            fail("Unable to start video", exception)
                        }
                    }

                    override fun onConfigureFailed(captureSession: CameraCaptureSession) {
                        if (generation == sessionGeneration) {
                            fail("Unable to configure camera", null)
                        }
                    }
                },
                cameraHandler,
            )
        } catch (exception: Exception) {
            fail("Unable to prepare video", exception)
        }
    }

    private fun firstFrameCallback(
        cameraId: String,
        characteristics: CameraCharacteristics,
        size: Size,
        frameRate: Range<Int>,
        rotation: Int,
        recordingGeneration: Long,
    ) = object : CameraCaptureSession.CaptureCallback() {
        override fun onCaptureStarted(
            session: CameraCaptureSession,
            request: CaptureRequest,
            timestamp: Long,
            frameNumber: Long,
        ) {
            if (synchronized(lock) { startGeneration != recordingGeneration || !active } ||
                !recorderStarted || firstFrameMonotonicNs != null) return
            val timestampSource = characteristics.get(CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE)
            val isRealtime = timestampSource == CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME
            val callbackMonotonicNs = monotonicNanos()
            val monotonicTimestamp = if (isRealtime) timestamp else callbackMonotonicNs
            firstFrameMonotonicNs = monotonicTimestamp
            val info = AndroidVideoStartInfo(
                mediaRecorderStartedMonotonicNs = requireNotNull(mediaRecorderStartedMonotonicNs),
                firstFrameMonotonicNs = monotonicTimestamp,
                firstFrameCameraTimestampNs = timestamp,
                firstFrameCallbackMonotonicNs = callbackMonotonicNs,
                cameraTimestampSource = if (isRealtime) "realtime" else "unknown",
                synchronizationQuality = if (isRealtime) "arrival_aligned" else "callback_estimate",
                cameraId = cameraId,
                lensFacing = lensFacing(characteristics),
                width = size.width,
                height = size.height,
                frameRate = frameRate.upper,
                rotationDegrees = rotation,
            )
            firstFrameInfo = info
            val callback = synchronized(lock) {
                if (startGeneration == recordingGeneration) onStarted else null
            }
            mainHandler.post {
                if (startGeneration == recordingGeneration) callback?.invoke(info)
            }
        }
    }

    private fun stopOnCameraThread(): AndroidVideoStopInfo? {
        val stoppedAt = monotonicNanos()
        var validVideo = recorder != null && firstFrameMonotonicNs != null
        try {
            session?.stopRepeating()
            session?.abortCaptures()
        } catch (_: Exception) {
        }
        try {
            recorder?.stop()
        } catch (_: Exception) {
            validVideo = false
        }
        releaseSession()
        val firstVideoSamplePtsUs = outputFile?.let(::firstVideoSamplePtsUs)
        validVideo = validVideo && firstVideoSamplePtsUs != null
        val startedAt = firstFrameMonotonicNs
        synchronized(lock) {
            active = false
            stopRequested = false
            recorderStarted = false
        }
        return if (validVideo) AndroidVideoStopInfo(
            stoppedMonotonicNs = stoppedAt,
            durationNs = startedAt?.let { (stoppedAt - it).coerceAtLeast(0L) },
            firstVideoSamplePtsUs = requireNotNull(firstVideoSamplePtsUs),
            startInfo = firstFrameInfo,
        ) else null
    }

    private fun fail(message: String, throwable: Throwable?) {
        val (failedGeneration, errorCallback) = synchronized(lock) {
            val callback = startGeneration to onError
            if (active) lastFailure = message to throwable
            releaseSession()
            active = false
            stopRequested = false
            recorderStarted = false
            callback
        }
        mainHandler.post { if (startGeneration == failedGeneration) errorCallback?.invoke(message, throwable) }
    }

    private fun releaseSession() {
        sessionGeneration++
        cameraGeneration++
        cameraOpening = false
        try {
            session?.close()
        } catch (_: Exception) {
        }
        try {
            recorder?.reset()
            recorder?.release()
        } catch (_: Exception) {
        }
        try {
            camera?.close()
        } catch (_: Exception) {
        }
        session = null
        recorder = null
        camera = null
    }

    private fun selectCameraId(): String {
        return cameraManager.cameraIdList.firstOrNull { id ->
            cameraManager.getCameraCharacteristics(id)
                .get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
        } ?: cameraManager.cameraIdList.firstOrNull()
        ?: error("No camera available")
    }

    private fun selectVideoSize(characteristics: CameraCharacteristics): Size {
        val sizes = characteristics
            .get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?.getOutputSizes(MediaRecorder::class.java)
            .orEmpty()
        val capped = sizes.filter { it.width <= 1920 && it.height <= 1080 }
        return capped
            .filter { it.width * 9 == it.height * 16 }
            .maxByOrNull { it.width.toLong() * it.height }
            ?: capped.maxByOrNull { it.width.toLong() * it.height }
            ?: sizes
                .filter { it.width * 9 == it.height * 16 }
                .maxByOrNull { it.width.toLong() * it.height }
            ?: sizes.maxByOrNull { it.width.toLong() * it.height }
            ?: error("Camera has no video size")
    }

    private fun selectFrameRate(characteristics: CameraCharacteristics): Range<Int> {
        val ranges = characteristics.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES).orEmpty()
        return ranges
            .filter { it.contains(30) }
            .minByOrNull { (it.upper - it.lower) * 1000 + it.upper }
            ?: ranges.maxByOrNull { it.upper }
            ?: Range(30, 30)
    }

    private fun videoRotation(characteristics: CameraCharacteristics): Int {
        val sensor = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
        val displayDegrees = when (display?.rotation ?: Surface.ROTATION_0) {
            Surface.ROTATION_90 -> 90
            Surface.ROTATION_180 -> 180
            Surface.ROTATION_270 -> 270
            else -> 0
        }
        val clockwiseOrientation = deviceOrientationDegrees ?: (360 - displayDegrees) % 360
        return videoRotationDegrees(
            sensor,
            characteristics.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_FRONT,
            clockwiseOrientation,
        )
    }

    private fun lensFacing(characteristics: CameraCharacteristics): String {
        return when (characteristics.get(CameraCharacteristics.LENS_FACING)) {
            CameraCharacteristics.LENS_FACING_FRONT -> "front"
            CameraCharacteristics.LENS_FACING_BACK -> "back"
            CameraCharacteristics.LENS_FACING_EXTERNAL -> "external"
            else -> "unknown"
        }
    }

    private fun firstVideoSamplePtsUs(file: File): Long? {
        if (!file.isFile || file.length() == 0L) return null
        return runCatching {
            val extractor = MediaExtractor()
            try {
                extractor.setDataSource(file.absolutePath)
                val track = (0 until extractor.trackCount).firstOrNull { index ->
                    extractor.getTrackFormat(index)
                        .getString(MediaFormat.KEY_MIME)
                        ?.startsWith("video/") == true
                } ?: return null
                extractor.selectTrack(track)
                extractor.seekTo(0L, MediaExtractor.SEEK_TO_CLOSEST_SYNC)
                extractor.sampleTime.takeIf { it >= 0L }
            } finally {
                extractor.release()
            }
        }.getOrNull()
    }

    override fun close() {
        orientationListener.disable()
        stop()
        setPreviewSurface(null)
        cameraThread.quitSafely()
    }

    private companion object {
        const val START_TIMEOUT_MILLIS = 10_000L
    }
}

internal fun videoRotationDegrees(sensor: Int, front: Boolean, clockwiseOrientation: Int): Int =
    (sensor + (if (front) clockwiseOrientation else -clockwiseOrientation) + 360) % 360
