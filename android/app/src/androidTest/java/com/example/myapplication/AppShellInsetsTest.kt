package com.example.myapplication

import android.content.pm.ActivityInfo
import android.view.View
import android.view.WindowInsets
import androidx.activity.ComponentActivity
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.hasAnyAncestor
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.core.view.WindowCompat
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.example.myapplication.feature.device.ChartUiState
import com.example.myapplication.feature.device.DeviceUiState
import com.example.myapplication.localization.AppLanguage
import com.example.myapplication.localization.AppLocalizationProvider
import com.example.myapplication.localization.AppTextResolver
import com.example.myapplication.profile.SessionQuestionnaireDialog
import com.example.myapplication.ui.theme.AppThemeMode
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.max

private const val CHART_FULLSCREEN_CONTROLS_TEST_TAG = "chart_fullscreen_controls"

@RunWith(AndroidJUnit4::class)
class AppShellInsetsTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<ComponentActivity>()

    @Before
    fun setUp() {
        composeRule.activityRule.scenario.onActivity { activity ->
            WindowCompat.setDecorFitsSystemWindows(activity.window, false)
        }
    }

    @Test
    fun topBarTitle_staysBelowTopSystemInsets() {
        setShellContent()

        composeRule.waitForIdle()

        val titleBounds = composeRule
            .onAllNodesWithText("Animals")
            .fetchSemanticsNodes()
            .minByOrNull { it.boundsInRoot.top }
            ?.boundsInRoot
            ?: error("Overview title node was not found")
        val topInset = topSafeInsetPx()

        assertTrue(
            "Expected title top ${titleBounds.top} to be below top inset $topInset",
            titleBounds.top >= topInset,
        )
    }

    @Test
    fun bottomNav_staysAboveBottomSystemInsets() {
        setShellContent()

        composeRule.waitForIdle()

        val settingsBounds = composeRule
            .onNodeWithText("Settings")
            .assertExists()
            .fetchSemanticsNode()
            .boundsInRoot
        val rootHeight = composeRule.activity.findViewById<View>(android.R.id.content).height.toFloat()
        val bottomInset = bottomSystemInsetPx()

        assertTrue(
            "Expected nav item bottom ${settingsBounds.bottom} to be above bottom-safe bound ${rootHeight - bottomInset}",
            settingsBounds.bottom <= rootHeight - bottomInset,
        )
    }

    @Test
    fun sessionQuestionnaire_videoChoice_staysAboveBottomSystemInsets() {
        composeRule.setContent {
            MaterialTheme {
                SessionQuestionnaireDialog(
                    language = AppLanguage.ENGLISH,
                    onDismiss = {},
                    onSave = {},
                )
            }
        }

        val noBounds = composeRule
            .onNodeWithText("No")
            .performScrollTo()
            .assertIsDisplayed()
            .fetchSemanticsNode()
            .boundsInRoot
        val rootHeight = composeRule.activity.findViewById<View>(android.R.id.content).height.toFloat()

        assertTrue(
            "Expected video choice bottom ${noBounds.bottom} to be above bottom-safe bound ${rootHeight - bottomSystemInsetPx()}",
            noBounds.bottom <= rootHeight - bottomSystemInsetPx(),
        )
    }

    @Test
    fun chartControls_stayWithinViewportWidth() {
        setShellContent(
            uiState = DeviceUiState(
                showCaptureUi = true,
                chart = ChartUiState(
                    canPanLeft = true,
                    canPanRight = true,
                    canZoomIn = true,
                    canZoomOut = true,
                ),
            ),
        )

        composeRule.onNode(hasTestTag("tab.session")).performClick()
        composeRule.onNode(hasTestTag("session.charts")).performClick()
        composeRule.waitUntil(timeoutMillis = 5_000) {
            composeRule.onAllNodesWithText("900k").fetchSemanticsNodes().isNotEmpty() &&
                composeRule.onAllNodesWithText("Y Reset").fetchSemanticsNodes().isNotEmpty()
        }

        val rootWidth = composeRule.activity.findViewById<View>(android.R.id.content).width.toFloat()
        val presetBounds = composeRule.onNodeWithText("900k").assertExists().fetchSemanticsNode().boundsInRoot
        val resetBounds = composeRule.onNodeWithText("Y Reset").assertExists().fetchSemanticsNode().boundsInRoot

        assertTrue(
            "Expected preset chip right edge ${presetBounds.right} to stay within root width $rootWidth",
            presetBounds.right <= rootWidth,
        )
        assertTrue(
            "Expected reset button right edge ${resetBounds.right} to stay within root width $rootWidth",
            resetBounds.right <= rootWidth,
        )
    }

    @Test
    fun fullscreenChartControls_stayWithinViewportWidth() {
        setShellContent(
            uiState = DeviceUiState(
                showCaptureUi = true,
                chart = ChartUiState(
                    canPanLeft = true,
                    canPanRight = true,
                    canZoomIn = true,
                    canZoomOut = true,
                ),
            ),
        )

        composeRule.onNode(hasTestTag("tab.session")).performClick()
        composeRule.onNode(hasTestTag("session.charts")).performClick()
        composeRule.onNodeWithContentDescription("Open fullscreen chart").performClick()
        composeRule.onNodeWithText("Fullscreen chart").assertExists()
        val fullscreenControlMatcher = hasAnyAncestor(hasTestTag(CHART_FULLSCREEN_CONTROLS_TEST_TAG))
        composeRule.waitUntil(timeoutMillis = 5_000) {
            composeRule
                .onAllNodes(
                    hasText("900k") and fullscreenControlMatcher,
                    useUnmergedTree = true,
                )
                .fetchSemanticsNodes()
                .isNotEmpty() &&
                composeRule
                    .onAllNodes(
                        hasText("Y Reset") and fullscreenControlMatcher,
                        useUnmergedTree = true,
                    )
                    .fetchSemanticsNodes()
                    .isNotEmpty()
        }

        val rootWidth = composeRule.activity.findViewById<View>(android.R.id.content).width.toFloat()
        val controlBounds = composeRule
            .onAllNodes(
                hasText("900k") and fullscreenControlMatcher,
                useUnmergedTree = true,
            )
            .fetchSemanticsNodes()
            .map { it.boundsInRoot } +
            composeRule
                .onAllNodes(
                    hasText("Y Reset") and fullscreenControlMatcher,
                    useUnmergedTree = true,
                )
                .fetchSemanticsNodes()
                .map { it.boundsInRoot }

        assertTrue("Expected fullscreen controls to be present", controlBounds.isNotEmpty())
        controlBounds.forEach { bounds ->
            assertTrue(
                "Expected fullscreen control right edge ${bounds.right} to stay within root width $rootWidth",
                bounds.right <= rootWidth,
            )
        }
    }

    @Test
    fun chartControls_areReachableInLandscape() {
        composeRule.activity.requestedOrientation =
            ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        composeRule.waitUntil(timeoutMillis = 10_000) {
            val content = composeRule.activity.findViewById<View>(android.R.id.content)
            content.width > content.height
        }
        setShellContent(
            uiState = DeviceUiState(
                showCaptureUi = true,
                chart = ChartUiState(
                    canPanLeft = true,
                    canPanRight = true,
                    canZoomIn = true,
                    canZoomOut = true,
                ),
            ),
        )

        composeRule.onNode(hasTestTag("tab.session")).performClick()
        composeRule.onNode(hasTestTag("session.charts")).performClick()
        composeRule.onNodeWithText("Y Reset").performScrollTo().assertIsDisplayed()
        composeRule
            .onNodeWithText("No data for the selected sensor/channel")
            .performScrollTo()
            .assertIsDisplayed()
    }

    private fun setShellContent(
        uiState: DeviceUiState = DeviceUiState(),
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
                            selectedThemeMode = AppThemeMode.SYSTEM,
                            onStartScan = {},
                            onConnect = {},
                            onTransportProfileSelect = {},
                            onLanguageSelect = {},
                            onThemeModeSelect = {},
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
                            canShareAllFiles = false,
                            canSharePacketFile = false,
                            canShareCsvFile = false,
                            canShareRawFile = false,
                            canShareLogFile = false,
                            onShareAllFiles = {},
                            onSharePacketFile = {},
                            onShareCsvFile = {},
                            onShareRawFile = {},
                            onShareLogFile = {},
                            showReplayAction = true,
                            onReplayRequest = {},
                        )
                    }
                }
            }
        }
    }

    private fun topSafeInsetPx(): Int {
        val insets = requireWindowInsets()
        val systemBarTop = insets.getInsets(WindowInsets.Type.systemBars()).top
        val cutoutTop = insets.displayCutout?.safeInsetTop ?: 0
        return max(systemBarTop, cutoutTop)
    }

    private fun bottomSystemInsetPx(): Int {
        return requireWindowInsets().getInsets(WindowInsets.Type.systemBars()).bottom
    }

    private fun requireWindowInsets(): WindowInsets {
        return composeRule.runOnIdle {
            composeRule.activity.window.decorView.rootWindowInsets
                ?: error("Root window insets were not available")
        }
    }
}
