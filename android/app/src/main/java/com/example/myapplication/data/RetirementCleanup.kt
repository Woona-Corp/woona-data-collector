package com.example.myapplication.data

import android.content.ContentValues
import android.database.sqlite.SQLiteDatabase
import java.io.File
import java.time.Instant
import java.util.UUID

/** Retirement is authoritative; pending entries mean only physical cleanup remains. */
data class RetirementCleanupStatus(val pending: Int, val lastError: String? = null, val deferredCount: Int = 0)

internal fun createRetirementCleanupTable(db: SQLiteDatabase) {
    db.execSQL("""CREATE TABLE IF NOT EXISTS deferred_retirements (
        kind TEXT NOT NULL CHECK(kind IN ('recording','dog','profile','artifact')),
        id_sha256 TEXT NOT NULL,
        received_at_utc TEXT NOT NULL,
        PRIMARY KEY(kind,id_sha256)
    )""")
    db.execSQL("""CREATE TABLE IF NOT EXISTS local_deletion_outbox (
        id TEXT PRIMARY KEY,
        relative_path TEXT NOT NULL,
        entry_kind TEXT NOT NULL CHECK(entry_kind IN ('directory','file')),
        created_at_utc TEXT NOT NULL,
        last_error TEXT,
        UNIQUE(relative_path,entry_kind)
    )""")
}

/** Validate every target before the retirement transaction can commit. */
internal fun WoonaDatabase.enqueueRetirementCleanup(db: SQLiteDatabase, file: File, directory: Boolean) {
    val root = rootDirectory.canonicalFile.toPath()
    val target = file.canonicalFile.toPath()
    val recordings = root.resolve("recordings")
    require(target.startsWith(recordings) && target != recordings) { "Retirement target must be inside a recording directory" }
    val relative = root.relativize(target).toString().replace(File.separatorChar, '/')
    db.insertWithOnConflict("local_deletion_outbox", null, ContentValues().apply {
        put("id", UUID.randomUUID().toString())
        put("relative_path", relative)
        put("entry_kind", if (directory) "directory" else "file")
        put("created_at_utc", Instant.now().toString())
    }, SQLiteDatabase.CONFLICT_IGNORE).also {
        // CONFLICT_IGNORE is permitted only for the same durable intent.
        check(it != -1L || db.rawQuery("SELECT 1 FROM local_deletion_outbox WHERE relative_path=? AND entry_kind=?",
            arrayOf(relative, if (directory) "directory" else "file")).use { cursor -> cursor.moveToFirst() }) { "Could not persist retirement cleanup intent" }
    }
}

fun WoonaDatabase.retirementCleanupStatus(): RetirementCleanupStatus = readableDatabase.rawQuery(
    "SELECT COUNT(*),(SELECT last_error FROM local_deletion_outbox WHERE last_error IS NOT NULL ORDER BY created_at_utc,id LIMIT 1),(SELECT COUNT(*) FROM deferred_retirements) FROM local_deletion_outbox", null,
).use { it.moveToFirst(); RetirementCleanupStatus(it.getInt(0), if (it.isNull(1)) null else it.getString(1), it.getInt(2)) }

/** Caller serializes against capture/server mutations. Never unlink before SQL commit.
 * A failed/partial unlink leaves its durable intent for startup or explicit retry. */
fun WoonaDatabase.retryRetirementCleanup(
    deleteEntry: (File, Boolean) -> Boolean = { file, directory -> if (directory) file.deleteRecursively() else file.delete() },
): RetirementCleanupStatus {
    check(!writableDatabase.inTransaction()) { "Retirement cleanup requires a committed database transaction" }
    data class Entry(val id: String, val path: String, val directory: Boolean)
    val entries = readableDatabase.rawQuery("SELECT id,relative_path,entry_kind FROM local_deletion_outbox ORDER BY created_at_utc,id", null).use { cursor ->
        buildList { while (cursor.moveToNext()) add(Entry(cursor.getString(0), cursor.getString(1), cursor.getString(2) == "directory")) }
    }
    entries.forEach { entry ->
        try {
            val root = rootDirectory.canonicalFile.toPath()
            val lexical = File(root.toFile(), entry.path).absoluteFile.toPath().normalize()
            val canonical = lexical.toFile().canonicalFile.toPath()
            val recordings = root.resolve("recordings")
            require(canonical.startsWith(recordings) && canonical != recordings && canonical == lexical) { "Cleanup path escapes storage, names its root, or changed through a symbolic link" }
            readableDatabase.rawQuery("SELECT status,relative_directory FROM recordings", null).use { cursor ->
                while (cursor.moveToNext()) {
                    val retained = recordingDirectory(cursor.getString(1)).toPath()
                    require(!entry.directory || (!retained.startsWith(canonical) && !canonical.startsWith(retained))) { "Cleanup directory overlaps a retained recording" }
                    require(cursor.getString(0) !in setOf("preparing", "recording") || !canonical.startsWith(retained)) { "Cleanup target overlaps active capture" }
                }
            }
            if (!entry.directory) readableDatabase.rawQuery("SELECT relative_path FROM artifacts", null).use { cursor ->
                while (cursor.moveToNext()) require(resolveRelativePath(cursor.getString(0)).toPath() != canonical) { "Cleanup file is still referenced by a retained artifact" }
            }
            val file = canonical.toFile()
            check(!file.exists() || deleteEntry(file, entry.directory) || !file.exists()) { "Local cleanup failed: ${entry.path}" }
            writableDatabase.delete("local_deletion_outbox", "id=?", arrayOf(entry.id))
        } catch (error: Exception) {
            writableDatabase.update("local_deletion_outbox", ContentValues().apply {
                put("last_error", (error.message ?: error.javaClass.simpleName).take(2000))
            }, "id=?", arrayOf(entry.id))
        }
    }
    return retirementCleanupStatus()
}
