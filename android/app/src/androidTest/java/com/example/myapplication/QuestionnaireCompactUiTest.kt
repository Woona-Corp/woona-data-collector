package com.example.myapplication

import android.content.pm.ActivityInfo
import android.view.View
import android.view.accessibility.AccessibilityWindowInfo
import androidx.activity.ComponentActivity
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.example.myapplication.data.SessionQuestionnaire
import com.example.myapplication.localization.AppLanguage
import com.example.myapplication.profile.SessionQuestionnaireDialog
import com.example.myapplication.sync.QuestionnaireRevisionConflict
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class QuestionnaireCompactUiTest {
    @get:Rule val compose = createAndroidComposeRule<ComponentActivity>()

    @Test fun landscapeConflictKeepsFormAndDraftReachable() {
        val orientation = compose.activity.requestedOrientation
        val content = compose.activity.findViewById<View>(android.R.id.content)
        val wasPortrait = content.height > content.width
        try {
            compose.activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
            compose.waitUntil(10_000) {
                val view = compose.activity.findViewById<View>(android.R.id.content)
                view.width > view.height
            }
            val heightDp = compose.activity.findViewById<View>(android.R.id.content).height /
                compose.activity.resources.displayMetrics.density
            assumeTrue("This regression requires a compact landscape viewport (height <= 500dp), got $heightDp", heightDp <= 500f)
            val draft = SessionQuestionnaire(schemaVersion = 2, sessionLabel = "Compact draft", plannedActivities = listOf("Покой"))
            var saved: SessionQuestionnaire? = null
            var savedRevision: Int? = null
            compose.setContent { MaterialTheme {
                SessionQuestionnaireDialog(
                    AppLanguage.ENGLISH, onDismiss = {}, onSave = {}, initial = draft,
                    onSaveAtRevision = { answers, revision ->
                        if (revision == null) throw QuestionnaireRevisionConflict(draft.copy(sessionLabel = "Compact server"), 5)
                        saved = answers
                        savedRevision = revision
                    },
                )
            } }
            compose.onNodeWithText("Validate and save").performClick()
            compose.onNodeWithText("HTTP 409:", substring = true).performScrollTo().assertIsDisplayed()
            // The conflict must not consume the viewport: the form is reachable before resolving it.
            compose.onNodeWithText("Compact draft").performScrollTo().assertIsDisplayed()
            compose.onNodeWithText("Load server answers and retain my draft").performScrollTo().performClick()
            compose.onNodeWithText("Compact server").performScrollTo().assertIsDisplayed()
            compose.onNodeWithText("Restore my edits").performScrollTo().performClick()
            compose.onNodeWithText("Compact draft").performScrollTo().assertIsDisplayed()
            compose.onNodeWithText("Validate and save").performClick()
            compose.runOnIdle {
                assertEquals("Compact draft", saved?.sessionLabel)
                assertEquals(5, savedRevision)
            }
        } finally {
            compose.activity.restoreTestOrientation(orientation)
            if (wasPortrait) compose.waitUntil(10_000) {
                val view = compose.activity.findViewById<View>(android.R.id.content)
                view.height > view.width
            }
        }
    }

    @Test fun landscapeKeyboardDoesNotHideFormControls() {
        val orientation = compose.activity.requestedOrientation
        val initial = compose.activity.findViewById<View>(android.R.id.content)
        val wasPortrait = initial.height > initial.width
        val automation = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().uiAutomation
        val originalFlags = automation.serviceInfo.flags
        var primaryFailure: Throwable? = null
        try {
            automation.serviceInfo = automation.serviceInfo.apply {
                flags = flags or android.accessibilityservice.AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
            }
            compose.activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE
            compose.waitUntil(10_000) {
                val view = compose.activity.findViewById<View>(android.R.id.content)
                view.width > view.height
            }
            val heightDp = compose.activity.findViewById<View>(android.R.id.content).height /
                compose.activity.resources.displayMetrics.density
            assumeTrue("Compact landscape viewport required, got $heightDp dp", heightDp <= 500f)
            var saved: SessionQuestionnaire? = null
            compose.setContent { MaterialTheme {
                SessionQuestionnaireDialog(AppLanguage.ENGLISH, onDismiss = {}, onSave = { saved = it }, videoAllowed = false)
            } }
            compose.onNodeWithText("Session number *").performTextInput("Compact keyboard")
            compose.waitUntil(10_000) { automation.windows.any { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD } }
            Thread.sleep(1_000) // Let the platform keyboard's window and inset animation settle.
            val input = compose.activity.getSystemService(android.content.Context.INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager
            val fullscreenIme = input.isFullscreenMode
            android.util.Log.i("WoonaCompactUi", "landscape fullscreen IME=$fullscreenIme")
            // A fullscreen IME intentionally replaces the app window; the user
            // must finish editing before the form can receive touches.
            if (fullscreenIme) androidx.test.espresso.Espresso.closeSoftKeyboard()
            val gait = compose.onNodeWithText("Gait/movement").performScrollTo()
            val bounds = gait.fetchSemanticsNode().boundsInRoot
            val viewport = compose.onNodeWithTag("questionnaire.scroll").fetchSemanticsNode().boundsInRoot
            assertTrue("The control must occupy the scroll viewport above the IME", bounds.width > 0f && bounds.height > 0f && bounds.overlaps(viewport))
            // Verify actual touch delivery and saved values; Android's window-level
            // isDisplayed check can report false while the IME owns focus.
            gait.performClick()
            compose.onNodeWithText("Validate and save").performClick()
            compose.waitUntil(10_000) { saved != null }
            compose.runOnIdle {
                assertEquals("Compact keyboard", saved?.sessionLabel)
                assertEquals(listOf("Аллюр/движение"), saved?.plannedActivities)
                assertEquals(false, saved?.videoRequested)
            }
        } catch (primary: Throwable) {
            primaryFailure = primary
            UiStopTrace.primary("Compact.landscape", primary)
            throw primary
        } finally {
            UiStopTrace.beforeClose("Compact.landscape")
            restoreUiTestState(primaryFailure,
                { androidx.test.espresso.Espresso.closeSoftKeyboard() },
                { automation.serviceInfo = automation.serviceInfo.apply { flags = originalFlags } },
                {
                    compose.activity.restoreTestOrientation(orientation)
                    if (wasPortrait) compose.waitUntil(10_000) {
                        val view = compose.activity.findViewById<View>(android.R.id.content)
                        view.height > view.width
                    }
                },
            )
        }
    }

    @Test fun portraitKeyboardKeepsFormControlsReachable() {
        val orientation = compose.activity.requestedOrientation
        val initial = compose.activity.findViewById<View>(android.R.id.content)
        val wasLandscape = initial.width > initial.height
        val automation = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().uiAutomation
        val originalFlags = automation.serviceInfo.flags
        var primaryFailure: Throwable? = null
        try {
            automation.serviceInfo = automation.serviceInfo.apply {
                flags = flags or android.accessibilityservice.AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS
            }
            compose.activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            compose.waitUntil(10_000) {
                val view = compose.activity.findViewById<View>(android.R.id.content)
                view.height > view.width
            }
            var saved: SessionQuestionnaire? = null
            compose.setContent { MaterialTheme {
                SessionQuestionnaireDialog(AppLanguage.ENGLISH, onDismiss = {}, onSave = { saved = it }, videoAllowed = false)
            } }
            compose.onNodeWithText("Session number *").performTextInput("Portrait keyboard")
            compose.waitUntil(10_000) { automation.windows.any { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD } }
            val input = compose.activity.getSystemService(android.content.Context.INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager
            assumeTrue("IME runs in fullscreen extract mode", !input.isFullscreenMode)
            compose.onNodeWithText("Gait/movement").performScrollTo().assertIsDisplayed().performClick()
            compose.onNodeWithText("Validate and save").assertIsDisplayed().performClick()
            compose.waitUntil(10_000) { saved != null }
            compose.runOnIdle {
                assertEquals("Portrait keyboard", saved?.sessionLabel)
                assertEquals(listOf("Аллюр/движение"), saved?.plannedActivities)
            }
        } catch (primary: Throwable) {
            primaryFailure = primary
            UiStopTrace.primary("Compact.portrait", primary)
            throw primary
        } finally {
            UiStopTrace.beforeClose("Compact.portrait")
            restoreUiTestState(primaryFailure,
                { androidx.test.espresso.Espresso.closeSoftKeyboard() },
                { automation.serviceInfo = automation.serviceInfo.apply { flags = originalFlags } },
                {
                    compose.activity.restoreTestOrientation(orientation)
                    if (wasLandscape) compose.waitUntil(10_000) {
                        val view = compose.activity.findViewById<View>(android.R.id.content)
                        view.width > view.height
                    }
                },
            )
        }
    }
}
