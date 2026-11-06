package com.example.myapplication

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.platform.app.InstrumentationRegistry
import com.example.myapplication.localization.AppLanguage
import com.example.myapplication.localization.AppLanguagePreferences
import org.junit.Rule
import org.junit.Test

class ServerSettingsDraftRecreationTest {
    @get:Rule val compose = createEmptyComposeRule()
    @Test fun draftSurvivesRecreationButCancelClearsIt() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        AppLanguagePreferences(context).setSelectedLanguage(AppLanguage.ENGLISH)
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            compose.waitUntil(30_000) { compose.onAllNodesWithTag("tab.settings").fetchSemanticsNodes().isNotEmpty() }
            // Fresh isolated app may initially require a dog questionnaire.
            if (compose.onAllNodesWithText("Cancel").fetchSemanticsNodes().isNotEmpty()) compose.onNodeWithText("Cancel").performClick()
            compose.onNodeWithTag("tab.settings").performClick()
            compose.onNode(hasScrollAction()).performScrollToNode(hasText("Server storage"))
            compose.onNode(hasText("Connect") or hasText("Reconnect")).performScrollTo().performClick()
            compose.onNodeWithText("Server URL").performTextReplacement("https://draft.invalid")
            compose.onNodeWithText("New token").performTextInput("synthetic-draft-only")
            androidx.test.espresso.Espresso.closeSoftKeyboard()
            scenario.recreate()
            compose.waitUntil(30_000) { compose.onAllNodesWithText("New token").fetchSemanticsNodes().isNotEmpty() }
            compose.onNodeWithText("Server URL").assertTextContains("https://draft.invalid")
            // Password semantics must remain masked; inspect only our synthetic draft
            // in its in-memory owner to verify the exact bytes survived recreation.
            compose.onNodeWithText("New token").assertTextContains("•".repeat("synthetic-draft-only".length))
            scenario.onActivity { activity ->
                org.junit.Assert.assertEquals("synthetic-draft-only", androidx.lifecycle.ViewModelProvider(activity)[com.example.myapplication.sync.ServerSettingsDraftViewModel::class.java].open("").token)
            }
            compose.onNodeWithText("Cancel").assertIsDisplayed().performClick()
            compose.onNodeWithTag("tab.settings").performClick()
            compose.onNode(hasScrollAction()).performScrollToNode(hasText("Server storage"))
            compose.onNode(hasText("Connect") or hasText("Reconnect")).performScrollTo().performClick()
            compose.onNodeWithText("New token").assert(SemanticsMatcher.expectValue(androidx.compose.ui.semantics.SemanticsProperties.EditableText, androidx.compose.ui.text.AnnotatedString("")))
            compose.onNodeWithText("Server URL").assert(SemanticsMatcher("draft URL was cleared") {
                it.config.getOrElse(androidx.compose.ui.semantics.SemanticsProperties.EditableText) { androidx.compose.ui.text.AnnotatedString("") }.text != "https://draft.invalid"
            })
            compose.onNodeWithText("Cancel").assertIsDisplayed().performClick()
        }
    }
}
