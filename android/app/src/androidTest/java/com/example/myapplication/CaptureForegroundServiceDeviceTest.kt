package com.example.myapplication

import android.Manifest
import android.app.ActivityManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import androidx.activity.ComponentActivity
import androidx.lifecycle.Lifecycle
import androidx.test.ext.junit.rules.ActivityScenarioRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.util.concurrent.atomic.AtomicInteger
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Tests Android's foreground-service registration, without opening a camera or BLE. */
@RunWith(AndroidJUnit4::class)
class CaptureForegroundServiceDeviceTest {
    @get:Rule val activityRule = ActivityScenarioRule(ComponentActivity::class.java)
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private var previousStop: (() -> Unit)? = null

    @Before fun prepare() {
        CaptureForegroundService.stop(context)
        await { !CaptureServiceBridge.isRunning }
        previousStop = CaptureServiceBridge.onStopRequested
        instrumentation.uiAutomation.grantRuntimePermission(context.packageName, Manifest.permission.BLUETOOTH_CONNECT)
    }

    @After fun finish() {
        CaptureForegroundService.stop(context)
        await { !CaptureServiceBridge.isRunning }
        CaptureServiceBridge.onStopRequested = previousStop
    }

    @Test fun manifestDeclaresCameraPermissionAndBothForegroundTypes() {
        val info = context.packageManager.getServiceInfo(ComponentName(context, CaptureForegroundService::class.java), 0)
        assertEquals(ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA,
            info.foregroundServiceType)
        val permissions = context.packageManager.getPackageInfo(context.packageName, PackageManager.GET_PERMISSIONS).requestedPermissions.orEmpty()
        assertTrue(permissions.contains(Manifest.permission.FOREGROUND_SERVICE_CAMERA))
    }

    @Test fun sensorOnlyCaptureNeverPromotesCameraEvenWhenPermissionExists() {
        activityRule.scenario.onActivity { assertTrue(CaptureForegroundService.start(it, videoRequested = false)) }
        await { CaptureServiceBridge.isRunning }
        assertFalse(CaptureServiceBridge.cameraForegroundEnabled)
        assertTrue(isForeground())
    }

    @Test fun visibleGrantedCameraPromotionSurvivesActivityStopAndKeepsExplicitStopCallback() {
        instrumentation.uiAutomation.grantRuntimePermission(context.packageName, Manifest.permission.CAMERA)
        activityRule.scenario.onActivity { assertTrue(CaptureForegroundService.start(it, videoRequested = true)) }
        await { CaptureServiceBridge.isRunning && CaptureServiceBridge.cameraForegroundEnabled }
        assertTrue(isForeground())
        activityRule.scenario.moveToState(Lifecycle.State.CREATED)
        assertTrue(CaptureServiceBridge.isRunning)
        assertTrue(CaptureServiceBridge.cameraForegroundEnabled)
        val stops = AtomicInteger()
        CaptureServiceBridge.onStopRequested = { stops.incrementAndGet() }
        context.startService(Intent(context, CaptureForegroundService::class.java).setAction(CaptureForegroundService.ACTION_STOP))
        await { stops.get() == 1 }
        // Finalization owns stopping the service; notification Stop only requests it.
        assertTrue(CaptureServiceBridge.isRunning)
        CaptureForegroundService.stop(context)
        await { !CaptureServiceBridge.isRunning }
        assertFalse(CaptureServiceBridge.cameraForegroundEnabled)
    }

    @Suppress("DEPRECATION")
    private fun isForeground(): Boolean = context.getSystemService(ActivityManager::class.java)
        .getRunningServices(100).any { it.service == ComponentName(context, CaptureForegroundService::class.java) && it.foreground }

    private fun await(condition: () -> Boolean) {
        val deadline = System.nanoTime() + 5_000_000_000L
        while (System.nanoTime() < deadline && !condition()) Thread.sleep(25)
        assertTrue("Foreground-service state did not settle", condition())
    }
}
