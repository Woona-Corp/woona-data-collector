package com.example.myapplication.data

import android.content.ContentValues
import android.database.sqlite.SQLiteDatabase
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.security.MessageDigest
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** SQL snapshots are created on an empty DB. Provenance/limits are in assets/migrations/README.md. */
@RunWith(AndroidJUnit4::class)
class HistoricalMigrationMatrixTest {
    @Test fun reconstructedV1LegacyTablesUpgradeWithoutLosingOriginals() = verify(1)
    @Test fun reconstructedV2LegacyTablesUpgradeWithoutLosingOriginals() = verify(2)
    @Test fun reconstructedV3RepairsMissingSyncAndPreservesOriginals() = verify(3)
    @Test fun reconstructedV4RepairsProfileHashAndPreservesOriginals() = verify(4)
    @Test fun publishedV5UpgradesArtifactsWithoutLosingOffsets() = verify(5)
    @Test fun publishedV6UpgradesAccountsWithoutLosingOffsets() = verify(6)
    @Test fun publishedV7AddsDurableRetirementWithoutLosingOwnership() = verify(7)
    @Test fun publishedV8ReopensWithoutChangingRowsOrFiles() = verify(8)

    private fun verify(version: Int) {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val root = File(context.cacheDir, "migration-matrix-$version-${java.util.UUID.randomUUID()}").apply { mkdirs() }
        val dogId = "00000000-0000-0000-0000-000000000001"
        val recordingId = "00000000-0000-0000-0000-000000000002"
        val profileId = "00000000-0000-0000-0000-000000000003"
        val directory = "recordings/$dogId/2026-07-01/$recordingId"
        val packet = File(root, "$directory/packets.bin").apply { parentFile!!.mkdirs(); writeBytes(ByteArray(257) { (it % 253).toByte() }) }
        val video = File(root, "$directory/video.mp4").apply { writeBytes(ByteArray(4099) { (it % 197).toByte() }) }
        val packetBytes = packet.readBytes(); val videoBytes = video.readBytes()
        val packetHash = digest(packetBytes); val videoHash = digest(videoBytes)
        val started = "2026-07-01T12:34:56.123456Z"
        val dogJson = """{"schemaVersion":1,"numberOrName":"Historical synthetic dog","shelterOrPlace":"Synthetic shelter","breedStatus":"unknown","size":"medium","ageStatus":"unknown","ageSource":"unknown","sex":"unknown","sterilizationStatus":"unknown","weightStatus":"unknown","bodyConditionStatus":"unable","muscleMass":"unable","neckCircumferenceStatus":"not_measured","coatLength":"unknown","undercoat":"unknown","shavedAreasStatus":"unknown","observedSigns":["none"],"diagnosesStatus":"unknown","housing":"unknown","walksStatus":"unknown","cohabitants":"unknown","shelterPermission":"unknown","notesStatus":"none"}"""
        val sessionJson = """{"schemaVersion":1,"sessionLabel":"Historical session","operatorName":"Synthetic operator","activityGroup":"stationary","activityType":"rest","location":"indoors","surface":"concrete","airTemperatureStatus":"not_measured","sensorPosition":"dorsal_neck","collarTightness":"snug","preMeasurementState":"rest","pulseStatus":"not_measured","respirationStatus":"not_measured","bodyTemperatureStatus":"not_measured","videoRequested":true}"""
        val anchor = 9_007_199_254_740_999L
        try {
            SQLiteDatabase.openOrCreateDatabase(File(root, "woona.sqlite"), null).use { old ->
                val ddl = InstrumentationRegistry.getInstrumentation().context.assets.open("migrations/schema-v$version.sql").bufferedReader().use { it.readText() }
                ddl.lineSequence().filterNot { it.trimStart().startsWith("--") }.joinToString("\n").split(';').map(String::trim).filter(String::isNotEmpty).forEach(old::execSQL)
                assertEquals(version, old.version)
                if (version <= 2) {
                    old.insertOrThrow("dog_profiles", null, values("id" to dogId, "number_or_name" to "Historical synthetic dog", "questionnaire_json" to dogJson, "created_at_utc" to started, "updated_at_utc" to started))
                    old.insertOrThrow("recordings", null, values("id" to recordingId, "profile_id" to dogId, "source" to "live", "status" to "failed", "started_at_utc" to started, "ended_at_utc" to null, "timezone" to "Europe/Moscow", "questionnaire_json" to sessionJson, "relative_directory" to directory))
                } else {
                    old.insertOrThrow("dogs", null, values("id" to dogId, "number_or_name" to "Historical synthetic dog", "created_at_utc" to started, "updated_at_utc" to started).apply { if (version >= 7) put("account_id", "historical-account") })
                    old.insertOrThrow("dog_profile_versions", null, values("id" to profileId, "dog_id" to dogId, "schema_version" to if (version == 3) 0 else 1, "validation_state" to "legacy_incomplete", "questionnaire_json" to dogJson, "content_sha256" to if (version <= 4) "f".repeat(64) else canonicalJsonSha256(dogJson), "client_created_at_utc" to started))
                    old.insertOrThrow("recordings", null, values("id" to recordingId, "dog_id" to dogId, "dog_profile_version_id" to profileId, "source" to "live", "status" to "failed", "session_label" to "Historical session", "questionnaire_schema_version" to if (version == 3) 0 else 1, "questionnaire_validation_state" to "legacy_incomplete", "questionnaire_json" to sessionJson, "video_requested" to 1, "started_at_utc" to started, "ended_at_utc" to null, "timezone" to "Europe/Moscow", "app_version" to "historical-$version", "capture_error_code" to "gatt_error", "capture_error_message" to "GATT status 8", "relative_directory" to directory, "client_created_at_utc" to started).apply { if (version >= 7) { put("remote_copy", 1); put("questionnaire_revision", 7) } })
                    if (version >= 4) old.insertOrThrow("recording_sync", null, values("recording_id" to recordingId, "schema_version" to 2, "monotonic_clock" to "ios.CMClock.hostTime", "session_zero_at_utc" to started, "session_zero_wall_clock_ms" to 1_782_909_296_123L, "session_zero_monotonic_ns" to anchor, "session_zero_uncertainty_ns" to 456L, "first_sensor_packet_monotonic_ns" to anchor + 10, "video_offset_from_sensor_ns" to -12345L, "camera_clock_quality" to "hardware_monotonic", "sensor_clock_quality" to "first_packet_arrival", "overall_sync_quality" to "arrival_aligned", "updated_at_utc" to started))
                    old.insertOrThrow("server_sync_state", null, values("recording_id" to recordingId, "state" to "retryable_error", "attempt_count" to 3, "last_error_code" to "fixture_error", "last_error_message" to "Preserve diagnostic", "server_receipt_sha256" to "b".repeat(64), "updated_at_utc" to started))
                }
                listOf(packet to packetHash, video to videoHash).forEachIndexed { index, (file, hash) ->
                    val relative = root.toPath().relativize(file.toPath()).toString()
                    old.insertOrThrow("artifacts", null, values("id" to "00000000-0000-0000-0000-00000000001$index", "recording_id" to recordingId, "type" to if (index == 0) "packet" else "video", "relative_path" to relative, "size_bytes" to file.length(), "created_at_utc" to started).apply { if (version >= 3) { put("file_name", file.name); put("mime_type", if(index == 0) "application/octet-stream" else "video/mp4"); put("sha256", hash); put("hash_state", "verified"); put("local_presence", "local"); put("upload_state", "uploading"); put("uploaded_bytes", 17L) } })
                }
            }
            repeat(2) { pass ->
                WoonaDatabase(context, root).use { database ->
                    assertEquals(8, database.readableDatabase.version)
                    val profile = requireNotNull(database.profile(dogId)); val recording = requireNotNull(database.recording(recordingId))
                    assertEquals("Historical synthetic dog", profile.numberOrName)
                    assertEquals(if(version >= 7) "historical-account" else null, profile.accountId)
                    if (version >= 3) assertEquals(profileId, profile.profileVersionId)
                    assertEquals(dogId, recording.profileId); assertEquals(RecordingStatus.FAILED, recording.status)
                    assertNull("An unknown historical end must remain unknown", recording.endedAtUtc)
                    assertEquals(started, recording.startedAtUtc); assertEquals("Europe/Moscow", recording.timezone)
                    assertEquals("Historical session", recording.sessionLabel)
                    assertEquals(2, recording.artifacts.size)
                    assertArrayEquals(packetBytes, packet.readBytes()); assertArrayEquals(videoBytes, video.readBytes())
                    if (version <= 2 && pass == 0) assertEquals(2, database.hashPendingArtifacts())
                    val currentArtifacts = requireNotNull(database.recording(recordingId)).artifacts
                    assertEquals(packetHash, currentArtifacts.single { it.type == ArtifactType.PACKET }.sha256)
                    assertEquals(videoHash, currentArtifacts.single { it.type == ArtifactType.VIDEO }.sha256)
                    if(version >= 3) {
                        assertTrue(currentArtifacts.all { it.uploadedBytes == 17L && it.uploadState == "uploading" })
                        assertEquals("gatt_error", recording.captureErrorCode); assertEquals("GATT status 8", recording.captureErrorMessage)
                        assertEquals(if(version <= 4) "pending" else "retryable_error", recording.serverSyncState)
                        assertEquals(if(version <= 4) null else "Preserve diagnostic", recording.serverSyncError)
                        assertEquals("b".repeat(64), recording.serverReceiptSha256)
                    }
                    assertEquals(if(version >= 7) 7 else 1, recording.questionnaireRevision)
                    assertEquals(version >= 7, recording.remoteOrigin)
                    database.readableDatabase.rawQuery("SELECT questionnaire_json,content_sha256 FROM dog_profile_versions WHERE dog_id=?", arrayOf(dogId)).use { c -> c.moveToFirst(); assertEquals(dogJson,c.getString(0)); assertEquals(canonicalJsonSha256(dogJson),c.getString(1)) }
                    database.readableDatabase.rawQuery("SELECT session_zero_monotonic_ns,video_offset_from_sensor_ns,monotonic_clock FROM recording_sync WHERE recording_id=?", arrayOf(recordingId)).use { c ->
                        assertTrue(c.moveToFirst()); assertEquals(if(version >= 4) anchor else 0L,c.getLong(0))
                        if(version >= 4) { assertEquals(-12345L,c.getLong(1)); assertEquals("ios.CMClock.hostTime",c.getString(2)) }
                    }
                    database.readableDatabase.rawQuery("PRAGMA integrity_check",null).use { c -> assertTrue(c.moveToFirst());assertEquals("ok",c.getString(0)) }
                    database.readableDatabase.rawQuery("PRAGMA foreign_key_check",null).use { c -> assertFalse(c.moveToFirst()) }
                }
            }
        } finally { root.deleteRecursively() }
    }

    private fun values(vararg fields: Pair<String, Any?>) = ContentValues().apply {
        fields.forEach { (key,value) -> when(value) { null -> putNull(key);is String -> put(key,value);is Int -> put(key,value);is Long -> put(key,value);else -> error("Unsupported fixture value") } }
    }
    private fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
}
