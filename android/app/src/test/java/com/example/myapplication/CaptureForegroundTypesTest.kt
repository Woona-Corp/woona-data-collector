package com.example.myapplication

import android.content.pm.ServiceInfo
import org.junit.Assert.assertEquals
import org.junit.Test

class CaptureForegroundTypesTest {
    @Test fun cameraRequiresVideoPermissionAndForegroundLaunchTogether() {
        for (video in listOf(false, true)) for (permission in listOf(false, true)) for (visible in listOf(false, true)) {
            val expected = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE or
                if (video && permission && visible) ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA else 0
            assertEquals("video=$video permission=$permission visible=$visible", expected,
                captureForegroundTypes(video, permission, visible))
        }
    }
}
