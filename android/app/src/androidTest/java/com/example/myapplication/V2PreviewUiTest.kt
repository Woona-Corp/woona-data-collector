package com.example.myapplication

import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import com.example.myapplication.feature.device.*
import com.example.myapplication.localization.AppLanguage
import com.example.myapplication.localization.AppLocalizationProvider
import com.example.myapplication.localization.AppTextResolver
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class V2PreviewUiTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun pickerDefaultsToRecordingAndRoutesExplicitPreviewWithoutAnimalQuestionnaire() {
        val ordinary = mutableListOf<String>()
        val preview = mutableListOf<String>()
        compose.setContent {
            AppLocalizationProvider(AppLanguage.ENGLISH, AppTextResolver(compose.activity) { AppLanguage.ENGLISH }) {
                MaterialTheme {
                    DeviceOverviewScreen(
                        DeviceUiState(foundDevices = listOf(DeviceListItem("Synthetic V2 sensor", "AA:BB"))),
                        onStartScan = {}, onConnect = ordinary::add, onDisconnect = {},
                        onV2PreviewConnect = preview::add, showReplayAction = false, onReplayRequest = {},
                    )
                }
            }
        }
        compose.onNodeWithText("New connection").performClick()
        compose.onNodeWithTag("ble.purpose.recording").assertIsSelected()
        compose.onNodeWithTag("ble.purpose.v2").performClick()
        compose.onNodeWithText("Connect only to an idle sensor.", substring = true).assertExists()
        compose.onNodeWithText("Synthetic V2 sensor").performClick()
        compose.runOnIdle { assertEquals(listOf("AA:BB"), preview); assertEquals(emptyList<String>(), ordinary) }
        compose.onNodeWithText("New connection").performClick()
        compose.onNodeWithTag("ble.purpose.recording").assertIsSelected()
        compose.onNodeWithText("Synthetic V2 sensor").performClick()
        compose.runOnIdle { assertEquals(listOf("AA:BB"), ordinary) }
    }

    @Test fun failedPreviewRetainsConnectionAndManualDisconnectRequiresConfirmation() {
        var disconnects = 0
        compose.setContent {
            AppLocalizationProvider(AppLanguage.ENGLISH, AppTextResolver(compose.activity) { AppLanguage.ENGLISH }) {
                MaterialTheme {
                    DeviceOverviewScreen(
                        DeviceUiState(showCaptureUi = true, v2DiscoveryRequested = true,
                            v2PreviewStage = V2PreviewStage.FAILED, v2DiscoveryError = "Sensor is already recording to SD"),
                        onStartScan = {}, onConnect = {}, onDisconnect = { disconnects++ },
                        showReplayAction = false, onReplayRequest = {},
                    )
                }
            }
        }
        compose.runOnIdle { assertEquals(0, disconnects) }
        compose.onNodeWithText("DISCONNECT").performClick()
        compose.onNodeWithText("Disconnecting may stop an SD-card recording. Continue?").assertIsDisplayed()
        compose.onNodeWithText("Cancel").performClick()
        compose.runOnIdle { assertEquals(0, disconnects) }
        compose.onNodeWithText("DISCONNECT").performClick()
        compose.onAllNodesWithText("DISCONNECT").onLast().performClick()
        compose.runOnIdle { assertEquals(1, disconnects) }
    }
}
