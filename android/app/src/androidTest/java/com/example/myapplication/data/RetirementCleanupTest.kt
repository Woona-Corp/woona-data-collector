package com.example.myapplication.data

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import java.util.UUID
import org.junit.After
import org.junit.Before
import org.junit.Test
import org.junit.Assert.*
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RetirementCleanupTest {
    private lateinit var root: File
    private lateinit var database: WoonaDatabase
    @Before fun setup() {
        root=File(ApplicationProvider.getApplicationContext<android.content.Context>().cacheDir,"retirement-${UUID.randomUUID()}")
        database=WoonaDatabase(ApplicationProvider.getApplicationContext(),root)
    }
    @After fun cleanup() { database.close();root.deleteRecursively() }
    private fun record():Pair<Recording,File> {
        val dog=database.saveProfile(DogQuestionnaire(schemaVersion=2,numberOrName="Retirement fixture",animalId=UUID.randomUUID().toString()),accountId="other-account")
        val recording=database.beginRecording(dog.id,RecordingSource.LIVE,SessionQuestionnaire(schemaVersion=2,sessionLabel="Only local copy",plannedActivities=listOf("walk"),videoRequested=false))
        val file=File(database.recordingDirectory(recording.relativeDirectory),"packets.bin").apply {writeText("SOLE SYNTHETIC ORIGINAL")}
        database.finishRecording(recording.id,RecordingStatus.COMPLETED)
        return requireNotNull(database.recording(recording.id)) to file
    }
    private fun marker(id:String)= "recording" to java.security.MessageDigest.getInstance("SHA-256").digest(id.toByteArray()).joinToString(""){"%02x".format(it)}

    @Test fun databaseAbortPreservesAllSourceBytesAndRollsBackIntent() {
        val (record,file)=record()
        database.writableDatabase.execSQL("CREATE TRIGGER reject_retirement BEFORE DELETE ON recordings BEGIN SELECT RAISE(ABORT,'injected DB error'); END")
        assertTrue(runCatching {database.applyServerDeletions(listOf(marker(record.id)))}.isFailure)
        assertNotNull(database.recording(record.id));assertEquals("SOLE SYNTHETIC ORIGINAL",file.readText())
        assertEquals(0,database.retirementCleanupStatus().pending)
    }
    @Test fun authoritativeRetirementPersistsIntentAcrossFilesystemFailureAndRestart() {
        val (record,file)=record()
        File(file.parentFile,"unregistered-note.txt").writeText("Explicit retirement also retires this directory")
        assertEquals(1,database.applyServerDeletions(listOf(marker(record.id))) { _,_->false })
        assertNull(database.recording(record.id));assertEquals("SOLE SYNTHETIC ORIGINAL",file.readText())
        assertEquals(1,database.retirementCleanupStatus().pending);assertNotNull(database.retirementCleanupStatus().lastError)
        database.close();database=WoonaDatabase(ApplicationProvider.getApplicationContext(),root)
        assertEquals(1,database.retirementCleanupStatus().pending)
        assertEquals(0,database.retryRetirementCleanup().pending)
        assertFalse(file.parentFile!!.exists())
        assertEquals(0,database.applyServerDeletions(listOf(marker(record.id))))
        assertEquals(0,database.retryRetirementCleanup().pending)
    }
    @Test fun cleanupNeverRunsBeforeOuterCommitAndCannotRemoveActiveOrEscapingPaths() {
        val (record,file)=record()
        database.writableDatabase.beginTransaction()
        try {
            database.enqueueRetirementCleanup(database.writableDatabase,file.parentFile!!,true)
            assertTrue(runCatching {database.retryRetirementCleanup()}.isFailure)
            assertTrue(file.isFile)
        } finally {database.writableDatabase.endTransaction()}
        assertEquals(0,database.retirementCleanupStatus().pending)
        database.writableDatabase.execSQL("UPDATE recordings SET status='recording' WHERE id=?",arrayOf(record.id))
        database.enqueueRetirementCleanup(database.writableDatabase,file.parentFile!!,true)
        assertEquals(1,database.retryRetirementCleanup().pending);assertTrue(file.isFile)
        val outside=File(root.parentFile,"outside-${UUID.randomUUID()}").apply {writeText("PRESERVE")}
        try {
            database.writableDatabase.execSQL("INSERT INTO local_deletion_outbox(id,relative_path,entry_kind,created_at_utc) VALUES(?,?,?,?)",arrayOf(UUID.randomUUID().toString(),"../${outside.name}","file","2026-10-27T00:00:00Z"))
            assertEquals(2,database.retryRetirementCleanup().pending)
            assertEquals("PRESERVE",outside.readText());assertTrue(root.isDirectory)
        } finally {outside.delete()}
    }
    @Test fun acceptedActiveRetirementSurvivesRestartAndNeedsNoServerOrReceiptAfterRecovery() {
        val (record,file)=record()
        database.writableDatabase.execSQL("UPDATE recordings SET status='recording',ended_at_utc=NULL WHERE id=?",arrayOf(record.id))
        assertEquals(0,database.applyServerDeletions(listOf(marker(record.id))))
        assertTrue(file.isFile);assertEquals(1,database.retirementCleanupStatus().deferredCount)
        database.close();database=WoonaDatabase(ApplicationProvider.getApplicationContext(),root)
        database.interruptUnfinished()
        assertEquals(1,database.applyServerDeletions(emptyList()))
        assertNull(database.recording(record.id));assertFalse(file.exists())
        assertEquals(RetirementCleanupStatus(0,null,0),database.retirementCleanupStatus())
    }

    @Test fun version7UpgradeAddsOutboxWithoutChangingFilesOffsetsOrQuestionnaire() {
        val (record,file)=record()
        val artifact=record.artifacts.single()
        database.markArtifactProgress(artifact.id,5)
        database.writableDatabase.execSQL("DROP TABLE local_deletion_outbox")
        database.writableDatabase.execSQL("DROP TABLE deferred_retirements")
        database.writableDatabase.version=7
        database.close();database=WoonaDatabase(ApplicationProvider.getApplicationContext(),root)
        assertEquals(8,database.readableDatabase.version)
        assertEquals(0,database.retirementCleanupStatus().pending)
        val restored=requireNotNull(database.recording(record.id))
        assertEquals(record.questionnaire,restored.questionnaire);assertEquals(5L,restored.artifacts.single().uploadedBytes)
        assertEquals("SOLE SYNTHETIC ORIGINAL",file.readText())
    }
}
