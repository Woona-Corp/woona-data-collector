package com.example.myapplication

import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import com.example.myapplication.localization.AppLanguage
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class AccountControlsUiTest {
    @get:Rule val compose = createComposeRule()

    @Test fun dataScopeIsNotLoginAndUnappliedDraftDoesNotChangeActiveScope() {
        var requested: String? = null
        val diagnostic = "Local history fixture: one hidden card; originals retained"
        compose.setContent { MaterialTheme {
            AccountControls("active-fixture", AppLanguage.ENGLISH, true, emptyList(),
                onApply = { requested = it }, onLink = {}, localHistorySummary = diagnostic)
        } }
        compose.onNodeWithText("Data account").assertExists()
        compose.onNodeWithText("Data scope, not sign-in. Empty means unassigned.").assertExists()
        compose.onNodeWithText(diagnostic).assertDoesNotExist()
        compose.onNode(hasSetTextAction()).performTextClearance()
        compose.onNode(hasSetTextAction()).performTextInput("draft-fixture")
        compose.onNodeWithText("Apply account").performClick()
        assertEquals("draft-fixture", requested)
        compose.onNodeWithText("Active scope: active-fixture").assertExists()
        compose.onNodeWithText("draft-fixture").assertExists()
        compose.onNodeWithText("+ Data scope details").performClick()
        compose.onNodeWithText(diagnostic).assertExists()
    }
}
