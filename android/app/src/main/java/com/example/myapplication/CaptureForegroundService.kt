package com.example.myapplication

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.content.pm.ServiceInfo
import android.content.pm.PackageManager
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner

/** Keeps the process eligible to continue an active BLE capture off-screen. */
class CaptureForegroundService : Service() {
    private var foregroundTypes = 0
    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            CaptureServiceBridge.onStopRequested?.invoke()
            return START_NOT_STICKY
        }

        val captureGeneration = intent?.getLongExtra(EXTRA_CAPTURE_GENERATION, 0L) ?: 0L
        val notification = buildNotification()
        val requestedCamera = intent?.getBooleanExtra(EXTRA_VIDEO_REQUESTED, false) == true
        val cameraGranted = ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        val existingCamera = foregroundTypes and ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA != 0
        val types = captureForegroundTypes(requestedCamera, cameraGranted,
            existingCamera || intent?.getBooleanExtra(EXTRA_VISIBLE_CAMERA_START, false) == true)
        var cameraFailure: SecurityException? = null
        try {
            try {
                promote(notification, types)
            } catch (error: SecurityException) {
                if (types and ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA == 0) throw error
                // Visibility/permission may change after the Activity requested
                // the start. Preserve BLE capture with the connected-device type.
                cameraFailure = error
                promote(notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
            }
        } catch (error: SecurityException) {
            reportStartFailure(startId, error, captureGeneration)
            return START_NOT_STICKY
        } catch (error: IllegalStateException) {
            reportStartFailure(startId, error, captureGeneration)
            return START_NOT_STICKY
        }
        CaptureServiceBridge.isRunning = true
        CaptureServiceBridge.cameraForegroundEnabled = foregroundTypes and ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA != 0
        CaptureServiceBridge.onForegroundReady?.invoke(CaptureServiceBridge.cameraForegroundEnabled, captureGeneration)
        cameraFailure?.let { CaptureServiceBridge.onStartFailed?.invoke("camera_foreground_unavailable", it, captureGeneration) }
        return START_NOT_STICKY
    }

    private fun promote(notification: Notification, types: Int) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) startForeground(NOTIFICATION_ID, notification, types)
        else startForeground(NOTIFICATION_ID, notification)
        foregroundTypes = types
    }

    private fun reportStartFailure(startId: Int, error: RuntimeException, captureGeneration: Long) {
        CaptureServiceBridge.isRunning = false
        CaptureServiceBridge.cameraForegroundEnabled = false
        CaptureServiceBridge.onStartFailed?.invoke("capture_foreground_start_denied", error, captureGeneration)
        stopSelf(startId)
    }

    override fun onDestroy() {
        CaptureServiceBridge.isRunning = false
        CaptureServiceBridge.cameraForegroundEnabled = false
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun buildNotification(): Notification {
        val openIntent = PendingIntent.getActivity(
            this,
            REQUEST_OPEN,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stopIntent = PendingIntent.getService(
            this,
            REQUEST_STOP,
            Intent(this, CaptureForegroundService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setContentTitle(getString(R.string.capture_notification_title))
            .setContentText(getString(R.string.capture_notification_text))
            .setContentIntent(openIntent)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .addAction(R.drawable.ic_launcher_foreground, getString(R.string.capture_notification_stop), stopIntent)
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                getString(R.string.capture_notification_channel),
                NotificationManager.IMPORTANCE_LOW,
            ),
        )
    }

    companion object {
        private const val CHANNEL_ID = "woona_capture"
        private const val NOTIFICATION_ID = 0x574F4F4E
        private const val REQUEST_OPEN = 1
        private const val REQUEST_STOP = 2
        const val ACTION_STOP = "com.example.myapplication.action.STOP_CAPTURE"
        private const val EXTRA_CAPTURE_GENERATION = "capture_generation"
        private const val EXTRA_VIDEO_REQUESTED = "video_requested"
        private const val EXTRA_VISIBLE_CAMERA_START = "visible_camera_start"

        /** Pass the visible Activity for camera promotion; application Context
         * deliberately requests only the connected-device foreground type. */
        fun start(context: Context, videoRequested: Boolean = false, captureGeneration: Long = 0L): Boolean {
            var candidate = context
            while (candidate is ContextWrapper && candidate !is Activity) {
                val base = candidate.baseContext
                if (base === candidate) break
                candidate = base
            }
            val activity = candidate as? Activity
            val visible = activity != null && !activity.isFinishing && !activity.isDestroyed &&
                (activity as? LifecycleOwner)?.lifecycle?.currentState?.isAtLeast(Lifecycle.State.STARTED) == true
            val cameraGranted = ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
            val allowCamera = videoRequested && cameraGranted && visible
            return try {
                ContextCompat.startForegroundService(context, Intent(context, CaptureForegroundService::class.java)
                    .putExtra(EXTRA_CAPTURE_GENERATION, captureGeneration)
                    .putExtra(EXTRA_VIDEO_REQUESTED, videoRequested)
                    .putExtra(EXTRA_VISIBLE_CAMERA_START, allowCamera))
                true
            } catch (error: SecurityException) {
                CaptureServiceBridge.onStartFailed?.invoke("capture_foreground_start_denied", error, captureGeneration)
                false
            } catch (error: IllegalStateException) {
                CaptureServiceBridge.onStartFailed?.invoke("capture_foreground_start_denied", error, captureGeneration)
                false
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, CaptureForegroundService::class.java))
        }
    }
}

object CaptureServiceBridge {
    @Volatile
    var isRunning: Boolean = false

    @Volatile
    var cameraForegroundEnabled: Boolean = false

    @Volatile
    var onForegroundReady: ((cameraEnabled: Boolean, captureGeneration: Long) -> Unit)? = null

    @Volatile
    var onStartFailed: ((code: String, error: RuntimeException, captureGeneration: Long) -> Unit)? = null

    @Volatile
    var onStopRequested: (() -> Unit)? = null
}

internal fun captureForegroundTypes(videoRequested: Boolean, cameraGranted: Boolean, foregroundLaunch: Boolean): Int =
    ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or
        if (videoRequested && cameraGranted && foregroundLaunch) ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA else 0
