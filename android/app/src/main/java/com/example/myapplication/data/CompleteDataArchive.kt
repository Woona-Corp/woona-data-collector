package com.example.myapplication.data

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import com.example.myapplication.storage.CompleteArchiveExporter
import com.example.myapplication.sync.serverOperationLock
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.TimeUnit

internal val completeArchiveLifecycleLock = Any()
@Volatile var isCompleteArchiveExporting: Boolean = false
    private set

/** Uses SQLite's transactional VACUUM INTO snapshot, including committed WAL pages. */
fun createCompleteDataArchive(
    context: Context,
    checkCancelled: () -> Unit = {},
    onProgress: (CompleteArchiveExporter.Progress) -> Unit = {},
    captureActive: Boolean = false,
): File {
    checkCancelled()
    if (captureActive) throw IOException("Stop and finalize the active recording before exporting all data. Original files are unchanged.")
    synchronized(completeArchiveLifecycleLock) {
        check(!isCompleteArchiveExporting) { "A complete archive export is already running" }
        isCompleteArchiveExporting = true
    }
    var acquired = false
    try {
        if (!serverOperationLock.tryLock(1, TimeUnit.SECONDS)) throw IOException("Server synchronization is running. Wait for it to finish, then retry the export.")
        acquired = true
        val root = File(context.filesDir, "Woona")
        WoonaDatabase(context).use { database ->
            val directory = File(context.cacheDir, "woona_complete_exports/${UUID.randomUUID()}")
            if (!directory.mkdirs()) throw IOException("Cannot create export directory")
            val snapshot = File(directory, "snapshot.sqlite")
            try {
                // Dedicated connection: data_version detects writes from every other connection.
                SQLiteDatabase.openDatabase(File(root, "woona.sqlite").path, null, SQLiteDatabase.OPEN_READWRITE).use { source ->
                    fun version(): Long = source.rawQuery("PRAGMA data_version", null).use { it.moveToFirst(); it.getLong(0) }
                    val before = version()
                    createDatabaseSnapshot(source, snapshot)
                    checkCancelled()
                    val settings = com.example.myapplication.sync.ServerSettingsStore(context).get()
                    val configuration = JSONObject()
                        .put("language", com.example.myapplication.localization.AppLanguagePreferences(context).selectedLanguage().languageTag)
                        .put("theme", com.example.myapplication.ui.theme.AppThemePreferences(context).selectedThemeMode().name)
                        .put("transport", com.example.myapplication.ble.BleTransportProfilePreferences(context).selectedTransportProfile().name)
                        .put("serverConfigured", settings.isConfigured).put("wifiOnly", settings.wifiOnly)
                        .put("captureDeviceId", settings.deviceId)
                        .put("selectedAccountId", settings.accountId ?: JSONObject.NULL)
                    val metadata = JSONObject(completeArchiveMetadata(snapshot, root)).put("configuration", configuration).toString()
                    val roots = listOf(
                        CompleteArchiveExporter.Root("data/Woona", root) { !CompleteArchiveExporter.isDatabaseFile(it) },
                        CompleteArchiveExporter.Root("data/legacy", context.filesDir, CompleteArchiveExporter::isLegacyData),
                        CompleteArchiveExporter.Root("data/recovered-cache", context.cacheDir, CompleteArchiveExporter::isLegacyData),
                    )
                    return CompleteArchiveExporter().export(
                        roots, snapshot, File(directory, "Woona-All-Data-${System.currentTimeMillis()}.zip"), metadata,
                        checkCancelled = checkCancelled,
                        checkDatabaseUnchanged = {
                            if (version() != before) throw IOException("Local database changed during export. Original data is safe. Wait for recording, editing and synchronization to finish, then retry.")
                        }, onProgress = onProgress,
                    )
                }
            } catch (error: Throwable) {
                directory.deleteRecursively()
                throw error
            } finally { snapshot.delete() }
        }
    } finally {
        if (acquired) serverOperationLock.unlock()
        synchronized(completeArchiveLifecycleLock) { isCompleteArchiveExporting = false }
    }
}

internal fun completeArchiveMetadata(snapshot: File, root: File): String =
    SQLiteDatabase.openDatabase(snapshot.path, null, SQLiteDatabase.OPEN_READONLY).use { database ->
        val result = JSONObject()
        val counts = JSONObject()
        database.rawQuery("PRAGMA quick_check", null).use {
            if (!it.moveToFirst() || it.getString(0) != "ok") throw IOException("SQLite snapshot failed its integrity check. Export was not created; original data is unchanged.")
        }
        database.rawQuery("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name", null).use { tables ->
            while (tables.moveToNext()) {
                val table = tables.getString(0)
                val escaped = table.replace("\"", "\"\"")
                database.rawQuery("SELECT count(*) FROM \"$escaped\"", null).use { rows -> rows.moveToFirst(); counts.put(table, rows.getLong(0)) }
            }
        }
        val unfinished = JSONArray()
        database.rawQuery("SELECT id,status FROM recordings WHERE status IN ('preparing','recording') ORDER BY id", null).use { rows ->
            while (rows.moveToNext()) unfinished.put(JSONObject().put("recordingId", rows.getString(0)).put("savedStatus", rows.getString(1))
                .put("reason", "Unfinalized history is included as saved; it may be left by an interrupted process. No active capture is inferred from database status."))
        }
        val missing = JSONArray()
        database.rawQuery("SELECT id,recording_id,relative_path,size_bytes,sha256 FROM artifacts ORDER BY relative_path", null).use { values ->
            while (values.moveToNext()) {
                val relative = values.getString(2)
                val file = File(root, relative).canonicalFile
                if (!file.toPath().startsWith(root.canonicalFile.toPath())) throw IOException("Artifact path escapes local data root")
                if (!file.isFile) missing.put(JSONObject().put("artifactId", values.getString(0)).put("recordingId", values.getString(1))
                    .put("path", "data/Woona/$relative").put("expectedBytes", values.getLong(3)).put("expectedSha256", values.getString(4))
                    .put("reason", "not_available_locally_deleted_or_server_only"))
            }
        }
        result.put("snapshot", "data/Woona/woona.sqlite").put("integrityCheck", "ok").put("counts", counts)
            .put("unavailableLocalArtifacts", missing).put("unavailableLocalArtifactCount", missing.length())
            .put("unfinalizedRecordings", unfinished).put("unfinalizedRecordingCount", unfinished.length()).toString()
    }

internal fun createDatabaseSnapshot(source: SQLiteDatabase, destination: File) {
    source.execSQL("VACUUM INTO ?", arrayOf(destination.absolutePath))
}
