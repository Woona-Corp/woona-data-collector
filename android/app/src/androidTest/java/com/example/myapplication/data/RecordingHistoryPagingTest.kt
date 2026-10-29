package com.example.myapplication.data

import android.content.ContentValues
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import java.time.Instant
import java.util.UUID
import kotlin.system.measureNanoTime
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RecordingHistoryPagingTest {
    @Test fun thousandRecordHistoryIsBoundedStableAndPreservesMetadata() = withDatabase { database ->
        val dog = seed(database, 1205)
        val first = database.recordingHistoryPage(dog.id)
        assertEquals(100, first.recordings.size); assertEquals(1205, first.totalCount)
        assertEquals(10, database.recentRecordings(dog.id).size)
        val rows = mutableListOf<Recording>()
        var cursor: RecordingHistoryCursor? = null
        val bulkNs = measureNanoTime {
            do {
                val page = database.recordingHistoryPage(dog.id, after = cursor)
                assertTrue(page.recordings.size <= 100)
                rows += page.recordings; cursor = page.nextCursor
            } while (cursor != null)
        }
        assertEquals(1205, rows.size); assertEquals(1205, rows.map { it.id }.distinct().size)
        assertEquals((1204 downTo 0).map { UUID(0,it.toLong()+1).toString() }, rows.map { it.id })
        assertTrue(rows.all { it.captureErrorCode == "gatt_error" && it.captureErrorMessage == "GATT status 8" })
        assertTrue(rows.all { it.endedAtUtc == null && it.questionnaireRevision == 7 && it.remoteOrigin })
        assertTrue(rows.all { it.artifacts.size == 2 && it.serverSyncState == "retryable_error" && it.serverSyncError == "Preserve detailed cause" })
        val perRow = mutableListOf<Recording>()
        val perRowNs = measureNanoTime { rows.forEach { perRow += requireNotNull(database.recording(it.id)) } }
        assertEquals(perRow, rows)
        android.util.Log.i("WoonaHistoryBenchmark", "1205 rows: bounded bulk pages=${bulkNs/1_000_000}ms, per-record legacy metadata reads=${perRowNs/1_000_000}ms")
        database.readableDatabase.rawQuery("EXPLAIN QUERY PLAN SELECT id FROM recordings WHERE dog_id=? ORDER BY COALESCE(CAST(ROUND((CASE WHEN started_at_utc GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*' THEN julianday(started_at_utc) END-2440587.5)*86400000.0) AS INTEGER),-9223372036854775807) DESC,id DESC LIMIT 100", arrayOf(dog.id)).use { plan ->
            val text = buildString { while(plan.moveToNext()) appendLine(plan.getString(3)) }
            assertTrue(text, text.contains("recordings_history_time")); assertFalse(text,text.contains("TEMP B-TREE"))
        }
    }

    @Test fun mixedUtcPrecisionsOffsetsAndInvalidDatesCrossPageBoundariesWithoutChangingOriginals() = withDatabase { database ->
        val dog = seed(database, 9)
        val times = listOf("2026-07-01T10:00:03Z", "2026-07-01T10:00:03.123Z", "2026-07-01T13:00:03.123000+03:00", "2026-07-01T10:00:03.123456Z", "2026-07-01T10:00:03.900000Z", "2026-07-01T10:00:04Z", "invalid historical time", "now", null)
        times.forEachIndexed { index,time -> database.writableDatabase.update("recordings", ContentValues().apply { if(time==null) putNull("started_at_utc") else put("started_at_utc",time) }, "id=?", arrayOf(UUID(0,index.toLong()+1).toString())) }
        val actual = mutableListOf<Recording>();var cursor:RecordingHistoryCursor?=null
        do { val page=database.recordingHistoryPage(dog.id,2,cursor);actual+=page.recordings;cursor=page.nextCursor } while(cursor!=null)
        assertEquals(listOf(6,5,4,3,2,1,9,8,7).map {UUID(0,it.toLong()).toString()},actual.map {it.id})
        assertEquals(9,actual.map {it.id}.distinct().size)
        times.forEachIndexed { index,time -> database.readableDatabase.rawQuery("SELECT started_at_utc FROM recordings WHERE id=?",arrayOf(UUID(0,index.toLong()+1).toString())).use { c -> c.moveToFirst();assertEquals(time,if(c.isNull(0))null else c.getString(0)) } }
        assertTrue(actual.all {it.endedAtUtc==null})
    }

    @Test fun insertionAheadOfCursorDoesNotRepeatPreviouslyShownRows() = withDatabase { database ->
        val dog=seed(database,205);val first=database.recordingHistoryPage(dog.id)
        val newest=database.beginRecording(dog.id,RecordingSource.LIVE,SessionQuestionnaire(schemaVersion=2,sessionLabel="New capture",plannedActivities=listOf("Покой"),videoRequested=false))
        val second=database.recordingHistoryPage(dog.id,after=first.nextCursor)
        assertEquals(206,second.totalCount);assertEquals(100,second.recordings.size)
        assertTrue(first.recordings.map {it.id}.intersect(second.recordings.map {it.id}.toSet()).isEmpty())
        assertFalse(second.recordings.any {it.id==newest.id})
    }

    private fun seed(database:WoonaDatabase,count:Int):DogProfile {
        val dog=database.saveProfile(DogQuestionnaire(schemaVersion=2,animalId="history-fixture",numberOrName="Synthetic history",species="собака"))
        val template=database.beginRecording(dog.id,RecordingSource.LIVE,SessionQuestionnaire(schemaVersion=2,sessionLabel="Template",plannedActivities=listOf("Покой"),videoRequested=false))
        val original=ContentValues();database.readableDatabase.rawQuery("SELECT * FROM recordings WHERE id=?",arrayOf(template.id)).use {c->c.moveToFirst();android.database.DatabaseUtils.cursorRowToContentValues(c,original)}
        val base=Instant.parse("2026-07-01T10:00:00Z")
        database.writableDatabase.beginTransaction()
        try {
            for(index in 0 until count) {
                val id=UUID(0,index.toLong()+1).toString();val directory="recordings/${dog.id}/2026-07-01/$id"
                database.writableDatabase.insertOrThrow("recordings",null,ContentValues(original).apply {put("id",id);put("session_label","Session $index");put("started_at_utc",base.plusMillis(index.toLong()).toString());putNull("ended_at_utc");put("status","failed");put("capture_error_code","gatt_error");put("capture_error_message","GATT status 8");put("questionnaire_revision",7);put("remote_copy",1);put("relative_directory",directory)})
                database.writableDatabase.insertOrThrow("server_sync_state",null,ContentValues().apply {put("recording_id",id);put("state","retryable_error");put("last_error_message","Preserve detailed cause");put("server_receipt_sha256","b".repeat(64));put("updated_at_utc",base.toString())})
                for((type,name) in listOf("packet" to "packets.bin","video" to "video.mp4")) database.writableDatabase.insertOrThrow("artifacts",null,ContentValues().apply {put("id",UUID.randomUUID().toString());put("recording_id",id);put("type",type);put("file_name",name);put("mime_type","application/octet-stream");put("relative_path","$directory/$name");put("size_bytes",100L);put("sha256","a".repeat(64));put("hash_state","verified");put("local_presence","remote_only");put("upload_state","available");put("uploaded_bytes",100L);put("created_at_utc",base.toString())})
            }
            database.writableDatabase.delete("server_sync_state","recording_id=?",arrayOf(template.id));database.writableDatabase.delete("recordings","id=?",arrayOf(template.id))
            database.writableDatabase.setTransactionSuccessful()
        }finally{database.writableDatabase.endTransaction()}
        return dog
    }
    private fun withDatabase(test:(WoonaDatabase)->Unit) {
        val context=ApplicationProvider.getApplicationContext<android.content.Context>()
        val root=File(context.cacheDir,"history-qa-${UUID.randomUUID()}")
        try{WoonaDatabase(context,root).use(test)}finally{root.deleteRecursively()}
    }
}
