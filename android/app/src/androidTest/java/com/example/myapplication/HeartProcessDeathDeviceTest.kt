package com.example.myapplication

import android.content.Context
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.example.myapplication.data.*
import com.example.myapplication.localization.AppLanguage
import com.example.myapplication.localization.AppLanguagePreferences
import java.io.File
import java.util.UUID
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

/** Two explicit invocations with a host-side force-stop between them; isolated QA package only. */
@RunWith(AndroidJUnit4::class)
class HeartProcessDeathDeviceTest {
    @get:Rule val compose = createEmptyComposeRule()
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext
    private val fixture get() = context.getSharedPreferences("heart-process-death-fixture", Context.MODE_PRIVATE)

    private fun requirePhase(phase: String) {
        assumeTrue("Explicit isolated process-death phase required", InstrumentationRegistry.getArguments().getString("heartDeathPhase") == phase)
        require(context.packageName.contains(".qa")) { "Only a separately installed synthetic QA package is allowed" }
    }

    @Test fun prepareActiveHeartRecording() {
        requirePhase("prepare")
        context.getSharedPreferences("woona_server", Context.MODE_PRIVATE).edit().remove("account_id")
            .putBoolean("explicitly_disconnected", true).commit()
        AppLanguagePreferences(context).setSelectedLanguage(AppLanguage.ENGLISH)
        WoonaDatabase(context).use { db ->
            val dog = db.saveProfile(DogQuestionnaire(schemaVersion = 2, animalId = "death-${UUID.randomUUID()}", numberOrName = "Synthetic process death"))
            context.getSharedPreferences("woona_profiles", Context.MODE_PRIVATE).edit().putString("last_profile_id", dog.id).commit()
            val recording = db.beginRecording(dog.id, RecordingSource.LIVE, SessionQuestionnaire(
                schemaVersion = 2, sessionLabel = "Synthetic interrupted heart", sessionKind = "heart", videoRequested = false))
            val original = File(db.recordingDirectory(recording.relativeDirectory), "packets.bin").apply { writeBytes(byteArrayOf(7, 8, 9)) }
            db.writeSyncMetadata(recording.id, CaptureSyncMetadata(recordingId = recording.id, profileId = dog.id,
                source = "live", timezone = recording.timezone, selectedSessionStartUtc = recording.startedAtUtc))
            db.markRecording(recording.id)
            assertTrue(fixture.edit().putString("recording", recording.id).putString("original", original.absolutePath).commit())
            assertEquals(RecordingStatus.RECORDING, db.recording(recording.id)?.status)
        }
    }

    @Test fun verifyRestartPromptsOnceAndKeepsOriginal() {
        requirePhase("verify")
        val id = requireNotNull(fixture.getString("recording", null))
        val original = File(requireNotNull(fixture.getString("original", null)))
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            compose.waitUntil(20_000) {
                try { compose.onAllNodesWithText("Activity and heart questionnaire").fetchSemanticsNodes().isNotEmpty() }
                catch (_: IllegalStateException) { false }
            }
            WoonaDatabase(context).use { db ->
                assertEquals(RecordingStatus.INTERRUPTED, db.recording(id)?.status)
                assertArrayEquals(byteArrayOf(7, 8, 9), original.readBytes())
            }
            assertTrue(id in PendingHeartPrompts(context).ids())
            compose.onNodeWithText("Cancel").performClick()
            compose.waitUntil(5_000) { id !in PendingHeartPrompts(context).ids() }
            scenario.recreate()
            compose.waitUntil(15_000) {
                try { compose.onAllNodesWithTag("tab.animals").fetchSemanticsNodes().isNotEmpty() }
                catch (_: IllegalStateException) { false }
            }
            compose.onNodeWithText("Activity and heart questionnaire").assertDoesNotExist()
            assertArrayEquals(byteArrayOf(7, 8, 9), original.readBytes())
        }
    }
}
