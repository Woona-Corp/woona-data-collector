package com.example.myapplication.data

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LocalAnimalIdentityTest {
    private lateinit var root: File
    private lateinit var db: WoonaDatabase
    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private fun dog(identity: String, name: String = "Dog") = DogQuestionnaire(
        schemaVersion = 2, numberOrName = name, animalId = identity,
    )

    @Before fun setUp() {
        root = File(context.cacheDir, "identity-test-${System.nanoTime()}")
        db = WoonaDatabase(context, root)
    }
    @After fun tearDown() { db.close(); root.deleteRecursively() }

    @Test fun normalizationMatchesStripAndCasefoldRatherThanLowercase() {
        for ((raw, expected) in listOf(
            " \tDoG\n" to "dog", "Straße" to "strasse", "Σςσ" to "σσσ",
            "\u0085\u001cDOG\u00a0" to "dog", "ﬃ" to "ffi", "İ" to "i\u0307",
            "\u200bDOG\u200b" to "\u200bdog\u200b",
        )) assertEquals(expected, normalizedAnimalIdentity(raw))
    }

    @Test fun sameUuidMayEditAndHistoricalAliasRemainsReservedAcrossAccounts() {
        val first = db.saveProfile(dog(" Straße "), accountId = "first")
        val immutable = requireNotNull(db.profileSyncRecord(first.profileVersionId))
        assertEquals(first.profileVersionId, db.saveProfile(dog(" Straße "), first.id).profileVersionId)
        val edited = db.saveProfile(dog("New-ID", "Renamed"), first.id)
        assertEquals(first.id, edited.id)
        assertNotEquals(first.profileVersionId, edited.profileVersionId)
        db.markProfileSyncError(first.profileVersionId, false, "http_409", "Historical error")
        val snapshot = requireNotNull(db.profileSyncSnapshots()[first.id])
        assertEquals(edited.profileVersionId, snapshot.versionId)
        assertEquals("pending", snapshot.state)
        assertEquals(0, snapshot.attemptCount)
        assertNull(snapshot.errorCode)
        assertNull(snapshot.lastAttemptUtc)
        val before = requireNotNull(db.profileSyncRecord(first.profileVersionId))
        // dogName is a joined CURRENT card label, not immutable version JSON.
        assertEquals("Renamed", before.dogName)
        assertEquals(immutable.copy(dogName = "Renamed"), before)
        val failure = assertThrows(LocalAnimalIdentityConflict::class.java) {
            db.saveProfile(dog("STRASSE"), accountId = "second")
        }
        assertEquals(first.id, failure.existingProfileId)
        assertEquals("Renamed", failure.existingProfileName)
        assertEquals("first", failure.existingAccountId)
        assertEquals(before, db.profileSyncRecord(first.profileVersionId))
        assertEquals(1, db.profiles().size)
        // Its own old alias can be reused, without merging with any other UUID.
        assertEquals(first.id, db.saveProfile(dog("strasse", "Renamed"), first.id).id)
    }

    @Test fun archivedProfilesStillReserveIdsAndFailureDoesNotSupersedeCurrentVersion() {
        val first = db.saveProfile(dog("reserved"))
        val second = db.saveProfile(dog("available"))
        db.writableDatabase.execSQL("UPDATE dogs SET archived_at_utc='2026-11-07T00:00:00Z' WHERE id=?", arrayOf(first.id))
        val before = requireNotNull(db.profileSyncRecord(second.profileVersionId))
        assertThrows(LocalAnimalIdentityConflict::class.java) { db.saveProfile(dog("RESERVED"), second.id) }
        assertEquals(second.profileVersionId, db.profile(second.id)?.profileVersionId)
        assertEquals(before, db.profileSyncRecord(second.profileVersionId))
    }

    @Test fun concurrentSeparateDatabaseHandlesCannotClaimSameIdentity() {
        // Open both before racing to isolate save transaction serialization.
        WoonaDatabase(context, root).use { other ->
            other.writableDatabase
            val executor = Executors.newFixedThreadPool(2)
            val start = CountDownLatch(1)
            try {
                val futures = listOf(db, other).mapIndexed { index, database -> executor.submit<Boolean> {
                    start.await()
                    try { database.saveProfile(dog(if (index == 0) "Race" else " RACE ")); true }
                    catch (_: LocalAnimalIdentityConflict) { false }
                } }
                start.countDown()
                assertEquals(1, futures.count { it.get(15, TimeUnit.SECONDS) })
                assertEquals(1, db.profiles().size)
            } finally { executor.shutdownNow() }
        }
    }

    @Test fun syncFailureDetailsAreRedactedBeforeDurableStorage() {
        val saved = db.saveProfile(dog("redaction"))
        val recording = db.beginRecording(saved.id, RecordingSource.LIVE,
            SessionQuestionnaire(schemaVersion = 2, sessionLabel = "Synthetic", plannedActivities = listOf("walk")))
        val raw = """Server returned HTTP 409: {"token":"synthetic-secret","password":"password-secret","url":"https://files.example/a?X-Amz-Signature=signed-secret&credential=query-secret"} (requestId=req-safe-123)"""
        db.markProfileSyncError(saved.profileVersionId, false, "http_409", raw)
        db.markRecordingSyncError(recording.id, false, "http_409", raw)
        db.close(); db = WoonaDatabase(context, root)
        val profileMessage = requireNotNull(db.profileSyncSnapshots()[saved.id]?.errorMessage)
        val recordingMessage = db.readableDatabase.rawQuery(
            "SELECT last_error_message FROM server_sync_state WHERE recording_id=?", arrayOf(recording.id),
        ).use { assertTrue(it.moveToFirst()); it.getString(0) }
        for (message in listOf(profileMessage, recordingMessage)) {
            for (secret in listOf("synthetic-secret", "password-secret", "signed-secret", "query-secret")) {
                assertFalse(message.contains(secret))
            }
            assertTrue(message.contains("409"))
            assertTrue(message.contains("req-safe-123"))
        }
    }

    @Test fun linkingAccountOnlyInvalidatesCurrentAcceptanceWhenBindingActuallyChanges() {
        val first = db.saveProfile(dog("link"))
        db.markProfileSynced(first.profileVersionId, first.id, 3)
        val current = db.saveProfile(dog("link", "Edited"), first.id)
        db.markProfileSynced(current.profileVersionId, current.id, 4)
        val immutable = requireNotNull(db.profileSyncRecord(current.profileVersionId))
        db.linkDogAccount(current.id, " First ")
        assertEquals("first", db.profile(current.id)?.accountId)
        assertEquals("pending", db.profileSyncSnapshots()[current.id]?.state)
        assertEquals(immutable, db.profileSyncRecord(current.profileVersionId))
        assertTrue(current.profileVersionId in db.pendingProfileVersionIds())
        db.readableDatabase.rawQuery("SELECT server_sync_state,server_synced_at_utc FROM dog_profile_versions WHERE id=?", arrayOf(first.profileVersionId)).use {
            assertTrue(it.moveToFirst()); assertEquals("synced", it.getString(0)); assertNotNull(it.getString(1))
        }
        db.markProfileSynced(current.profileVersionId, current.id, 4)
        db.linkDogAccount(current.id, "FIRST")
        assertEquals("synced", db.profileSyncSnapshots()[current.id]?.state)
        assertFalse(current.profileVersionId in db.pendingProfileVersionIds())
        assertEquals(immutable, db.profileSyncRecord(current.profileVersionId))
    }

    @Test fun unconfiguredSchedulerLeavesLocalCommitPendingWithoutStartingRetryLoop() {
        val prefs = context.getSharedPreferences("woona_server", Context.MODE_PRIVATE)
        val hadFlag = prefs.contains("explicitly_disconnected")
        val oldFlag = prefs.getBoolean("explicitly_disconnected", false)
        val saved = db.saveProfile(dog("unconfigured"))
        val original = requireNotNull(db.profileSyncRecord(saved.profileVersionId))
        try {
            assertTrue(prefs.edit().putBoolean("explicitly_disconnected", true).commit())
            com.example.myapplication.sync.ServerSyncScheduler.enqueueProfile(context, saved.profileVersionId)
            val works = androidx.work.WorkManager.getInstance(context)
                .getWorkInfosForUniqueWork("server-profile-${saved.profileVersionId}").get(10, TimeUnit.SECONDS)
            assertTrue(works.none { !it.state.isFinished })
            assertEquals("pending", db.profileSyncSnapshots()[saved.id]?.state)
            assertEquals(original, db.profileSyncRecord(saved.profileVersionId))
            assertTrue(saved.profileVersionId in db.pendingProfileVersionIds())
        } finally {
            prefs.edit().apply {
                if (hadFlag) putBoolean("explicitly_disconnected", oldFlag) else remove("explicitly_disconnected")
            }.commit()
        }
    }

    @Test fun retryableWaitingSurvivesReopenWithoutChangingImmutablePayloadOrRevision() {
        val saved = db.saveProfile(dog("offline"))
        val original = requireNotNull(db.profileSyncRecord(saved.profileVersionId))
        // Also recover the exact permanent code written by older clients, but
        // never treat stale/invalid HTTP 409 as an automatic network retry.
        db.markProfileSyncError(saved.profileVersionId, false, "http_409", "Resolve the server conflict")
        assertFalse(saved.profileVersionId in db.pendingProfileVersionIds())
        db.markProfileSyncError(saved.profileVersionId, false, "server_not_configured", "Configure the server to resume")
        db.close(); db = WoonaDatabase(context, root)
        assertTrue(saved.profileVersionId in db.pendingProfileVersionIds())
        assertEquals(original, db.profileSyncRecord(saved.profileVersionId))
        db.markProfileUploading(saved.profileVersionId)
        db.markProfileSyncError(saved.profileVersionId, true, "network_error", "Offline")
        db.close(); db = WoonaDatabase(context, root)
        assertTrue(saved.profileVersionId in db.pendingProfileVersionIds())
        assertEquals(original, db.profileSyncRecord(saved.profileVersionId))
        db.markProfileSynced(saved.profileVersionId, saved.id, 7)
        assertFalse(saved.profileVersionId in db.pendingProfileVersionIds())
        val accepted = requireNotNull(db.profileSyncRecord(saved.profileVersionId))
        assertEquals(7L, accepted.expectedRevision)
        assertEquals(original.questionnaireJson, accepted.questionnaireJson)
        assertEquals(original.contentSha256, accepted.contentSha256)
    }
}
