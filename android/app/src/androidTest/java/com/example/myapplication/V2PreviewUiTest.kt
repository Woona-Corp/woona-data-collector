package com.example.myapplication

import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.width
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
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

    @Test fun allSevenPreviewSensorsRemainSelectableOnNarrowScreen() {
        val selections = mutableListOf<Int>()
        setNarrowCharts(DeviceUiState(v2DiscoveryRequested = true, v2Ready = true,
            v2StreamMask = 0x7f, v2PreviewStage = V2PreviewStage.RUNNING), selections::add)
        compose.onNodeWithText("T2").performScrollTo().assertIsDisplayed().performClick()
        compose.onNodeWithText("T2").assertIsSelected()
        compose.onNodeWithText("AXL").performScrollTo().assertIsDisplayed().performClick()
        compose.onNodeWithText("AXL").assertIsSelected()
        compose.runOnIdle { assertEquals(listOf(8, 2), selections) }
    }

    @Test fun failedPreviewRetainsAdvertisedSensorsInNormalAndFullscreenCharts() {
        val selections = mutableListOf<Int>()
        setNarrowCharts(DeviceUiState(v2DiscoveryRequested = true, v2Ready = false,
            v2StreamMask = 0x40, v2PreviewStage = V2PreviewStage.FAILED), selections::add)
        compose.onNodeWithText("T2").assertIsDisplayed().performClick()
        compose.onNodeWithText("T2").assertIsSelected()
        compose.onNodeWithText("T").assertDoesNotExist()
        compose.onNodeWithContentDescription("Open fullscreen chart").performClick()
        val inFullscreen = hasAnyAncestor(hasTestTag("chart_fullscreen_controls"))
        compose.onNode(hasText("T2") and inFullscreen).assertIsDisplayed().performClick()
        compose.onNode(hasText("T") and inFullscreen).assertDoesNotExist()
        compose.runOnIdle { assertEquals(listOf(8, 8), selections) }
    }

    private fun setNarrowCharts(initial: DeviceUiState, onSelect: (Int) -> Unit) {
        compose.setContent {
            AppLocalizationProvider(AppLanguage.ENGLISH, AppTextResolver(compose.activity) { AppLanguage.ENGLISH }) {
                MaterialTheme {
                    var state by remember { mutableStateOf(initial) }
                    Box(Modifier.width(320.dp).fillMaxHeight()) {
                        DeviceChartsScreen(state, onSensorSelect = {
                            state = state.copy(selectedSensorType = it, selectedChannel = 1)
                            onSelect(it)
                        }, onChannelSelect = {}, onChartWindowSelect = {}, onFollowLiveChange = {},
                            onChartPanLeft = {}, onChartPanRight = {}, onChartZoomIn = {},
                            onChartZoomOut = {}, onChartZoomReset = {}, onChartPanGesture = {},
                            onChartZoomGesture = { _, _ -> })
                    }
                }
            }
        }
    }

}
