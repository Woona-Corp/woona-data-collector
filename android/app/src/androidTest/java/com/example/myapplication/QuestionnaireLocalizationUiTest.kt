package com.example.myapplication

import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.example.myapplication.data.*
import com.example.myapplication.localization.AppLanguage
import com.example.myapplication.profile.*
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class QuestionnaireLocalizationUiTest {
    @get:Rule val compose = createComposeRule()

    @Test fun englishDogLabelsAndValidationDoNotTranslateAnswers() {
        var saved:DogQuestionnaire?=null
        compose.setContent { MaterialTheme { DogQuestionnaireDialog(null,false,AppLanguage.ENGLISH,{}, {saved=it}) } }
        compose.onNodeWithText("Validate and save").performClick()
        compose.onNodeWithText("Enter an animal ID (up to 100 characters)").assertExists()
        compose.onNodeWithText("Animal number/ID *").performTextInput("locale-id")
        compose.onNodeWithText("Name *").performTextInput("Активность")
        listOf("Species","Shelter/camp/collection site","Breed","If mixed breed — similar breed/type","Size","Age, years","Age, months","Age information source","Sex","Neutered/spayed","Weight, kg","Weight information source","BCS (1-9)","Muscle mass assessment","Neck circumference, cm","Coat length","Undercoat","Clipped/shaved areas","Where and why the coat was clipped","Veterinary diagnoses","Diagnoses (description)","Confirmed disease category","Disease category — other details","Chronic lameness/joint problems","Regular medications and doses","History/important comments","Housing","Housing — other details","Walks (frequency and duration)","Living with other animals","Recording permission","Notes","Recording specialist's full name").forEach(::see)
        compose.onNodeWithText("Small").performScrollTo().performClick()
        compose.onNodeWithText("Validate and save").performClick()
        compose.runOnIdle { assertEquals("Активность",saved?.numberOrName);assertEquals("мелкий",saved?.size);assertEquals("собака",saved?.species) }
    }

    @Test fun englishSessionDisplaysAllSectionsAndKeepsCanonicalSheetOptions() {
        var saved:SessionQuestionnaire?=null
        compose.setContent { MaterialTheme { SessionQuestionnaireDialog(AppLanguage.ENGLISH,{}, {saved=it}) } }
        compose.onNodeWithText("Session number *").performTextInput("EN session")
        listOf("Session type","Session date (YYYY-MM-DD)","Recording start time (HH:MM, for import)","End time (HH:MM, for import)","Actual duration, min (for import)","Recording operator","Planned recording activities *").forEach(::see)
        compose.onNodeWithText("Gait/movement").performScrollTo().performClick()
        listOf("Recording format — other details","Session location","Surface","Surface — other details","Air temperature, °C","Sensor unit position","Sensor unit position — other details","Collar tightness","Animal's state before recording","State before recording — other details","Last medication time (heart rate/breathing/activity)","Notes","Recording specialist's full name","Record video").forEach(::see)
        compose.onNodeWithText("Asphalt").performScrollTo().performClick()
        compose.onNodeWithText("Validate and save").performClick()
        compose.runOnIdle { assertEquals(listOf("Аллюр/движение"),saved?.plannedActivities);assertEquals(listOf("Асфальт"),saved?.surfaces) }
    }

    @Test fun replayQuestionnaireHidesVideoAndForcesItOff() {
        var saved: SessionQuestionnaire? = null
        compose.setContent { MaterialTheme { SessionQuestionnaireDialog(AppLanguage.ENGLISH, {}, { saved = it }, videoAllowed = false) } }
        compose.onNodeWithText("Record video").assertDoesNotExist()
        compose.onNodeWithText("Session number *").performTextInput("Replay no video")
        compose.onNodeWithText("Gait/movement").performScrollTo().performClick()
        compose.onNodeWithText("Validate and save").performClick()
        compose.runOnIdle { assertEquals(false, saved?.videoRequested); assertEquals(listOf("Аллюр/движение"), saved?.plannedActivities) }
    }

    @Test fun englishHeartSectionsOptionsAndRawTextsRemainDistinct() {
        val original=HeartQuestionnaire(mapOf("knownHeartCondition" to "yes","heartRelevantMedication" to "yes","preRecordingState" to "sleeping","actualActivity" to "rest","referenceMethod" to "bpm_only"),listOf("none"),referenceBpm=90.0,referenceMeasuredAtUtc="2026-10-29T10:00:00Z")
        var saved:HeartQuestionnaire?=null
        compose.setContent { MaterialTheme { HeartQuestionnaireDialog(AppLanguage.ENGLISH,original,{}, {saved=it}) } }
        see("Activity and heart questionnaire")
        listOf("1. Heart and medication information","1.1. Has a veterinarian diagnosed heart disease or a rhythm disorder? *","Diagnosis (optional)","1.2. Has the dog taken medication that may affect heart rate? *","Medication name and last dose time (optional)","2. Recording conditions","2.1. What was the dog doing immediately before recording? *","2.2. What was the dog actually doing during recording? *","2.3. Were there factors during recording that could affect heart rate? *","3. Reference measurement","3.1. Is there an independent heart measurement for the same period? *","Measured heart rate, bpm *","Measurement time (UTC, YYYY-MM-DDTHH:MM:SSZ) *").forEach(::see)
        compose.onNodeWithText("Validate and save").performClick()
        compose.runOnIdle { assertEquals(original.toJson().toString(),saved?.toJson()?.toString());assertEquals("Да",saved?.toJson()?.getJSONObject("knownHeartCondition")?.getString("text")) }
    }

    @Test fun englishReferenceFormErrorsAndExplanationsAreLocalized() {
        compose.setContent { MaterialTheme { ReferenceAttachmentDialog(AppLanguage.ENGLISH,"synthetic.csv",{}, {_,_->error("Invalid form must not save")}) } }
        listOf("Add reference recording","Data type *","ECG","Heart rate","Beat-to-beat intervals (Polar, etc.)","Device / source *","Reference recording start UTC * (YYYY-MM-DDTHH:MM:SSZ)","Reference recording end UTC *","Target UTC offset, ms (added to its timestamps, if known)","Time alignment / notes").forEach(::see)
        compose.onNodeWithText("Validate and save").performClick()
        see("Enter a device/source (up to 200 characters)")
    }

    private fun see(label:String) { val node=compose.onNodeWithText(label); if(runCatching { node.assertIsDisplayed() }.isFailure) node.performScrollTo(); node.assertIsDisplayed() }
}
