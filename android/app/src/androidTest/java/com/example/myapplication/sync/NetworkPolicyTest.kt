package com.example.myapplication.sync

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.example.myapplication.data.*
import java.io.File
import kotlin.concurrent.withLock
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.workDataOf
import java.util.UUID
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NetworkPolicyTest {
    private val context = ApplicationProvider.getApplicationContext<android.content.Context>()
    private val manager get() = WorkManager.getInstance(context)
    private fun constraint(type: NetworkType) = Constraints.Builder().setRequiredNetworkType(type).build()

    @Test fun orphanedUploadingStatesRecoverOnlyWhenUniqueWorkIsAbsentOrTerminal() {
        val root = File(context.cacheDir, "orphan-upload-${UUID.randomUUID()}")
        val names = mutableListOf<String>()
        try {
            WoonaDatabase(context, root).use { database ->
                fun record(name: String): Recording {
                    val dog = database.saveProfile(DogQuestionnaire(schemaVersion = 2, numberOrName = name, animalId = name))
                    val record = database.beginRecording(dog.id, RecordingSource.LIVE, SessionQuestionnaire(schemaVersion = 2, sessionLabel = name, plannedActivities = listOf("walk")))
                    File(database.recordingDirectory(record.relativeDirectory), "packets.bin").writeText("packet bytes")
                    database.writeSyncMetadata(record.id, CaptureSyncMetadata(recordingId = record.id, profileId = dog.id, source = "live", timezone = record.timezone, selectedSessionStartUtc = record.startedAtUtc))
                    database.finishRecording(record.id, RecordingStatus.COMPLETED)
                    database.hashPendingArtifacts()
                    database.markRecordingUploading(record.id)
                    return record
                }
                val lost = record("lost")
                val terminal = record("terminal")
                val queued = record("queued")
                val packet = requireNotNull(database.recordingSyncRecord(lost.id)).artifacts.first()
                database.markArtifactProgress(packet.id, 2)
                database.writableDatabase.execSQL("UPDATE server_sync_state SET server_receipt_sha256=? WHERE recording_id=?", arrayOf("f".repeat(64), lost.id))
                val before = requireNotNull(database.recordingSyncRecord(lost.id)).artifacts
                val profile = requireNotNull(database.profile(lost.profileId))
                database.markProfileUploading(profile.profileVersionId)
                val activeProfile = requireNotNull(database.profile(queued.profileId))
                database.markProfileUploading(activeProfile.profileVersionId)
                fun queue(name: String, id: String, profileWorker: Boolean = false) {
                    val request = if (profileWorker) OneTimeWorkRequestBuilder<ProfileSyncWorker>().setInputData(workDataOf("id" to id)).setInitialDelay(1, TimeUnit.DAYS).build()
                        else OneTimeWorkRequestBuilder<RecordingSyncWorker>().setInputData(workDataOf("id" to id)).setInitialDelay(1, TimeUnit.DAYS).build()
                    manager.enqueueUniqueWork(name, androidx.work.ExistingWorkPolicy.KEEP, request).result.get(10, TimeUnit.SECONDS)
                    names.add(name)
                }
                queue("server-sync-${terminal.id}", terminal.id)
                manager.cancelUniqueWork("server-sync-${terminal.id}").result.get(10, TimeUnit.SECONDS)
                queue("server-sync-${queued.id}", queued.id)
                queue("server-profile-${activeProfile.profileVersionId}", activeProfile.profileVersionId, true)
                val counts = serverOperationLock.withLock {
                    database.recoverOrphanedUploads { name -> manager.getWorkInfosForUniqueWork(name).get(10, TimeUnit.SECONDS).any { !it.state.isFinished } }
                }
                assertEquals(1 to 2, counts)
                assertEquals(before, requireNotNull(database.recordingSyncRecord(lost.id)).artifacts)
                assertTrue(database.pendingRecordingIds().containsAll(listOf(lost.id, terminal.id)))
                assertFalse(database.pendingRecordingIds().contains(queued.id))
                assertTrue(database.pendingProfileVersionIds().contains(profile.profileVersionId))
                assertFalse(database.pendingProfileVersionIds().contains(activeProfile.profileVersionId))
                database.readableDatabase.rawQuery("SELECT server_receipt_sha256 FROM server_sync_state WHERE recording_id=?", arrayOf(lost.id)).use { cursor ->
                    assertTrue(cursor.moveToFirst()); assertEquals("f".repeat(64), cursor.getString(0))
                }
                assertEquals(WorkInfo.State.ENQUEUED, manager.getWorkInfosForUniqueWork("server-sync-${queued.id}").get().first { !it.state.isFinished }.state)
            }
        } finally {
            names.forEach { manager.cancelUniqueWork(it).result.get(10, TimeUnit.SECONDS) }
            root.deleteRecursively()
        }
    }

    @Test fun queuedWorkKeepsIdentityTagsAndInputWhileItsNetworkConstraintChanges() {
        val name = "policy-fixture-${UUID.randomUUID()}"
        val inputId = "not-a-stored-profile-${UUID.randomUUID()}"
        val request = OneTimeWorkRequestBuilder<ProfileSyncWorker>()
            .setInputData(workDataOf("id" to inputId)).addTag(name)
            .setConstraints(constraint(NetworkType.UNMETERED))
            .setInitialDelay(1, TimeUnit.DAYS)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .build()
        try {
            manager.enqueueUniqueWork(name, androidx.work.ExistingWorkPolicy.KEEP, request).result.get(10, TimeUnit.SECONDS)
            val before = requireNotNull(manager.getWorkInfoById(request.id).get(10, TimeUnit.SECONDS))
            assertEquals(WorkInfo.State.ENQUEUED, before.state)
            assertEquals(NetworkType.UNMETERED, before.constraints.requiredNetworkType)
            val changed = ServerSyncScheduler.updateWaitingNetworkPolicy(manager, name, constraint(NetworkType.CONNECTED)) { old ->
                OneTimeWorkRequestBuilder<ProfileSyncWorker>()
                    .setId(old.id).setInputData(workDataOf("id" to inputId))
                    .apply { old.tags.forEach { tag -> addTag(tag) } }
                    .setConstraints(constraint(NetworkType.CONNECTED))
                    .setInitialDelay(1, TimeUnit.DAYS)
                    .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
                    .build()
            }
            assertEquals(1, changed)
            val after = requireNotNull(manager.getWorkInfoById(request.id).get(10, TimeUnit.SECONDS))
            assertEquals(before.id, after.id)
            assertEquals(before.tags, after.tags)
            assertEquals(WorkInfo.State.ENQUEUED, after.state)
            assertEquals(NetworkType.CONNECTED, after.constraints.requiredNetworkType)
            assertEquals(before.generation + 1, after.generation)
        } finally { manager.cancelUniqueWork(name).result.get(10, TimeUnit.SECONDS) }
    }

    @Test fun runningWorkIsNotCancelledOrRebuiltWhenNetworkPolicyChanges() {
        val name = "policy-running-fixture-${UUID.randomUUID()}"
        val request = OneTimeWorkRequestBuilder<ProfileSyncWorker>()
            .setInputData(workDataOf("id" to "nonexistent-${UUID.randomUUID()}"))
            .addTag(name).build()
        serverOperationLock.lock()
        try {
            manager.enqueueUniqueWork(name, androidx.work.ExistingWorkPolicy.KEEP, request).result.get(10, TimeUnit.SECONDS)
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(15)
            var info: WorkInfo
            do {
                info = requireNotNull(manager.getWorkInfoById(request.id).get(5, TimeUnit.SECONDS))
                if (info.state == WorkInfo.State.RUNNING) break
                Thread.sleep(50)
            } while (System.nanoTime() < deadline)
            assertEquals("Synthetic worker must be held in RUNNING before the policy update", WorkInfo.State.RUNNING, info.state)
            var rebuilt = false
            val changed = ServerSyncScheduler.updateWaitingNetworkPolicy(manager, name, constraint(NetworkType.UNMETERED)) {
                rebuilt = true
                error("RUNNING work must not be rebuilt or cancelled")
            }
            assertEquals(0, changed)
            assertFalse(rebuilt)
            val after = requireNotNull(manager.getWorkInfoById(request.id).get(5, TimeUnit.SECONDS))
            assertEquals(WorkInfo.State.RUNNING, after.state)
            assertEquals(info.generation, after.generation)
        } finally {
            serverOperationLock.unlock()
            manager.cancelUniqueWork(name).result.get(10, TimeUnit.SECONDS)
        }
    }
}
