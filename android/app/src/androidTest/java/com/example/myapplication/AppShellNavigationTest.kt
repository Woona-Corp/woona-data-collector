package com.example.myapplication

import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.isDisplayed
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.hasAnySibling
import androidx.compose.ui.test.isToggleable
import androidx.test.espresso.Espresso
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.assertIsNotSelected
import androidx.compose.ui.test.assertIsSelected
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.hasAnyDescendant
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.junit4.StateRestorationTester
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.example.myapplication.feature.device.ChartPoint
import com.example.myapplication.feature.device.ChartUiState
import com.example.myapplication.feature.device.DeviceUiState
import com.example.myapplication.feature.device.ExportPhase
import com.example.myapplication.localization.AppLanguage
import com.example.myapplication.localization.AppLocalizationProvider
import com.example.myapplication.localization.AppTextResolver
import com.example.myapplication.data.HeartQuestionnaire
import com.example.myapplication.data.HEART_OPTIONS
import com.example.myapplication.data.canonicalJsonSha256
import com.example.myapplication.profile.HeartQuestionnaireDialog
import com.example.myapplication.profile.DogQuestionnaireDialog
import com.example.myapplication.profile.SessionQuestionnaireDialog
import com.example.myapplication.sync.ServerSyncUiState
import com.example.myapplication.sync.ServerSyncStatus
import com.example.myapplication.ui.theme.AppThemeMode
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

private const val CHART_FULLSCREEN_DIALOG_TEST_TAG = "chart_fullscreen_dialog"

@RunWith(AndroidJUnit4::class)
class AppShellNavigationTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<ComponentActivity>()

    @Test
    fun completedHeartQuestionnaireSavesWithoutLosingExistingAnswers() {
        val initial = HeartQuestionnaire(
            answers = HEART_OPTIONS.keys.filter { it != "acuteHeartRateFactors" }.associateWith { "unknown" } +
                mapOf("knownHeartCondition" to "yes", "heartRelevantMedication" to "yes", "referenceMethod" to "bpm_only"),
            acuteHeartRateFactors = listOf("stress", "pain"),
            knownHeartConditionDetails = "Existing diagnosis",
            heartRelevantMedicationDetails = "Existing medication and timing",
            referenceBpm = 121.0,
            referenceMeasuredAtUtc = "2026-10-10T10:00:00Z",
        )
        var saved: HeartQuestionnaire? = null
        composeRule.setContent {
            MaterialTheme {
                HeartQuestionnaireDialog(AppLanguage.ENGLISH, initial, onDismiss = {}, onSave = { saved = it })
            }
        }
        composeRule.onNodeWithText("Answered: 6 of 6").assertIsDisplayed()
        composeRule.onNodeWithText("Validate and save").performClick()
        composeRule.runOnIdle {
            assertEquals(canonicalJsonSha256(initial.toJson().toString()),
                canonicalJsonSha256(requireNotNull(saved).toJson().toString()))
        }
    }

    @Test
    fun operationFailureDetailsRemainVisibleAcrossAllTabs() {
        val details = "Download failed: java.net.SocketTimeoutException: read timed out"
        setShellContent(uiState = DeviceUiState(errorMessage = details))
        composeRule.onNodeWithText(details).scrollToIfNeeded().assertIsDisplayed()
        chartControl().performClick()
        composeRule.onNodeWithText(details).assertIsDisplayed()
        navTab("Settings").performClick()
        composeRule.onNodeWithText(details).assertIsDisplayed()
    }

    @Test
    fun serverSettingsShowsUploadFailureReason() {
        val message = "Server returned HTTP 401: invalid_bearer_token"
        setShellContent(serverSyncState = ServerSyncUiState(
            status = ServerSyncStatus.NEEDS_ATTENTION,
            failed = 1,
            lastErrorMessage = message,
        ))

        navTab("Settings").performClick()
        composeRule.onNode(hasScrollAction()).performScrollToIndex(3)
        composeRule.onNodeWithText(message).performScrollTo().assertIsDisplayed()
        composeRule.onNodeWithText("Retry uploads").performScrollTo().assertIsEnabled()
    }

    @Test
    fun animalsIsDefaultAndAllFiveDestinationsAreVisible() {
        setShellContent(openSession = false)
        navTab("Animals").assertIsSelected()
        for (label in listOf("Session", "Video", "Recordings", "Settings")) navTab(label).assertIsNotSelected()
        composeRule.onNodeWithText("New connection").assertDoesNotExist()
        navTab("Session").performClick()
        composeRule.onNodeWithText("New connection").assertIsDisplayed().performClick()
        composeRule.onNodeWithText("BLE devices").assertIsDisplayed()
    }

    @Test
    fun bottomNavigation_switchesBetweenDestinations() {
        setShellContent(
            uiState = DeviceUiState(showCaptureUi = true),
        )

        chartControl().performClick()
        chartControl().assertIsSelected()
        navTab("Animals").assertIsNotSelected()
        navTab("Session").assertIsSelected()
        composeRule.onNodeWithText("Y Reset").scrollToIfNeeded().assertIsDisplayed()

        navTab("Settings").performClick()
        navTab("Settings").assertIsSelected()
        composeRule.onNode(hasScrollAction()).performScrollToIndex(1)
        composeRule.onNodeWithText("Theme").assertIsDisplayed()
        composeRule.onNodeWithText("Export").assertDoesNotExist()

        navTab("Session").performClick()
        navTab("Session").assertIsSelected()
        composeRule.onNode(hasTestTag("session.summary")).performClick()
        composeRule.onNodeWithText("Connection").assertIsDisplayed()
    }

    @Test
    fun exportButton_isHiddenOnSettings_andDisabledWithoutFiles() {
        setShellContent()

        composeRule.onNodeWithText("Export").assertExists().assertIsNotEnabled()

        composeRule.onNodeWithText("Settings").performClick()

        composeRule.onNodeWithText("Export").assertDoesNotExist()
    }

    @Test
    fun exportSheet_showsAvailableActions_andDisablesUnavailableOnes() {
        setShellContent(
            canShareAllFiles = true,
            canSharePacketFile = true,
            canShareCsvFile = true,
            canShareRawFile = false,
            canShareLogFile = true,
        )

        composeRule.onNodeWithText("Export").assertIsEnabled().performClick()

        composeRule.onNodeWithText("Session ZIP").assertIsEnabled()
        composeRule.onNodeWithText("Compiled binary").assertIsEnabled()
        composeRule.onNodeWithText("Channel CSV").assertIsEnabled()
        composeRule.onNodeWithText("Raw data stream").assertIsNotEnabled()
        composeRule.onNodeWithText("Session log").assertIsEnabled()
    }

    @Test
    fun exportWorksFromCharts_andDismissesSheetAfterSelection() {
        var exportAllClicks = 0
        setShellContent(
            uiState = DeviceUiState(showCaptureUi = true),
            canShareAllFiles = true,
            onShareAllFiles = { exportAllClicks++ },
        )

        chartControl().performClick()
        composeRule.onNodeWithText("Export").assertIsEnabled().performClick()
        composeRule.onNodeWithText("Session ZIP").assertIsEnabled().performClick()

        composeRule.waitForIdle()
        composeRule.onNodeWithText("Session ZIP").assertDoesNotExist()
        composeRule.runOnIdle {
            assertEquals(1, exportAllClicks)
        }
    }

    @Test
    fun exportProgress_overlayIsVisibleAndDisablesExportButton() {
        setShellContent(
            uiState = DeviceUiState(
                showCaptureUi = true,
                exportPhase = ExportPhase.GENERATING_CSV,
            ),
            canShareAllFiles = true,
        )

        composeRule.onNodeWithText("Export").assertExists().assertIsNotEnabled()
        composeRule.onNodeWithText("Preparing export").assertIsDisplayed()
        composeRule.onNodeWithText("Generating CSV").assertIsDisplayed()
    }

    @Test
    fun chartsDestination_remainsAccessible_withEmptyState() {
        setShellContent(
            uiState = DeviceUiState(showCaptureUi = true),
        )

        chartControl().performClick()

        composeRule.onNodeWithText("Y Reset").scrollToIfNeeded().assertIsDisplayed()
        composeRule
            .onNodeWithText("No data for the selected sensor/channel")
            .scrollToIfNeeded()
            .assertIsDisplayed()
    }

    @Test
    fun chartsFullscreen_opensAndClosesOverlay() {
        setShellContent(
            uiState = DeviceUiState(
                showCaptureUi = true,
                chart = ChartUiState(
                    points = listOf(
                        ChartPoint(timeMillis = 0L, value = 10f),
                        ChartPoint(timeMillis = 1_000L, value = 20f),
                    ),
                    viewportStartMillis = 0L,
                    viewportEndMillis = 1_000L,
                    sessionStartMillis = 0L,
                    latestPointMillis = 1_000L,
                ),
            ),
        )

        chartControl().performClick()
        composeRule.onNodeWithContentDescription("Open fullscreen chart").performClick()

        composeRule.onNodeWithText("Fullscreen chart").assertIsDisplayed()
        composeRule.onNodeWithContentDescription("Close fullscreen chart").performClick()

        composeRule.onNodeWithText("Fullscreen chart").assertDoesNotExist()
    }

    @Test
    fun chartsFullscreen_supportsEmptyChartState() {
        setShellContent(
            uiState = DeviceUiState(showCaptureUi = true),
        )

        chartControl().performClick()
        composeRule.onNodeWithContentDescription("Open fullscreen chart").performClick()

        composeRule.onNodeWithText("Fullscreen chart").assertIsDisplayed()
        composeRule.onNode(
            hasTestTag(CHART_FULLSCREEN_DIALOG_TEST_TAG) and
                hasAnyDescendant(hasText("No data for the selected sensor/channel")),
            useUnmergedTree = true,
        )
            .assertExists()
    }

    @Test
    fun settingsThemeControl_emitsSelectionChanges() {
        var selectedThemeMode = AppThemeMode.SYSTEM
        setShellContent(
            onThemeModeSelect = { themeMode -> selectedThemeMode = themeMode },
        )

        navTab("Settings").performClick()
        composeRule.onNode(hasScrollAction()).performScrollToIndex(1)
        composeRule.onNodeWithText("Dark").performScrollTo().assertIsDisplayed().performClick()

        composeRule.runOnIdle {
            assertEquals(AppThemeMode.DARK, selectedThemeMode)
        }
    }

    @Test
    fun serverConfiguration_isAvailableFromSettings() {
        setShellContent()
        navTab("Settings").performClick()

        composeRule.onNode(hasScrollAction()).performScrollToIndex(3)
        composeRule.onNodeWithText("Server storage").assertIsDisplayed()
        composeRule.onNodeWithText("Connect").assertIsEnabled()
    }

    @Test
    fun failedProfileSaveShowsInlineCauseAndPreservesDraftForRetry() {
        var attempts = 0
        var savedName: String? = null
        composeRule.setContent {
            MaterialTheme {
                DogQuestionnaireDialog(initial = null, required = false, language = AppLanguage.ENGLISH,
                    onDismiss = {}, onSave = { profile ->
                        attempts++
                        if (attempts == 1) error("Injected database save failure")
                        savedName = profile.numberOrName
                    })
            }
        }
        composeRule.onNodeWithText("Номер/ID животного *").performTextInput("retained-id")
        composeRule.onNodeWithText("Кличка *").performTextInput("Retained draft")
        composeRule.onNodeWithText("Validate and save").performClick()
        composeRule.onNodeWithText("Injected database save failure", substring = true).assertIsDisplayed()
        composeRule.onNodeWithText("Retained draft").assertIsDisplayed()
        composeRule.runOnIdle { assertEquals(null, savedName) }
        composeRule.onNodeWithText("Validate and save").performClick()
        composeRule.runOnIdle { assertEquals("Retained draft", savedName); assertEquals(2, attempts) }
    }

    @Test
    fun busyServerSettingsKeepReadOnlyConnectionCheckAvailable() {
        setShellContent(serverSyncState = ServerSyncUiState(
            status = ServerSyncStatus.READY, pending = 1, mutationsAllowed = false, mutationBlockReason = "capture"))
        navTab("Settings").performClick()
        composeRule.onNode(hasScrollAction()).performScrollToIndex(3)
        composeRule.onNodeWithText("Check connection").performScrollTo().assertIsEnabled()
        composeRule.onNodeWithText("Reconnect").performScrollTo().assertIsNotEnabled()
        composeRule.onNodeWithText("Retry uploads").performScrollTo().assertIsNotEnabled()
        composeRule.onNodeWithText("Restore from server").performScrollTo().assertIsNotEnabled()
    }

    @Test
    fun queuedUploadDoesNotPreventChangingWifiOnlyPolicy() {
        setShellContent(serverSyncState = ServerSyncUiState(status = ServerSyncStatus.WAITING,
            uploading = 1, workersRunning = 0, mutationsAllowed = false, networkPolicyAllowed = true))
        navTab("Settings").performClick()
        composeRule.onNode(hasScrollAction()).performScrollToIndex(3)
        composeRule.onNodeWithText("Wi-Fi only").performScrollTo()
        composeRule.onNode(isToggleable() and hasAnySibling(hasText("Wi-Fi only")), useUnmergedTree = true).assertIsEnabled()
    }

    @Test
    fun requiredDogProfile_cannotBeSkipped() {
        var savedProfiles = 0
        composeRule.setContent {
            MaterialTheme {
                DogQuestionnaireDialog(
                    initial = null,
                    required = true,
                    language = AppLanguage.ENGLISH,
                    onDismiss = {},
                    onSave = { savedProfiles++ },
                )
            }
        }

        composeRule.onNodeWithText("Dog questionnaire").assertIsDisplayed()
        composeRule.onNodeWithText("Cancel").assertDoesNotExist()
        composeRule.onNodeWithText("Validate and save").performClick()
        composeRule.runOnIdle {
            assertEquals(0, savedProfiles)
        }
        composeRule.onNodeWithText("Answered: 0 of 2").assertIsDisplayed()
        composeRule.onNodeWithText("2 fields need attention").assertIsDisplayed()
        composeRule.onNodeWithText("Номер/ID животного *").assertIsDisplayed()
        composeRule.onNodeWithText("Dog questionnaire").assertIsDisplayed()
    }

    @Test
    fun sheetSession_supportsMultipleRecordingTypes() {
        var saved: com.example.myapplication.data.SessionQuestionnaire? = null
        composeRule.setContent {
            MaterialTheme {
                SessionQuestionnaireDialog(
                    language = AppLanguage.ENGLISH,
                    onDismiss = {},
                    onSave = { saved = it },
                )
            }
        }

        composeRule.onNodeWithText("Номер сессии *").performTextInput("1")
        Espresso.closeSoftKeyboard()
        composeRule.onNodeWithText("Аллюр/движение").performScrollTo().performClick()
        checkbox("Аллюр/движение").assertIsOn()
        checkbox("Активность").performScrollTo().performClick()
        checkbox("Аллюр/движение").assertIsOn()
        checkbox("Активность").assertIsOn()
        composeRule.onNodeWithText("Validate and save").performClick()
        composeRule.runOnIdle { assertEquals(listOf("Аллюр/движение", "Активность"), saved?.plannedActivities) }
    }

    @Test
    fun questionnaireSaveFailure_showsDetailsAndKeepsDraftOpen() {
        composeRule.setContent {
            MaterialTheme {
                SessionQuestionnaireDialog(
                    language = AppLanguage.ENGLISH,
                    onDismiss = {},
                    onSave = { throw java.io.IOException("database unavailable") },
                )
            }
        }
        composeRule.onNodeWithText("Номер сессии *").performTextInput("Failure draft")
        Espresso.closeSoftKeyboard()
        composeRule.onNodeWithText("Аллюр/движение").performScrollTo().performClick()
        checkbox("Аллюр/движение").assertIsOn()
        composeRule.onNodeWithText("Validate and save").performClick()
        composeRule.waitUntil(timeoutMillis = 5_000) {
            composeRule.onNodeWithText("java.io.IOException: database unavailable").isDisplayed()
        }
        composeRule.onNodeWithText("java.io.IOException: database unavailable").assertIsDisplayed()
        composeRule.onNodeWithText("Session questionnaire").assertIsDisplayed()
        composeRule.onNodeWithText("Failure draft").performScrollTo().assertIsDisplayed()
    }

    @Test
    fun sheetSession_preservesMultipleSurfacesAcrossLocationChange() {
        var saved: com.example.myapplication.data.SessionQuestionnaire? = null
        composeRule.setContent {
            MaterialTheme {
                SessionQuestionnaireDialog(
                    language = AppLanguage.ENGLISH,
                    onDismiss = {},
                    onSave = { saved = it },
                )
            }
        }

        composeRule.onNodeWithText("Номер сессии *").performTextInput("2")
        Espresso.closeSoftKeyboard()
        composeRule.onNodeWithText("Аллюр/движение").performScrollTo().performClick()
        checkbox("Аллюр/движение").assertIsOn()
        composeRule.onNodeWithText("На улице").performScrollTo().performClick()
        composeRule.onNodeWithText("Асфальт").performScrollTo().performClick()
        checkbox("Асфальт").assertIsOn()
        composeRule.onNodeWithText("Трава").performScrollTo().performClick()
        checkbox("Асфальт").assertIsOn()
        checkbox("Трава").assertIsOn()
        composeRule.onNodeWithText("В помещении").performScrollTo().performClick()
        checkbox("Асфальт").assertIsOn()
        checkbox("Трава").assertIsOn()
        composeRule.onNodeWithText("Validate and save").performClick()
        composeRule.runOnIdle { assertEquals(listOf("Асфальт", "Трава"), saved?.surfaces) }
    }

    @Test
    fun sessionDraft_survivesSavedStateRestoration() {
        val restoration = StateRestorationTester(composeRule)
        restoration.setContent {
            MaterialTheme {
                SessionQuestionnaireDialog(
                    language = AppLanguage.ENGLISH,
                    onDismiss = {},
                    onSave = {},
                )
            }
        }
        composeRule.onNodeWithText("Номер сессии *").performTextInput("Draft session")

        restoration.emulateSavedInstanceStateRestore()

        composeRule.onNodeWithText("Draft session").assertIsDisplayed()
    }

    private fun setShellContent(
        uiState: DeviceUiState = DeviceUiState(),
        canShareAllFiles: Boolean = false,
        canSharePacketFile: Boolean = false,
        canShareCsvFile: Boolean = false,
        canShareRawFile: Boolean = false,
        canShareLogFile: Boolean = false,
        selectedThemeMode: AppThemeMode = AppThemeMode.SYSTEM,
        serverSyncState: ServerSyncUiState = ServerSyncUiState(),
        onShareAllFiles: () -> Unit = {},
        onSharePacketFile: () -> Unit = {},
        onShareCsvFile: () -> Unit = {},
        onShareRawFile: () -> Unit = {},
        onShareLogFile: () -> Unit = {},
        onThemeModeSelect: (AppThemeMode) -> Unit = {},
        openSession: Boolean = true,
    ) {
        composeRule.setContent {
            AppLocalizationProvider(
                language = AppLanguage.ENGLISH,
                textResolver = AppTextResolver(composeRule.activity) { AppLanguage.ENGLISH },
            ) {
                MaterialTheme {
                    Surface(modifier = Modifier.fillMaxSize()) {
                        DeviceAppShell(
                            uiState = uiState,
                            selectedLanguage = AppLanguage.ENGLISH,
                            selectedThemeMode = selectedThemeMode,
                            serverSyncState = serverSyncState,
                            onStartScan = {},
                            onConnect = {},
                            onTransportProfileSelect = {},
                            onLanguageSelect = {},
                            onThemeModeSelect = onThemeModeSelect,
                            onDisconnect = {},
                            onSensorSelect = {},
                            onChannelSelect = {},
                            onChartWindowSelect = {},
                            onFollowLiveChange = {},
                            onChartPanLeft = {},
                            onChartPanRight = {},
                            onChartZoomIn = {},
                            onChartZoomOut = {},
                            onChartZoomReset = {},
                            onChartPanGesture = { _ -> },
                            onChartZoomGesture = { _, _ -> },
                            canShareAllFiles = canShareAllFiles,
                            canSharePacketFile = canSharePacketFile,
                            canShareCsvFile = canShareCsvFile,
                            canShareRawFile = canShareRawFile,
                            canShareLogFile = canShareLogFile,
                            onShareAllFiles = onShareAllFiles,
                            onSharePacketFile = onSharePacketFile,
                            onShareCsvFile = onShareCsvFile,
                            onShareRawFile = onShareRawFile,
                            onShareLogFile = onShareLogFile,
                            showReplayAction = true,
                            onReplayRequest = {},
                        )
                    }
                }
            }
        }
        if (openSession) navTab("Session").performClick()
    }

    private fun checkbox(label: String) = composeRule.onNode(
        isToggleable() and hasAnySibling(hasText(label)),
        useUnmergedTree = true,
    )

    private fun chartControl(): SemanticsNodeInteraction {
        if (!composeRule.onNode(hasTestTag("session.charts")).isDisplayed()) navTab("Session").performClick()
        return composeRule.onNode(hasTestTag("session.charts"))
    }

    private fun navTab(label: String) = composeRule.onNode(
        hasText(label) and SemanticsMatcher.expectValue(
            androidx.compose.ui.semantics.SemanticsProperties.Role,
            androidx.compose.ui.semantics.Role.Tab,
        ),
    )
}

private fun SemanticsNodeInteraction.scrollToIfNeeded(): SemanticsNodeInteraction = apply {
    try {
        assertIsDisplayed()
    } catch (_: AssertionError) {
        performScrollTo()
    }
}
