package com.example.myapplication.data

import android.database.sqlite.SQLiteDatabase
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.json.JSONObject

@RunWith(AndroidJUnit4::class)
class CompleteDataArchiveTest {
    @Test fun unfinalizedHistoryAndUnavailableFilesRemainExplicitInRecoveryArchive() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val root = File(context.cacheDir, "archive-recovery-${System.nanoTime()}").apply { mkdirs() }
        val snapshot = File(root.parentFile, "archive-recovery-snapshot-${System.nanoTime()}.sqlite")
        try {
            SQLiteDatabase.openOrCreateDatabase(File(root, "woona.sqlite"), null).use { database ->
                database.execSQL("CREATE TABLE recordings(id TEXT PRIMARY KEY,status TEXT)")
                database.execSQL("CREATE TABLE artifacts(id TEXT,recording_id TEXT,relative_path TEXT,size_bytes INTEGER,sha256 TEXT)")
                database.execSQL("INSERT INTO recordings VALUES ('old-crash','recording')")
                database.execSQL("INSERT INTO artifacts VALUES ('old-file','old-crash','recordings/missing.mp4',12,'sha256')")
                createDatabaseSnapshot(database, snapshot)
            }
            val metadata = JSONObject(completeArchiveMetadata(snapshot, root))
            assertEquals(1, metadata.getInt("unfinalizedRecordingCount"))
            assertEquals("old-crash", metadata.getJSONArray("unfinalizedRecordings").getJSONObject(0).getString("recordingId"))
            assertEquals("recording", metadata.getJSONArray("unfinalizedRecordings").getJSONObject(0).getString("savedStatus"))
            assertEquals(1, metadata.getInt("unavailableLocalArtifactCount"))
            assertEquals("old-file", metadata.getJSONArray("unavailableLocalArtifacts").getJSONObject(0).getString("artifactId"))
        } finally { snapshot.delete(); root.deleteRecursively() }
    }
    @Test fun sqliteSnapshotIncludesCommittedWalAndAllHistoricalTables() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val root = File(context.cacheDir, "archive-wal-${System.nanoTime()}").apply { mkdirs() }
        try {
            WoonaDatabase(context, root).use { store ->
                val database = store.writableDatabase
                assertTrue(database.enableWriteAheadLogging())
                database.execSQL("CREATE TABLE export_wal_fixture (id INTEGER PRIMARY KEY, value TEXT)")
                database.execSQL("INSERT INTO export_wal_fixture(value) VALUES ('committed in WAL')")
                val snapshot = File(root.parentFile, "archive-snapshot-${System.nanoTime()}.sqlite")
                try {
                    createDatabaseSnapshot(database, snapshot)
                    SQLiteDatabase.openDatabase(snapshot.path, null, SQLiteDatabase.OPEN_READONLY).use { copy ->
                        copy.rawQuery("SELECT value FROM export_wal_fixture", null).use { assertTrue(it.moveToFirst()); assertEquals("committed in WAL", it.getString(0)) }
                        copy.rawQuery("PRAGMA quick_check", null).use { assertTrue(it.moveToFirst()); assertEquals("ok", it.getString(0)) }
                    }
                    val metadata = JSONObject(completeArchiveMetadata(snapshot, root))
                    assertEquals(1, metadata.getJSONObject("counts").getInt("export_wal_fixture"))
                    assertEquals(0, metadata.getJSONObject("counts").getInt("dogs"))
                    assertEquals(0, metadata.getInt("unavailableLocalArtifactCount"))
                    assertTrue(File(root, "woona.sqlite-wal").exists())
                } finally { snapshot.delete() }
            }
        } finally { root.deleteRecursively() }
    }
}
