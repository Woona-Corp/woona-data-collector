package com.example.myapplication

import android.view.WindowManager
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performTextInput
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.example.myapplication.data.DogQuestionnaire
import com.example.myapplication.data.WoonaDatabase
import com.example.myapplication.localization.AppLanguage
import com.example.myapplication.localization.AppLanguagePreferences
import org.junit.Rule
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MainActivityRecreationTest {
    @get:Rule
    val composeRule = createEmptyComposeRule()

    @Test
    fun keepScreenOn_survivesActivityRecreation() {
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            scenario.onActivity { activity ->
                assertTrue(activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON != 0)
            }

            scenario.recreate()

            scenario.onActivity { activity ->
                assertTrue(activity.window.attributes.flags and WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON != 0)
            }
        }
    }

    @Test
    fun openSessionQuestionnaireAndDraft_surviveActivityRecreation() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        AppLanguagePreferences(context).setSelectedLanguage(AppLanguage.ENGLISH)
        val profile = WoonaDatabase(context).use { database ->
            database.saveProfile(completeDogQuestionnaire())
        }
        context.getSharedPreferences("woona_profiles", android.content.Context.MODE_PRIVATE)
            .edit().putString("last_profile_id", profile.id).commit()

        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            composeRule.onNode(
                hasText("Session") and SemanticsMatcher.expectValue(
                    androidx.compose.ui.semantics.SemanticsProperties.Role,
                    androidx.compose.ui.semantics.Role.Tab,
                ),
            ).performClick()
            composeRule.onNodeWithText("New connection").performClick()
            composeRule
                .onNodeWithText("Upload binary (debug)")
                .performScrollTo()
                .performClick()
            composeRule
                .onNodeWithText("Номер сессии *")
                .performTextInput("Lifecycle draft")

            scenario.recreate()

            composeRule.onNodeWithText("Session questionnaire").assertIsDisplayed()
            composeRule.onNodeWithText("Lifecycle draft").assertIsDisplayed()
        }
    }

    private fun completeDogQuestionnaire() = DogQuestionnaire(
        numberOrName = "Lifecycle dog",
        shelterOrPlace = "Test shelter",
        breedStatus = "unknown",
        size = "medium",
        ageStatus = "unknown",
        ageSource = "unknown",
        sex = "unknown",
        sterilizationStatus = "unknown",
        weightStatus = "unknown",
        bodyConditionStatus = "unable",
        muscleMass = "unable",
        neckCircumferenceStatus = "not_measured",
        coatLength = "unknown",
        undercoat = "unknown",
        shavedAreasStatus = "unknown",
        observedSigns = listOf("none"),
        diagnosesStatus = "unknown",
        housing = "unknown",
        walksStatus = "unknown",
        cohabitants = "unknown",
        shelterPermission = "unknown",
        notesStatus = "none",
    )
}
