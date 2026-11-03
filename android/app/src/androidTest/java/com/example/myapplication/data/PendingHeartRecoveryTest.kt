package com.example.myapplication.data

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import android.content.Context
import java.io.File
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PendingHeartRecoveryTest {
    @Test fun recoveryPersistsOnlyUnfinishedUnansweredHeartsAndSurvivesRestartAndDismissal() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val root = File(context.cacheDir, "heart-recovery-${System.nanoTime()}")
        val prompts = PendingHeartPrompts(context)
        val ids = mutableListOf<String>()
        var db = WoonaDatabase(context, root)
        try {
            val dog = db.saveProfile(completeDogQuestionnaire("Synthetic recovery"))
            fun create(kind: String): Recording = db.beginRecording(dog.id, RecordingSource.LIVE,
                SessionQuestionnaire(schemaVersion = 2, sessionLabel = "Synthetic", sessionKind = kind,
                    plannedActivities = if (kind == "heart") emptyList() else listOf("Покой"), videoRequested = false)).also { ids += it.id }
            val active = create("heart")
            db.markRecording(active.id)
            val preparing = create("heart")
            val unrelated = create("activity")
            val old = create("heart")
            db.finishRecording(old.id, RecordingStatus.COMPLETED)
            val saved = create("heart")
            db.finishRecording(saved.id, RecordingStatus.COMPLETED)
            db.saveHeartQuestionnaire(saved.id, HeartQuestionnaire(
                answers = HEART_OPTIONS.keys.filter { it != "acuteHeartRateFactors" }.associateWith { "unknown" },
                acuteHeartRateFactors = listOf("unknown")))

            try {
                prompts.recoverInterrupted(db) { false }
                fail("failed persistence must abort recovery")
            } catch (_: java.io.IOException) { }
            assertEquals(RecordingStatus.RECORDING, db.recording(active.id)?.status)
            assertEquals(RecordingStatus.PREPARING, db.recording(preparing.id)?.status)
            prompts.recoverInterrupted(db)
            db.close()
            db = WoonaDatabase(context, root)
            val afterRestart = PendingHeartPrompts(context)
            assertTrue(afterRestart.ids().containsAll(listOf(active.id, preparing.id)))
            assertFalse(afterRestart.ids().contains(unrelated.id))
            assertFalse(afterRestart.ids().contains(old.id))
            assertFalse(afterRestart.ids().contains(saved.id))
            assertEquals(RecordingStatus.INTERRUPTED, db.recording(active.id)?.status)
            assertTrue(afterRestart.remove(active.id))
            afterRestart.recoverInterrupted(db)
            assertFalse(PendingHeartPrompts(context).ids().contains(active.id))
            assertTrue(PendingHeartPrompts(context).ids().contains(preparing.id))
        } finally {
            ids.forEach { prompts.remove(it) }
            db.close()
            root.deleteRecursively()
        }
    }
}

private fun completeDogQuestionnaire(name: String) = DogQuestionnaire(
    numberOrName = name,
    shelterOrPlace = "Shelter",
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

