package com.example.myapplication

import android.graphics.Bitmap
import android.content.res.Configuration
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.getUnclippedBoundsInRoot
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performScrollTo
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.example.myapplication.data.DogProfile
import com.example.myapplication.data.DogQuestionnaire
import com.example.myapplication.ble.PolarConnectionState
import com.example.myapplication.ble.PolarStatus
import com.example.myapplication.feature.device.VideoCaptureState
import com.example.myapplication.localization.AppLanguage
import com.example.myapplication.profile.ProfilesOverview
import java.io.File
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.Assert.assertTrue

@RunWith(AndroidJUnit4::class)
class VisualCaptureScreenTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun recordingCaptureCard_fitsViewport() {
        capture(VideoCaptureState.RECORDING, "visual-capture-recording.png")
        composeRule.onNodeWithText("Sensor and video are recording").assertIsDisplayed()
        composeRule.onNodeWithText("Stop session").assertIsDisplayed()
        composeRule.onNodeWithText("ECG 12", substring = true).assertIsDisplayed()
    }

    @Test
    fun landscapePreview_fitsScreenHeightAndKeepsAspectRatio() {
        val landscape = Configuration().apply {
            orientation = Configuration.ORIENTATION_LANDSCAPE
            screenWidthDp = 640
            screenHeightDp = 320
        }
        composeRule.setContent {
            CompositionLocalProvider(LocalConfiguration provides landscape) {
                ProfilesOverview(
                    profiles = listOf(profile),
                    selectedProfileId = profile.id,
                    recordings = emptyList(),
                    language = AppLanguage.ENGLISH,
                    onSelectProfile = {},
                    onCreateProfile = {},
                    onEditProfile = {},
                    onShareRecording = {},
                    videoState = VideoCaptureState.RECORDING,
                    videoOffsetMillis = null,
                    onVideoAction = {},
                )
            }
        }
        val bounds = composeRule.onNodeWithTag("video_preview").getUnclippedBoundsInRoot()
        val height = (bounds.bottom - bounds.top).value
        val width = (bounds.right - bounds.left).value
        assertTrue("Landscape preview is too tall", height <= 128.5f)
        assertTrue("Landscape preview is stretched", kotlin.math.abs(width / height - 16f / 9f) < 0.02f)
    }

    private fun capture(state: VideoCaptureState, fileName: String) {
        composeRule.setContent {
            MaterialTheme {
                Surface(modifier = Modifier.fillMaxSize()) {
                    Column(modifier = Modifier.verticalScroll(rememberScrollState())) {
                        ProfilesOverview(
                            profiles = listOf(profile),
                            selectedProfileId = profile.id,
                            recordings = emptyList(),
                            language = AppLanguage.ENGLISH,
                            onSelectProfile = {},
                            onCreateProfile = {},
                            onEditProfile = {},
                            onShareRecording = {},
                            videoState = state,
                            videoOffsetMillis = 12.345,
                            onVideoAction = {},
                            polarStatus = PolarStatus(
                                state = PolarConnectionState.RECORDING,
                                heartRateBpm = 72,
                                ecgFrames = 12,
                                accFrames = 10,
                            ),
                        )
                    }
                }
            }
        }
        composeRule.onNodeWithText("Synchronized session").performScrollTo()
        composeRule.waitForIdle()
        val directory = checkNotNull(
            InstrumentationRegistry.getInstrumentation().targetContext.getExternalFilesDir(null),
        )
        val screenshot = File(directory, fileName)
        screenshot.outputStream().use { output ->
            check(composeRule.onRoot().captureToImage().asAndroidBitmap().compress(
                Bitmap.CompressFormat.PNG,
                100,
                output,
            ))
        }
    }

    private companion object {
        val profile = DogProfile(
            id = "visual-dog",
            profileVersionId = "visual-profile",
            numberOrName = "Visual Rex",
            questionnaire = DogQuestionnaire(numberOrName = "Visual Rex"),
            validationState = "complete",
            createdAtUtc = "2026-07-30T20:00:00Z",
            updatedAtUtc = "2026-07-30T20:00:00Z",
        )
    }
}
