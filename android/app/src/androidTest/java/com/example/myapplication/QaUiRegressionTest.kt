package com.example.myapplication

import android.content.pm.ActivityInfo
import android.content.Context
import android.view.View
import android.view.inputmethod.InputMethodManager
import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.text.TextLayoutResult
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.example.myapplication.data.HeartQuestionnaire
import com.example.myapplication.data.HEART_OPTIONS
import com.example.myapplication.localization.AppLanguage
import com.example.myapplication.profile.HeartQuestionnaireDialog
import com.example.myapplication.profile.SessionQuestionnaireDialog
import com.example.myapplication.sync.ServerSettings
import com.example.myapplication.sync.ServerSettingsDialog
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class QaUiRegressionTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    private fun readableAction(text: String, scroll: Boolean = false) {
        val node = compose.onNodeWithText(text)
        if (scroll) node.performScrollTo()
        node.assertIsDisplayed()
        val layouts = mutableListOf<TextLayoutResult>()
        node.performSemanticsAction(androidx.compose.ui.semantics.SemanticsActions.GetTextLayoutResult) { it(layouts) }
        assertTrue("$text must have measured text", layouts.isNotEmpty())
        // Text's integer pixel size can be rounded down by <1px; didOverflowWidth
        // alone therefore flags ordinary short labels. Measure actual line bounds.
        assertTrue("$text glyphs must fit the measured text bounds", layouts.all { result ->
            (0 until result.lineCount).all { line ->
                !result.isLineEllipsized(line) && result.getLineRight(line) <= result.size.width + 1f &&
                    result.getLineBottom(line) <= result.size.height + 1f
            }
        })
        val button = compose.onNode(hasText(text) and hasClickAction())
        assertTrue("$text touch target >=48dp", button.fetchSemanticsNode().boundsInRoot.height >= with(compose.activity.resources.displayMetrics) { 48 * density } - 1)
    }

    @Test fun visibleHeartDiagnosisHasInlineError() {
        val initial = HeartQuestionnaire(answers = HEART_OPTIONS.keys.filter { it != "acuteHeartRateFactors" }.associateWith { "unknown" } + ("knownHeartCondition" to "yes"), acuteHeartRateFactors = listOf("unknown"), knownHeartConditionDetails = "x".repeat(2001))
        compose.setContent { MaterialTheme { HeartQuestionnaireDialog(AppLanguage.ENGLISH, initial, {}, {}) } }
        compose.onNodeWithText("Validate and save").performClick()
        compose.onNodeWithText("Maximum 2000 characters").performScrollTo().assertIsDisplayed()
    }

    @Test fun landscapeServerActionsHaveReadableLabels() {
        compose.activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
        compose.waitUntil(10_000) { val v = compose.activity.findViewById<View>(android.R.id.content); v.width > v.height }
        compose.setContent { MaterialTheme {
            ServerSettingsDialog(ServerSettings("https://example.invalid", "", "qa-device", true), AppLanguage.ENGLISH, {}, { _, _ -> })
        } }
        readableAction("Cancel")
        readableAction("Save")
    }

    @Test fun portraitNotesRegularImeKeepsHeaderAndActionsVisible() {
        compose.activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        compose.waitUntil(10_000) { val v = compose.activity.findViewById<View>(android.R.id.content); v.height > v.width }
        compose.setContent { MaterialTheme { SessionQuestionnaireDialog(AppLanguage.ENGLISH, {}, {}, videoAllowed = false) } }
        compose.onNodeWithText("Notes").performScrollTo().performClick().performTextInput("Long notes\n".repeat(20))
        val ime = compose.activity.getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager
        compose.waitUntil(10_000) { ime.isAcceptingText }
        Thread.sleep(1000)
        assertFalse("Regression requires regular, not extract IME", ime.isFullscreenMode)
        compose.onNodeWithText("Session questionnaire").assertIsDisplayed()
        readableAction("Cancel")
        readableAction("Validate and save")
        androidx.test.espresso.Espresso.closeSoftKeyboard()
    }
}
