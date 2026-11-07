package com.example.myapplication

import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.example.myapplication.sync.SyncDetails
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class SyncDetailsUiTest {
    @get:Rule val compose = createComposeRule()

    @Test fun technicalEvidenceIsCollapsedSelectableAndRedacted() {
        compose.setContent { MaterialTheme { SyncDetails("Details", "HTTP 409 request-id=fixture Authorization: Bearer private-fixture") } }
        compose.onNodeWithText("HTTP 409", substring = true).assertDoesNotExist()
        compose.onNodeWithText("+ Details").performClick()
        compose.onNodeWithText("HTTP 409 request-id=fixture Authorization: [redacted]").assertExists()
        compose.onNodeWithText("private-fixture", substring = true).assertDoesNotExist()
        compose.onNodeWithText("− Details").performClick()
        compose.onNodeWithText("HTTP 409", substring = true).assertDoesNotExist()
    }
    @Test fun duplicateAnimalIdIsInlineAndKeepsTheDraftOpen() {
        val conflict = com.example.myapplication.data.LocalAnimalIdentityConflict("fixture-11119", "00000000-0000-0000-0000-000000000001", "Existing fixture dog", "fixture-account")
        compose.setContent { MaterialTheme {
            com.example.myapplication.profile.DogQuestionnaireDialog(
                initial = null, required = false,
                language = com.example.myapplication.localization.AppLanguage.ENGLISH,
                activeAccountId = "fixture-account", onDismiss = {}, onSave = { throw conflict },
            )
        } }
        compose.onAllNodes(hasSetTextAction())[0].performTextInput("fixture-11119")
        compose.onAllNodes(hasSetTextAction())[1].performTextInput("My retained draft")
        compose.onNodeWithText("Validate and save").performClick()
        compose.onNodeWithText("Existing fixture dog", substring = true).assertExists()
        compose.onNodeWithText("fixture-11119").assertExists()
        compose.onNodeWithText("My retained draft").assertExists()
        compose.onNodeWithText("Cancel").assertExists()
    }

    @Test fun unknownProfileStatusDoesNotClaimServerAcceptance() {
        compose.setContent { MaterialTheme {
            com.example.myapplication.profile.ProfileSyncStatus(null, com.example.myapplication.localization.AppLanguage.ENGLISH)
        } }
        compose.onNodeWithText("Profile delivery has not been confirmed").assertExists()
        compose.onNodeWithText("This profile version was accepted by the server").assertDoesNotExist()
    }

    @Test fun profileConflictOffersRecoveryWithoutNamingAnUnknownAnimal() {
        compose.setContent { MaterialTheme {
            com.example.myapplication.profile.ProfileSyncStatus(
                com.example.myapplication.profile.ProfileSyncUiStatus("permanent_error", "animal_id_already_exists", "raw-evidence"),
                com.example.myapplication.localization.AppLanguage.ENGLISH,
            )
        } }
        compose.onNodeWithText("Needs attention · profile not accepted").assertExists()
        compose.onNodeWithText("Restore profiles from server", substring = true).assertExists()
        compose.onNodeWithText("raw-evidence", substring = true).assertDoesNotExist()
    }

}
