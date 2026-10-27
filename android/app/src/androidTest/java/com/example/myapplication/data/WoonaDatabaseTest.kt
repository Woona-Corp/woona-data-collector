package com.example.myapplication.data

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.io.File
import java.time.Instant
import java.time.ZoneId
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.json.JSONObject

@RunWith(AndroidJUnit4::class)
class WoonaDatabaseTest {
    @Test
    fun captureFailureIsVisibleInHistoryAfterRestartEvenWhenSynced() {
        val dog = database.saveProfile(completeDogQuestionnaire("Capture failure"))
        val session = database.beginRecording(dog.id, RecordingSource.LIVE, completeSessionQuestionnaire())
        database.markCaptureError(session.id, "gatt_error", "Ошибка GATT-подключения: 8")
        database.finishRecording(session.id, RecordingStatus.FAILED)
        database.markRecordingSyncError(session.id, false, "http_401", "invalid_bearer_token")
        database.close()
        database = WoonaDatabase(ApplicationProvider.getApplicationContext(), root)
        val history = database.recentRecordings(dog.id).single()
        assertEquals("gatt_error", history.captureErrorCode)
        assertEquals("Ошибка GATT-подключения: 8", history.captureErrorMessage)
        assertEquals("invalid_bearer_token", history.serverSyncError)
        assertEquals("permanent_error", history.serverSyncState)
    }

    @Test
    fun terminalImportedUnknownEndCanEditAndAttachReferenceWithoutInventingEndTime() {
        val dog = database.saveProfile(completeDogQuestionnaire("Imported"))
        val original = completeSessionQuestionnaire()
        val session = database.beginRecording(dog.id, RecordingSource.LIVE, original)
        database.writableDatabase.execSQL("UPDATE recordings SET status='completed', ended_at_utc=NULL WHERE id=?", arrayOf(session.id))
        database.saveSessionQuestionnaire(session.id, requireNotNull(database.recording(session.id)?.questionnaire).copy(sessionLabel = "Edited import"))
        assertEquals("Edited import", database.recording(session.id)?.sessionLabel)
        assertEquals(null, database.recording(session.id)?.endedAtUtc)
        val metadata = ReferenceMetadata("Synthetic reference", "2026-10-25T10:00:00Z", "2026-10-25T10:01:00Z", null, null)
        database.attachReference(session.id, ArtifactType.RR, "fixture.csv", "utc,rr\n0,800\n".byteInputStream(), metadata)
        assertEquals(1, database.recording(session.id)?.artifacts?.count { it.type == ArtifactType.RR })
        assertEquals(null, database.recording(session.id)?.endedAtUtc)
        database.writableDatabase.execSQL("UPDATE recordings SET status='recording' WHERE id=?", arrayOf(session.id))
        try { database.saveSessionQuestionnaire(session.id, original); throw AssertionError("Active capture must stay protected") }
        catch (_: IllegalArgumentException) { }
    }

    private fun verifiedLocalAndRemote(): Pair<RecordingSyncRecord, RemoteRecording> {
        val initial = completedPacketRecording("Remove local")
        val full = requireNotNull(database.recordingSyncRecord(initial.id))
        val remote = remoteCompletedRecording(full)
        database.restoreServerMetadata(emptyList(), listOf(remote))
        assertEquals("synced", database.recording(full.id)?.serverSyncState)
        return full to remote
    }

    @Test
    fun terminalImportedSessionsWithoutMachineEndCanRemoveOnlyVerifiedLocalFiles() {
        for (status in listOf("completed", "failed", "interrupted")) {
            val (local, original) = verifiedLocalAndRemote()
            val remote = original.copy(endedAtUtc = null, captureStatus = status)
            database.writableDatabase.execSQL("UPDATE recordings SET ended_at_utc=NULL,status=? WHERE id=?", arrayOf(status, local.id))
            assertTrue(database.removeLocalRecordingFiles(local.id, remote) > 0)
            assertEquals(null, database.recording(local.id)?.endedAtUtc)
            assertEquals(status, database.recording(local.id)?.status?.value)
            assertEquals("synced", database.recording(local.id)?.serverSyncState)
        }
    }

    @Test
    fun missingMachineEndNeverMakesActiveOrServerMissingSessionRemovable() {
        val (local, original) = verifiedLocalAndRemote()
        val remote = original.copy(endedAtUtc = null)
        for (status in listOf("preparing", "recording")) {
            database.writableDatabase.execSQL("UPDATE recordings SET ended_at_utc=NULL,status=? WHERE id=?", arrayOf(status, local.id))
            org.junit.Assert.assertThrows(IllegalArgumentException::class.java) { database.removeLocalRecordingFiles(local.id, remote) }
            assertTrue(local.artifacts.all { database.resolveRelativePath(it.relativePath).isFile })
        }
        database.writableDatabase.execSQL("UPDATE recordings SET status='completed' WHERE id=?", arrayOf(local.id))
        val missing = remote.copy(artifacts = remote.artifacts.map { it.copy(storageStatus = "missing") })
        org.junit.Assert.assertThrows(IllegalArgumentException::class.java) { database.removeLocalRecordingFiles(local.id, missing) }
        assertTrue(local.artifacts.all { database.resolveRelativePath(it.relativePath).isFile })
    }

    @Test
    fun freshReceiptStatusRequiresCurrentVerifiedFilesAndStrictJsonBooleans() {
        val status = JSONObject("""{"ingestStatus":"complete","transfer":{"receiptVerified":true},"artifacts":[{"storageStatus":"available","verified":true,"errorCode":null}]}""")
        assertTrue(com.example.myapplication.sync.confirmsCurrentServerCopy(status))
        status.getJSONArray("artifacts").getJSONObject(0).put("storageStatus", "missing")
        assertTrue(!com.example.myapplication.sync.confirmsCurrentServerCopy(status))
        status.getJSONArray("artifacts").getJSONObject(0).put("storageStatus", "available").put("verified", "true")
        assertTrue(!com.example.myapplication.sync.confirmsCurrentServerCopy(status))
        status.getJSONArray("artifacts").getJSONObject(0).put("verified", true)
        status.getJSONObject("transfer").put("receiptVerified", "true")
        assertTrue(!com.example.myapplication.sync.confirmsCurrentServerCopy(status))
        assertTrue(!com.example.myapplication.sync.confirmsCurrentServerCopy(JSONObject("""{"transfer":{"receiptVerified":true}}""")))
    }

    @Test
    fun removeVerifiedLocalFilesKeepsHistoryAndAllowsDownloadAgain() {
        val (local, remote) = verifiedLocalAndRemote()
        val packet = database.resolveRelativePath(local.artifacts.first { it.type == "packet" }.relativePath)
        val original = packet.readBytes()
        val unregistered = File(packet.parentFile, "operator-note.txt").apply { writeText("Keep this local note") }
        assertTrue(database.removeLocalRecordingFiles(local.id, remote) > 0)
        assertTrue(!packet.exists())
        assertEquals("Keep this local note", unregistered.readText())
        assertEquals("synced", database.recording(local.id)?.serverSyncState)
        assertEquals(local.profileVersionId, database.recording(local.id)?.profileVersionId)
        assertTrue(database.profile(local.dogId) != null)
        assertTrue(database.recording(local.id)!!.artifacts.all { it.localPresence == "remote_only" })
        val missing = database.remoteArtifacts(local.id)
        assertEquals(local.artifacts.size, missing.size)
        val artifact = missing.first { it.type == ArtifactType.PACKET }
        database.artifactDownloadTarget(artifact).writeBytes(original)
        database.markArtifactDownloaded(artifact.id)
        assertEquals("both", database.recording(local.id)!!.artifacts.first { it.id == artifact.id }.localPresence)
        assertTrue(packet.exists())
    }

    @Test
    fun removingUnsyncedOrUnverifiedSessionNeverDeletesFiles() {
        val initial = completedPacketRecording("Pending local")
        val full = requireNotNull(database.recordingSyncRecord(initial.id))
        val remote = remoteCompletedRecording(full)
        org.junit.Assert.assertThrows(IllegalArgumentException::class.java) { database.removeLocalRecordingFiles(full.id, remote) }
        assertTrue(full.artifacts.all { database.resolveRelativePath(it.relativePath).isFile })
        database.restoreServerMetadata(emptyList(), listOf(remote))
        org.junit.Assert.assertThrows(IllegalArgumentException::class.java) { database.removeLocalRecordingFiles(full.id, remote.copy(receiptSha256 = null)) }
        org.junit.Assert.assertThrows(IllegalArgumentException::class.java) { database.removeLocalRecordingFiles(full.id, remote.copy(artifacts = remote.artifacts.dropLast(1))) }
        assertTrue(full.artifacts.all { database.resolveRelativePath(it.relativePath).isFile })
    }

    @Test
    fun missingUploadedCacheFileIsOfferedForDownloadAfterRestart() {
        val (local, _) = verifiedLocalAndRemote()
        val packet = local.artifacts.first { it.type == "packet" }
        assertTrue(database.resolveRelativePath(packet.relativePath).delete())
        database.close()
        database = WoonaDatabase(ApplicationProvider.getApplicationContext(), root)
        assertEquals("remote_only", database.recording(local.id)!!.artifacts.first { it.id == packet.id }.localPresence)
        assertTrue(database.remoteArtifacts(local.id).any { it.id == packet.id })
    }

    @Test
    fun changedLocalFileBlocksDeletionOfEveryArtifact() {
        val (local, remote) = verifiedLocalAndRemote()
        val packet = database.resolveRelativePath(local.artifacts.first { it.type == "packet" }.relativePath)
        packet.writeText("packet datX") // Same size, different SHA-256.
        org.junit.Assert.assertThrows(IllegalArgumentException::class.java) { database.removeLocalRecordingFiles(local.id, remote) }
        assertEquals("packet datX", packet.readText())
        assertTrue(local.artifacts.all { database.resolveRelativePath(it.relativePath).isFile })
        assertTrue(database.recording(local.id)!!.artifacts.none { it.localPresence == "remote_only" })
    }

    @Test
    fun accountOwnershipPersistsAndLinkIncludesAllSessions() {
        val old = database.saveProfile(completeDogQuestionnaire("Unassigned"))
        val one = database.beginRecording(old.id, RecordingSource.LIVE, completeSessionQuestionnaire())
        database.finishRecording(one.id, RecordingStatus.COMPLETED)
        val other = database.saveProfile(completeDogQuestionnaire("Other"), accountId = "other")
        database.linkDogAccount(old.id, " First ")
        assertEquals("first", database.profile(requireNotNull(database.recording(one.id)).profileId)?.accountId)
        assertEquals("other", database.profile(other.id)?.accountId)
        org.junit.Assert.assertThrows(IllegalArgumentException::class.java) { database.linkDogAccount(old.id, "other") }
        database.close()
        database = WoonaDatabase(ApplicationProvider.getApplicationContext(), root)
        assertEquals("first", database.profile(old.id)?.accountId)
        assertEquals(one.id, database.recentRecordings(old.id).single().id)
    }

    @Test
    fun editingLocalQuestionnairePreservesCaptureFields() {
        val dog = database.saveProfile(completeDogQuestionnaire("Edit"))
        val session = completeSessionQuestionnaire()
        val record = database.beginRecording(dog.id, RecordingSource.LIVE, session)
        database.finishRecording(record.id, RecordingStatus.COMPLETED)
        val initial = requireNotNull(database.recording(record.id)?.questionnaire)
        database.saveSessionQuestionnaire(record.id, initial.copy(sessionLabel = "Edited"))
        assertEquals("Edited", database.recording(record.id)?.questionnaire?.sessionLabel)
        org.junit.Assert.assertThrows(IllegalArgumentException::class.java) {
            database.saveSessionQuestionnaire(record.id, initial.copy(videoRequested = !initial.videoRequested))
        }
    }

    @Test
    fun completedRestoreUpdatesEditedSessionLabelAndRevision() {
        val local = completedPacketRecording("Restore edit")
        val original = requireNotNull(database.recording(local.id)?.questionnaire)
        val remote = remoteCompletedRecording(local).copy(
            sessionLabel = "Remote edited", sessionQuestionnaireJson = original.copy(sessionLabel = "Remote edited").toJson(), questionnaireRevision = 2)
        database.restoreServerMetadata(emptyList(), listOf(remote))
        assertEquals("Remote edited", database.recording(local.id)?.sessionLabel)
        assertEquals(2, database.recording(local.id)?.questionnaireRevision)
    }

    @Test
    fun staleRemoteOwnerCannotRemoveLocalAssignmentOrSessions() {
        val local = completedPacketRecording("Owned")
        database.linkDogAccount(local.dogId, "first")
        val stale = remoteCompletedRecording(local)
        val result = database.restoreServerMetadata(listOf(RemoteDog(local.dogId, "Stale", 1, stale.profile)), listOf(stale))
        assertEquals("first", database.profile(local.dogId)?.accountId)
        assertEquals(local.id, database.recording(local.id)?.id)
        assertEquals("packet data", database.resolveRelativePath(local.artifacts.single().relativePath).readText())
        assertTrue(result.conflicts > 0)
    }

    @Test
    fun restoredIncompleteCaptureDoesNotQueueButOriginKeepsQueue() {
        val origin = completedPacketRecording("Origin pending")
        database.hashPendingArtifacts()
        val remote = remoteCompletedRecording(origin).copy(id = "remote-incomplete", receiptSha256 = null, verifiedAtUtc = null,
            artifacts = origin.artifacts.map { RemoteArtifact("remote-${it.id}", it.type, it.fileName, it.mimeType, it.sizeBytes, it.sha256, "uploading") })
        database.restoreServerMetadata(emptyList(), listOf(remote))
        assertEquals(origin.sessionQuestionnaireJson, database.recording(remote.id)?.questionnaire?.toJson())
        assertTrue(origin.id in database.pendingRecordingIds())
        assertTrue(remote.id !in database.pendingRecordingIds())
    }

    @Test
    fun unchangedAnswersDoNotCreateAnotherProfileVersion() {
        val original = database.saveProfile(completeDogQuestionnaire("Unchanged"))
        val saved = database.saveProfile(original.questionnaire.copy(savedAtLocal = "2026-10-09T12:00:00"),original.id)
        assertEquals(original.profileVersionId,saved.profileVersionId)
    }

    @Test
    fun questionnairesMatchSharedServerFixtures() {
        val assets = androidx.test.platform.app.InstrumentationRegistry.getInstrumentation().context.assets
        val cases = org.json.JSONArray(assets.open("questionnaires-v2.json").bufferedReader().use { it.readText() })
        repeat(cases.length()) { index ->
            val item = cases.getJSONObject(index)
            val json = item.getJSONObject("questionnaire").toString()
            val valid = if (item.getString("kind") == "dog") dogQuestionnaireFromJson(json).validate().isValid
                else sessionQuestionnaireFromJson(json).validate().isValid
            assertEquals(item.getBoolean("valid"), valid)
        }
    }

    private lateinit var root: File
    private lateinit var database: WoonaDatabase

    @Before
    fun setUp() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        root = File(context.cacheDir, "woona-db-test-${System.nanoTime()}")
        database = WoonaDatabase(context, root)
    }

    @After
    fun tearDown() {
        database.close()
        root.deleteRecursively()
    }

    @Test
    fun heartSessionWaitsForAnswersAndKeepsReferencesAfterRestart() {
        val profile = database.saveProfile(completeDogQuestionnaire("Heart dog"))
        val session = SessionQuestionnaire(schemaVersion = 2, sessionLabel = "Heart", sessionKind = "heart", videoRequested = false)
        val recording = database.beginRecording(profile.id, RecordingSource.LIVE, session)
        database.finishRecording(recording.id, RecordingStatus.COMPLETED)
        assertTrue(database.pendingRecordingIds().isEmpty())
        val heart = HeartQuestionnaire(
            answers = HEART_OPTIONS.keys.filter { it != "acuteHeartRateFactors" }.associateWith { "unknown" },
            acuteHeartRateFactors = listOf("unknown"),
        )
        database.saveHeartQuestionnaire(recording.id, heart)
        assertEquals(listOf(recording.id), database.pendingRecordingIds())
        val bytes = "utc,bpm\n2026-10-05T12:00:00Z,120\n".toByteArray()
        val metadata = ReferenceMetadata("Polar H10", "2026-10-05T12:00:00Z", "2026-10-05T12:01:00Z", 0.0)
        database.attachReference(recording.id, ArtifactType.HEART_RATE, "hr.csv", bytes.inputStream(), metadata)
        database.hashPendingArtifacts()
        database.close()
        database = WoonaDatabase(ApplicationProvider.getApplicationContext(), root)
        val restored = requireNotNull(database.recording(recording.id))
        assertEquals(heart.answers.filterKeys { it != "acuteHeartRateFactors" }, restored.questionnaire?.heartQuestionnaire?.answers)
        val reference = restored.artifacts.single { it.type == ArtifactType.HEART_RATE }
        assertEquals(metadata.toJson(), reference.referenceMetadataJson)
        assertTrue(database.resolveRelativePath(reference.relativePath).readBytes().contentEquals(bytes))
        val serialized = JSONObject(restored.questionnaire!!.toJson()).getJSONObject("heartQuestionnaire")
        assertEquals("Неизвестно", serialized.getJSONObject("referenceMethod").getString("text"))
    }

    @Test
    fun serverDeletionRemovesOnlyRetiredUnitAndIsIdempotent() {
        val profile = database.saveProfile(completeDogQuestionnaire("Delete test"))
        val retired = database.beginRecording(profile.id, RecordingSource.LIVE, completeSessionQuestionnaire())
        database.finishRecording(retired.id, RecordingStatus.COMPLETED)
        val keep = database.beginRecording(profile.id, RecordingSource.LIVE, completeSessionQuestionnaire())
        val hash = java.security.MessageDigest.getInstance("SHA-256").digest(retired.id.toByteArray()).joinToString("") { "%02x".format(it) }
        assertEquals(1, database.applyServerDeletions(listOf("recording" to hash)))
        assertEquals(null, database.recording(retired.id))
        assertTrue(database.recording(keep.id) != null)
        assertEquals(0, database.applyServerDeletions(listOf("recording" to hash)))
    }

    @Test
    fun serverDeletionRejectsRecordingDirectoryThatResolvesToStorageRoot() {
        val profile = database.saveProfile(completeDogQuestionnaire("Corrupt retired path"))
        val retired = database.beginRecording(profile.id, RecordingSource.LIVE, completeSessionQuestionnaire())
        database.finishRecording(retired.id, RecordingStatus.COMPLETED)
        val keep = database.beginRecording(profile.id, RecordingSource.LIVE, completeSessionQuestionnaire())
        val preserved = File(database.recordingDirectory(keep.relativeDirectory), "packets.bin")
        preserved.writeText("unrelated recording")
        database.writableDatabase.execSQL("UPDATE recordings SET relative_directory='.' WHERE id=?", arrayOf(retired.id))
        val hash = java.security.MessageDigest.getInstance("SHA-256").digest(retired.id.toByteArray()).joinToString("") { "%02x".format(it) }

        assertTrue(runCatching { database.applyServerDeletions(listOf("recording" to hash)) }.isFailure)
        assertTrue(root.isDirectory)
        assertEquals("unrelated recording", preserved.readText())
        assertTrue(database.recording(keep.id) != null)
        assertTrue(database.recording(retired.id) != null)
    }

    @Test
    fun profileSyncFailureIsCountedAndCanBeRetriedWithoutRecordings() {
        val profile = database.saveProfile(completeDogQuestionnaire("Mock profile"))
        assertEquals(1, database.serverSyncCounts().pending)
        database.markProfileSyncError(profile.profileVersionId, false, "http_401", "invalid_bearer_token")
        assertEquals(1, database.serverSyncCounts().failed)
        assertEquals("invalid_bearer_token", database.serverSyncCounts().lastErrorMessage)

        database.resetFailedSync()
        assertEquals(1, database.serverSyncCounts().pending)
        assertEquals(0, database.serverSyncCounts().failed)
        assertEquals(null, database.serverSyncCounts().lastErrorMessage)
    }

    @Test
    fun syncFailureShowsPersistedReasonAndClearsAfterRetry() {
        val profile = database.saveProfile(completeDogQuestionnaire("Mock dog"))
        val recording = database.beginRecording(profile.id, RecordingSource.LIVE, completeSessionQuestionnaire())
        database.finishRecording(recording.id, RecordingStatus.COMPLETED)
        database.markRecordingSyncError(recording.id, false, "http_401", "Server returned HTTP 401: invalid_bearer_token")

        assertEquals(1, database.serverSyncCounts().failed)
        assertEquals("Server returned HTTP 401: invalid_bearer_token", database.serverSyncCounts().lastErrorMessage)

        database.markRecordingSyncError(recording.id, true, "network_error", "")
        assertEquals("network_error", database.serverSyncCounts().lastErrorMessage)
        database.resetFailedSync()
        assertEquals(0, database.serverSyncCounts().failed)
        assertEquals(null, database.serverSyncCounts().lastErrorMessage)
    }

    @Test
    fun unreadableArtifactShowsReasonAndCanBeRetried() {
        val profile = database.saveProfile(completeDogQuestionnaire("Mock unreadable file"))
        val recording = database.beginRecording(profile.id, RecordingSource.LIVE, completeSessionQuestionnaire())
        val packet = File(database.recordingDirectory(recording.relativeDirectory), "packets.bin")
        packet.writeBytes(byteArrayOf(1, 2, 3))
        database.finishRecording(recording.id, RecordingStatus.COMPLETED)
        database.writableDatabase.execSQL("UPDATE artifacts SET hash_state='pending' WHERE recording_id=?", arrayOf(recording.id))
        android.system.Os.chmod(packet.absolutePath, 0)
        try {
            val error = runCatching { database.hashPendingArtifacts() }.exceptionOrNull()
            assertTrue(error is java.io.IOException)
            assertEquals(1, database.serverSyncCounts().failed)
            assertTrue(database.serverSyncCounts().lastErrorMessage.orEmpty().contains("EACCES"))
        } finally {
            android.system.Os.chmod(packet.absolutePath, 384)
        }
        database.resetFailedSync()
        database.hashPendingArtifacts()
        assertEquals(0, database.serverSyncCounts().failed)
        assertTrue(database.pendingRecordingIds().contains(recording.id))
    }

    @Test
    fun sheetQuestionnairesPreserveIdentitySurfacesAndHistoricalProfile() {
        val dog = DogQuestionnaire(schemaVersion = 2, animalId = "финик", numberOrName = "Финик", species = "собака",
            diseaseCategory = "Суставы", diagnosesDetails = "Дисплазия", specialistName = "Иван")
        val profile = database.saveProfile(dog)
        assertEquals(dog, dogQuestionnaireFromJson(dog.toJson()))
        val session = SessionQuestionnaire(schemaVersion = 2, sessionLabel = "2", plannedActivities = listOf("Аллюр/движение"),
            surfaces = listOf("Асфальт", "Грунт", "Трава"), sensorPosition = "Снизу на горле", notes = "Заметка")
        assertEquals(session, sessionQuestionnaireFromJson(session.toJson()))
        val recording = database.beginRecording(profile.id, RecordingSource.LIVE, session, ZoneId.of("Europe/Moscow"), Instant.parse("2026-09-04T16:08:00Z"))
        database.finishRecording(recording.id, RecordingStatus.COMPLETED, Instant.parse("2026-09-04T16:10:00Z"))
        val saved = requireNotNull(database.recording(recording.id)).questionnaire!!
        assertEquals("финик", saved.animalId)
        assertEquals(session.surfaces, saved.surfaces)
        assertEquals("19:08", saved.startTime)
        assertEquals("19:10", saved.endTime)
        assertEquals(2.0, saved.durationMinutes!!, 0.0)
        assertEquals(profile.profileVersionId, requireNotNull(database.recording(recording.id)).profileVersionId)
    }

    @Test
    fun profilesRecordingsAndArtifactsRoundTrip() {
        val questionnaire = DogQuestionnaire(
            numberOrName = "D-17",
            shelterOrPlace = "Shelter 1",
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
            observedSigns = listOf("cough", "distress"),
            diagnosesStatus = "unknown",
            housing = "unknown",
            walksStatus = "unknown",
            cohabitants = "unknown",
            shelterPermission = "unknown",
            notesStatus = "none",
        )
        val profile = database.saveProfile(questionnaire, now = Instant.parse("2026-07-28T08:00:00Z"))
        assertEquals(questionnaire, database.profile(profile.id)?.questionnaire)

        val session1 = SessionQuestionnaire(
            sessionLabel = "Baseline",
            operatorName = "Operator",
            activityGroup = "stationary",
            activityType = "rest",
            location = "indoors",
            surface = "concrete",
            airTemperatureStatus = "not_measured",
            sensorPosition = "dorsal_neck",
            collarTightness = "snug",
            preMeasurementState = "rest",
            pulseStatus = "measured",
            pulseBpm = 72,
            respirationStatus = "not_measured",
            bodyTemperatureStatus = "not_measured",
            measurementAtUtc = "2026-07-28T09:29:00Z",
        )
        val session2 = session1.copy(sessionLabel = "Replay")
        val first = database.beginRecording(
            profile.id,
            RecordingSource.LIVE,
            session1,
            ZoneId.of("Europe/Moscow"),
            Instant.parse("2026-07-28T09:30:00Z"),
        )
        val second = database.beginRecording(
            profile.id,
            RecordingSource.REPLAY,
            session2,
            ZoneId.of("Europe/Moscow"),
            Instant.parse("2026-07-28T09:31:00Z"),
        )
        assertNotEquals(first.relativeDirectory, second.relativeDirectory)
        assertTrue(first.relativeDirectory.contains("/2026-07-28/"))

        val firstDirectory = database.recordingDirectory(first.relativeDirectory)
        File(firstDirectory, "packets.bin").writeBytes(byteArrayOf(1, 2, 3))
        File(firstDirectory, "diagnostics.log").writeText("ok")
        File(firstDirectory, "video.mp4").writeBytes(byteArrayOf(4, 5, 6))
        val sensorAnchor = SyncClockAnchor(
            event = "ble_capture_ready",
            absoluteUtc = "2026-07-28T09:30:00Z",
            wallClockEpochMillis = 1_775_899_800_000,
            monotonicTimeNs = 10_000_000_000,
            monotonicClock = "android.elapsedRealtimeNanos",
            samplingUncertaintyNs = 1_000,
        )
        val syncFile = database.writeSyncMetadata(
            first.id,
            CaptureSyncMetadata(
                recordingId = first.id,
                profileId = profile.id,
                source = "live",
                timezone = "Europe/Moscow",
                selectedSessionStartUtc = first.startedAtUtc,
                sensor = sensorAnchor,
                firstSensorDeviceTimerMillis = 321,
                video = VideoSyncMetadata(
                    requestedAtUtc = "2026-07-28T09:30:02Z",
                    requestedMonotonicNs = 12_000_000_000,
                    firstFrameMonotonicNs = 12_250_000_000,
                    firstFrameCameraTimestampNs = 77,
                    firstFrameCallbackMonotonicNs = 12_260_000_000,
                    firstVideoSamplePtsUs = 0,
                    offsetFromSensorNs = 2_250_000_000,
                    cameraTimestampSource = "unknown",
                    synchronizationQuality = "callback_estimate",
                ),
            ),
        )
        val syncJson = JSONObject(syncFile.readText())
        assertEquals(2_250_000_000, syncJson.getJSONObject("video").getLong("offsetFromSensorNs"))
        assertEquals("D-17", syncJson.getJSONObject("dogQuestionnaire").getString("numberOrName"))
        val syncRecord = requireNotNull(database.recordingSyncRecord(first.id))
        assertEquals("callback_estimate", syncRecord.sync.cameraClockQuality)
        assertEquals("callback_estimate", syncRecord.sync.overallSyncQuality)
        assertEquals(321L, syncRecord.sync.firstSensorDeviceTimerMillis)
        assertEquals(12_260_000_000L, syncRecord.sync.videoFirstFrameCallbackMonotonicNs)
        assertEquals(0L, syncRecord.sync.videoFirstSamplePtsUs)
        database.markRecording(first.id)
        database.finishRecording(first.id, RecordingStatus.COMPLETED)

        val recent = database.recentRecordings(profile.id)
        val completed = recent.first { it.id == first.id }
        assertEquals(RecordingStatus.COMPLETED, completed.status)
        assertEquals(
            setOf("packets.bin", "diagnostics.log", "video.mp4", "sync.json"),
            completed.artifacts.map { it.relativePath.substringAfterLast('/') }.toSet(),
        )

        val edited = database.saveProfile(
            questionnaire.copy(numberOrName = "Rex"),
            profileId = profile.id,
        )
        assertEquals(profile.id, edited.id)
        assertNotEquals(profile.profileVersionId, edited.profileVersionId)
        assertEquals(profile.profileVersionId, database.recording(first.id)?.profileVersionId)
        assertEquals(profile.id, database.recording(first.id)?.profileId)

        database.interruptUnfinished()
        assertEquals(RecordingStatus.INTERRUPTED, database.recording(second.id)?.status)

        database.writableDatabase.rawQuery("PRAGMA foreign_keys", null).use {
            assertTrue(it.moveToFirst())
            assertEquals(1, it.getInt(0))
        }
    }

    @Test
    fun v2DatabaseMigratesWithoutLosingProfileRecordingOrArtifact() {
        database.close()
        root.deleteRecursively()
        root.mkdirs()
        val dbFile = File(root, "woona.sqlite")
        android.database.sqlite.SQLiteDatabase.openOrCreateDatabase(dbFile, null).use { legacy ->
            legacy.execSQL(
                "CREATE TABLE dog_profiles(id TEXT PRIMARY KEY,number_or_name TEXT NOT NULL,questionnaire_json TEXT NOT NULL,created_at_utc TEXT NOT NULL,updated_at_utc TEXT NOT NULL)",
            )
            legacy.execSQL(
                "CREATE TABLE recordings(id TEXT PRIMARY KEY,profile_id TEXT NOT NULL REFERENCES dog_profiles(id),source TEXT NOT NULL,status TEXT NOT NULL,started_at_utc TEXT NOT NULL,ended_at_utc TEXT,timezone TEXT NOT NULL,questionnaire_json TEXT,relative_directory TEXT NOT NULL UNIQUE)",
            )
            legacy.execSQL(
                "CREATE TABLE artifacts(id TEXT PRIMARY KEY,recording_id TEXT NOT NULL REFERENCES recordings(id),type TEXT NOT NULL,relative_path TEXT NOT NULL,size_bytes INTEGER NOT NULL,created_at_utc TEXT NOT NULL,UNIQUE(recording_id,relative_path))",
            )
            val legacyDog = """{"numberOrName":"Old Rex","observedSigns":[]}"""
            legacy.execSQL(
                "INSERT INTO dog_profiles VALUES(?,?,?,?,?)",
                arrayOf("dog-1", "Old Rex", legacyDog, "2026-07-01T00:00:00Z", "2026-07-01T00:00:00Z"),
            )
            legacy.execSQL(
                "INSERT INTO recordings VALUES(?,?,?,?,?,?,?,?,?)",
                arrayOf<Any?>(
                    "recording-1",
                    "dog-1",
                    "live",
                    "completed",
                    "2026-07-01T00:00:00Z",
                    "2026-07-01T00:01:00Z",
                    "UTC",
                    null,
                    "recordings/dog-1/2026-07-01/recording-1",
                ),
            )
            val packet = File(root, "recordings/dog-1/2026-07-01/recording-1/packets.bin")
            packet.parentFile?.mkdirs()
            packet.writeBytes(byteArrayOf(1, 2, 3))
            legacy.execSQL(
                "INSERT INTO artifacts VALUES(?,?,?,?,?,?)",
                arrayOf<Any?>("artifact-1", "recording-1", "packet", "recordings/dog-1/2026-07-01/recording-1/packets.bin", 3, "2026-07-01T00:01:00Z"),
            )
            legacy.version = 2
        }

        database = WoonaDatabase(
            ApplicationProvider.getApplicationContext(),
            root,
        )
        assertEquals("Old Rex", database.profile("dog-1")?.numberOrName)
        val migrated = database.recording("recording-1")
        assertEquals(RecordingStatus.COMPLETED, migrated?.status)
        assertEquals("0".repeat(64), migrated?.artifacts?.single()?.sha256)
        assertEquals(1, database.hashPendingArtifacts())
        assertNotEquals("0".repeat(64), database.recording("recording-1")?.artifacts?.single()?.sha256)
        val syncRecord = requireNotNull(database.recordingSyncRecord("recording-1"))
        assertEquals(1, syncRecord.questionnaireSchemaVersion)
        assertEquals("legacy_incomplete", syncRecord.questionnaireValidationState)
        assertEquals("{}", syncRecord.sessionQuestionnaireJson)
        database.readableDatabase.rawQuery("PRAGMA integrity_check", null).use {
            assertTrue(it.moveToFirst())
            assertEquals("ok", it.getString(0))
        }
    }

    @Test
    fun v4DatabaseRepairsCanonicalProfileHashForServerParity() {
        val questionnaire = completeDogQuestionnaire("Hash repair")
        val saved = database.saveProfile(questionnaire)
        database.close()
        val dbFile = File(root, "woona.sqlite")
        android.database.sqlite.SQLiteDatabase.openDatabase(
            dbFile.absolutePath,
            null,
            android.database.sqlite.SQLiteDatabase.OPEN_READWRITE,
        ).use { legacy ->
            legacy.execSQL(
                "UPDATE dog_profile_versions SET content_sha256=?,server_sync_state='permanent_error' WHERE id=?",
                arrayOf("f".repeat(64), saved.profileVersionId),
            )
            legacy.version = 4
        }

        database = WoonaDatabase(ApplicationProvider.getApplicationContext(), root)

        val repaired = requireNotNull(database.profileSyncRecord(saved.profileVersionId))
        assertEquals(canonicalJsonSha256(questionnaire.toJson()), repaired.contentSha256)
        assertEquals(saved.profileVersionId, database.pendingProfileVersionIds().single())
    }

    @Test
    fun canonicalJsonHashMatchesServerFormat() {
        assertEquals(
            "af876e788c47cf273845053cacf80c925cda1119ee33b1dcb40239cf5f64d75d",
            canonicalJsonSha256("""{"b":2,"a":[true,null,"Привет"]}"""),
        )
    }

    @Test
    fun serverMetadataRestore_isIdempotentAndKeepsArtifactsRemoteOnly() {
        val downloadBytes = byteArrayOf(1, 2, 3)
        val downloadHash = java.security.MessageDigest.getInstance("SHA-256").digest(downloadBytes).joinToString("") { "%02x".format(it) }
        val dogJson = completeDogQuestionnaire("Remote Rex").toJson()
        val sessionJson = completeSessionQuestionnaire().toJson()
        val profile = RemoteProfileVersion(
            id = "20000000-0000-0000-0000-000000000001",
            schemaVersion = 1,
            validationState = "complete",
            questionnaireJson = dogJson,
            contentSha256 = canonicalJsonSha256(dogJson),
            clientCreatedAtUtc = "2026-07-30T10:00:00Z",
        )
        val dog = RemoteDog(
            id = "10000000-0000-0000-0000-000000000001",
            numberOrName = "Remote Rex",
            revision = 1,
            profile = profile,
            profileVersions = listOf(
                RemoteProfileVersion(
                    id = "20000000-0000-0000-0000-000000000000",
                    schemaVersion = 1,
                    validationState = "complete",
                    questionnaireJson = completeDogQuestionnaire("Old Remote Rex").toJson(),
                    contentSha256 = canonicalJsonSha256(completeDogQuestionnaire("Old Remote Rex").toJson()),
                    clientCreatedAtUtc = "2026-07-29T10:00:00Z",
                    supersededAtUtc = "2026-07-30T10:00:00Z",
                ),
                profile,
            ),
        )
        val recording = RemoteRecording(
            id = "30000000-0000-0000-0000-000000000001",
            dogId = dog.id,
            profile = profile,
            source = "live",
            captureStatus = "completed",
            startedAtUtc = "2026-07-30T10:01:00Z",
            endedAtUtc = "2026-07-30T10:02:00Z",
            timezone = "UTC",
            sessionLabel = "Remote session",
            questionnaireSchemaVersion = 1,
            questionnaireValidationState = "complete",
            sessionQuestionnaireJson = sessionJson,
            videoRequested = false,
            sensorHardwareId = "sensor",
            appVersion = "test",
            protocolVersion = "1",
            captureErrorCode = null,
            captureErrorMessage = null,
            receiptSha256 = "a".repeat(64),
            verifiedAtUtc = "2026-07-30T10:03:00Z",
            sync = RecordingSyncClock(
                schemaVersion = 2,
                sessionZeroAtUtc = "2026-07-30T10:01:00Z",
                sessionZeroWallClockMs = 1_775_899_260_000,
                sessionZeroMonotonicNs = 10,
                sessionZeroUncertaintyNs = 1,
                firstSensorPacketMonotonicNs = 11,
                lastSensorPacketMonotonicNs = 12,
                videoRequestedMonotonicNs = null,
                mediaRecorderStartedMonotonicNs = null,
                videoFirstFrameMonotonicNs = null,
                videoFirstFrameCameraTimestampNs = null,
                videoOffsetFromSensorNs = null,
                cameraTimestampSource = null,
                cameraClockQuality = "unavailable",
                sensorClockQuality = "first_packet_arrival",
                overallSyncQuality = "arrival_aligned",
                calibrationOffsetNs = 0,
                estimatedDriftPpm = null,
            ),
            artifacts = listOf(
                RemoteArtifact(
                    id = "40000000-0000-0000-0000-000000000001",
                    type = "packet",
                    fileName = "packets.bin",
                    mimeType = "application/octet-stream",
                    sizeBytes = 3,
                    sha256 = downloadHash,
                    storageStatus = "available",
                ),
            ),
        )

        val first = database.restoreServerMetadata(listOf(dog), listOf(recording))
        val second = database.restoreServerMetadata(listOf(dog), listOf(recording))

        assertEquals(RestoreResult(1, 1, 1, 0), first)
        assertEquals(RestoreResult(0, 0, 0, 0), second)
        assertEquals("Remote Rex", database.profile(dog.id)?.numberOrName)
        database.readableDatabase.rawQuery(
            "SELECT count(*) FROM dog_profile_versions WHERE dog_id=?",
            arrayOf(dog.id),
        ).use { cursor ->
            assertTrue(cursor.moveToFirst())
            assertEquals(2, cursor.getInt(0))
        }
        assertEquals("remote_only", database.recording(recording.id)?.artifacts?.single()?.localPresence)
        assertEquals(1, database.remoteArtifacts(recording.id).size)

        val target = database.artifactDownloadTarget(database.remoteArtifacts(recording.id).single())
        target.parentFile?.mkdirs()
        target.writeBytes(downloadBytes)
        database.writableDatabase.execSQL(
            "UPDATE artifacts SET local_presence='local' WHERE id=?",
            arrayOf(recording.artifacts.single().id),
        )
        database.writableDatabase.execSQL(
            "UPDATE server_sync_state SET state='pending' WHERE recording_id=?",
            arrayOf(recording.id),
        )
        assertEquals(RestoreResult(0, 0, 0, 0), database.restoreServerMetadata(listOf(dog), listOf(recording)))
        assertEquals("both", database.recording(recording.id)?.artifacts?.single()?.localPresence)
        assertEquals("synced", database.recording(recording.id)?.serverSyncState)
    }

    @Test
    fun completedServerRestoreReconcilesArtifactIdWithoutChangingLocalBytes() {
        val local = completedPacketRecording("Canonical artifact")
        val old = local.artifacts.single()
        val canonicalId = "90000000-0000-0000-0000-000000000001"
        val remote = remoteCompletedRecording(local).let { it.copy(artifacts = listOf(it.artifacts.single().copy(id = canonicalId))) }

        assertEquals(0, database.restoreServerMetadata(emptyList(), listOf(remote)).conflicts)
        val restored = requireNotNull(database.recording(local.id)).artifacts.single { it.type == ArtifactType.PACKET }
        assertEquals(canonicalId, restored.id)
        assertEquals(old.relativePath, restored.relativePath)
        assertEquals("both", restored.localPresence)
        assertEquals("available", restored.uploadState)
        assertEquals(11L, restored.uploadedBytes)
        assertEquals("packet data", database.resolveRelativePath(old.relativePath).readText())
        assertEquals(RestoreResult(0, 0, 0, 0), database.restoreServerMetadata(emptyList(), listOf(remote)))
    }

    @Test
    fun completedServerRestoreRejectsArtifactIdOwnedByAnotherRecording() {
        val local = completedPacketRecording("First recording")
        val other = completedPacketRecording("Other recording")
        val remote = remoteCompletedRecording(local).let { it.copy(artifacts = listOf(it.artifacts.single().copy(id = other.artifacts.single().id))) }

        assertEquals(1, database.restoreServerMetadata(emptyList(), listOf(remote)).conflicts)
        assertEquals(local.artifacts.single().id, database.recording(local.id)?.artifacts?.single { it.type == ArtifactType.PACKET }?.id)
        assertEquals("pending", database.recording(local.id)?.serverSyncState)
        assertEquals("pending", database.recording(other.id)?.artifacts?.single { it.type == ArtifactType.PACKET }?.uploadState)
        assertEquals("packet data", database.resolveRelativePath(other.artifacts.single().relativePath).readText())
    }

    @Test
    fun completedServerRestoreMergesEarlierCanonicalPlaceholderIntoLocalPath() {
        val local = completedPacketRecording("Earlier placeholder")
        val old = local.artifacts.single()
        val canonicalId = "90000000-0000-0000-0000-000000000004"
        database.writableDatabase.execSQL("""
            INSERT INTO artifacts(id,recording_id,type,file_name,mime_type,relative_path,size_bytes,sha256,
                hash_state,local_presence,upload_state,uploaded_bytes,created_at_utc)
            SELECT ?,recording_id,type,file_name,mime_type,?,size_bytes,sha256,
                hash_state,'remote_only','available',size_bytes,created_at_utc FROM artifacts WHERE id=?
        """.trimIndent(), arrayOf(canonicalId, "recordings/server-corrected/packets.bin", old.id))
        val remote = remoteCompletedRecording(local).let { it.copy(artifacts = listOf(it.artifacts.single().copy(id = canonicalId))) }

        assertEquals(0, database.restoreServerMetadata(emptyList(), listOf(remote)).conflicts)
        val packets = requireNotNull(database.recording(local.id)).artifacts.filter { it.type == ArtifactType.PACKET }
        assertEquals(1, packets.size)
        assertEquals(canonicalId, packets.single().id)
        assertEquals(old.relativePath, packets.single().relativePath)
        assertEquals("both", packets.single().localPresence)
        assertEquals("available", packets.single().uploadState)
        assertEquals("packet data", database.resolveRelativePath(old.relativePath).readText())
        assertEquals("synced", database.recording(local.id)?.serverSyncState)
        assertEquals(RestoreResult(0, 0, 0, 0), database.restoreServerMetadata(emptyList(), listOf(remote)))
    }

    @Test
    fun completedServerRestoreRejectsAliasWithDifferentBytes() {
        val local = completedPacketRecording("Conflicting bytes")
        val remote = remoteCompletedRecording(local)
        val aliases = listOf(
            remote.artifacts.single().copy(id = "90000000-0000-0000-0000-000000000002", sha256 = "a".repeat(64)),
            remote.artifacts.single().copy(id = "90000000-0000-0000-0000-000000000003", sizeBytes = 12),
        )
        aliases.forEach { alias ->
            val restored = database.restoreServerMetadata(emptyList(), listOf(remote.copy(artifacts = listOf(alias))))
            assertEquals(1, restored.conflicts)
            assertEquals(1, restored.recordingConflicts)
            assertEquals(local.artifacts.single().id, database.recording(local.id)?.artifacts?.single { it.type == ArtifactType.PACKET }?.id)
            assertEquals("pending", database.recording(local.id)?.serverSyncState)
            assertEquals("packet data", database.resolveRelativePath(local.artifacts.single().relativePath).readText())
        }
    }

    @Test
    fun unsyncedDogDraftConflictDoesNotBlockCompletedRecordingRestore() {
        val local = completedPacketRecording("Server profile")
        val remote = remoteCompletedRecording(local)
        val draft = database.saveProfile(completeDogQuestionnaire("Local draft"), local.dogId)
        val dog = RemoteDog(local.dogId, "Server profile", 1, remote.profile)

        val restored = database.restoreServerMetadata(listOf(dog), listOf(remote))

        assertEquals(1, restored.conflicts)
        assertEquals(0, restored.recordingConflicts)
        assertEquals(draft.profileVersionId, database.profile(local.dogId)?.profileVersionId)
        assertEquals("synced", database.recording(local.id)?.serverSyncState)
        assertEquals("packet data", database.resolveRelativePath(local.artifacts.single().relativePath).readText())
    }

    @Test fun iosClockRoundTripPreservesDomainAndExactNanoseconds() {
        val local=completedPacketRecording("QA clock")
        val n=9_007_199_254_740_993L
        val clock=local.sync.copy(sessionZeroMonotonicNs=n,firstSensorPacketMonotonicNs=n+17,
            lastSensorPacketMonotonicNs=n+900_000_017,videoRequestedMonotonicNs=n-10,
            mediaRecorderStartedMonotonicNs=n+100,videoFirstFrameMonotonicNs=n+150,
            videoFirstFrameCameraTimestampNs=n+200,videoOffsetFromSensorNs=-123456789,
            videoFirstFrameCallbackMonotonicNs=n+250,videoFirstSamplePtsUs=1_234_567)
        val base=remoteCompletedRecording(local).copy(id=java.util.UUID.randomUUID().toString(),sync=clock,artifacts=emptyList())
        val client=com.example.myapplication.sync.ServerApiClient(com.example.myapplication.sync.ServerSettings("https://invalid.example","synthetic","qa-device",false,null))
        client.javaClass.getDeclaredField("authenticatedDeviceId").apply {isAccessible=true}.set(client,"00000000-0000-0000-0000-000000000099")
        val manifestMethod=client.javaClass.getDeclaredMethod("recordingManifest",RecordingSyncRecord::class.java).apply {isAccessible=true}
        val m=manifestMethod.invoke(client,local.copy(sync=clock)) as JSONObject
        val remoteJson=JSONObject(m.getJSONObject("recording").toString())
            .put("id",base.id).put("dogId",base.dogId).put("profileVersion",m.getJSONObject("dogProfileVersion"))
            .put("sync",m.getJSONObject("sync").put("monotonicClock","ios.CMClock.hostTime"))
            .put("artifacts",org.json.JSONArray()).put("receiptSha256",base.receiptSha256).put("serverVerifiedAtUtc",base.verifiedAtUtc)
        val parse=client.javaClass.getDeclaredMethod("parseRecording",JSONObject::class.java).apply {isAccessible=true}
        val parsed=parse.invoke(client,JSONObject(remoteJson.toString())) as RemoteRecording
        assertEquals(clock.copy(monotonicClock="ios.CMClock.hostTime"),parsed.sync)
        val invalid = JSONObject(remoteJson.toString()).apply { getJSONObject("sync").put("monotonicClock","unknown.clock") }
        assertTrue(runCatching { parse.invoke(client,invalid) }.exceptionOrNull()?.cause is IllegalArgumentException)
        database.restoreServerMetadata(emptyList(),listOf(parsed))
        database.readableDatabase.rawQuery("SELECT monotonic_clock,session_zero_monotonic_ns FROM recording_sync WHERE recording_id=?",arrayOf(base.id)).use {
            it.moveToFirst();assertEquals("ios.CMClock.hostTime",it.getString(0));assertEquals(n,it.getLong(1))
        }
        val restored=requireNotNull(database.recordingSyncRecord(base.id)); assertEquals(clock.copy(monotonicClock="ios.CMClock.hostTime"),restored.sync)
        val emitted=(manifestMethod.invoke(client,restored) as JSONObject).getJSONObject("sync")
        assertEquals(n,emitted.getLong("sessionZeroMonotonicNs"));assertEquals(n+150,emitted.getLong("videoFirstFrameMonotonicNs"))
        assertEquals(-123456789L,emitted.getLong("videoOffsetFromSensorNs"));assertEquals("ios.CMClock.hostTime",emitted.getString("monotonicClock"))
    }


    @Test fun acceptedLocalRecordingCannotBecomeOfflineEditableAfterAnotherTaskMakesItPending() {
        val local=completedPacketRecording("Accepted with queued reference")
        database.markRecordingSynced(local.id,"f".repeat(64),"2026-10-27T00:00:00Z")
        database.markRecordingSyncError(local.id,true,"transfer_paused","Paused")
        val current=requireNotNull(database.recording(local.id))
        assertTrue(!current.remoteOrigin);assertTrue(current.requiresServerQuestionnaireEdit)
        org.junit.Assert.assertThrows(IllegalArgumentException::class.java) {
            database.saveSessionQuestionnaire(local.id,requireNotNull(current.questionnaire).copy(sessionLabel="Do not silently queue this edit"))
        }
        assertEquals(local.sessionLabel,database.recording(local.id)?.sessionLabel)
    }

    @Test fun restoredPendingQuestionnaireCannotBeSavedOfflineOrThrough404Fallback() {
        database.close(); root.deleteRecursively()
        val context=ApplicationProvider.getApplicationContext<android.content.Context>()
        root=File(context.filesDir,"Woona");root.deleteRecursively()
        val store=com.example.myapplication.sync.ServerSettingsStore(context)
        context.getSharedPreferences("woona_server",android.content.Context.MODE_PRIVATE).edit().clear().commit()
        database=WoonaDatabase(context,root)
        val local=completedPacketRecording("Remote edit protection")
        val remote=remoteCompletedRecording(local).copy(id=java.util.UUID.randomUUID().toString(),receiptSha256=null,verifiedAtUtc=null,artifacts=emptyList())
        database.restoreServerMetadata(emptyList(),listOf(remote))
        val displayed=requireNotNull(database.recording(remote.id))
        val draft=requireNotNull(displayed.questionnaire).copy(sessionLabel="KEEP MY DRAFT")
        assertTrue(displayed.remoteOrigin);assertEquals("pending",displayed.serverSyncState)
        org.junit.Assert.assertThrows(IllegalArgumentException::class.java) { database.saveSessionQuestionnaire(remote.id,draft) }
        androidx.test.core.app.ActivityScenario.launch(com.example.myapplication.MainActivity::class.java).use { scenario ->
            awaitStartupReady(scenario)
            fun attempt():Throwable? {
                var failed:Throwable?=null
                scenario.onActivity { activity ->
                    val editor=activity.javaClass.getDeclaredField("editingRecording\$delegate").apply {isAccessible=true}
                    @Suppress("UNCHECKED_CAST")
                    (editor.get(activity) as androidx.compose.runtime.MutableState<Recording?>).value=displayed
                    val method=activity.javaClass.declaredMethods.single {it.name=="saveEditedQuestionnaire"}.apply {isAccessible=true}
                    try { kotlinx.coroutines.runBlocking {
                        kotlin.coroutines.intrinsics.suspendCoroutineUninterceptedOrReturn<Unit> { continuation ->
                            method.invoke(activity,displayed,draft,null,false,continuation)
                        }
                    } } catch(error:Throwable) { failed=if(error is java.lang.reflect.InvocationTargetException) error.targetException else error }
                    assertTrue("The editor must remain open",(editor.get(activity) as androidx.compose.runtime.State<*>).value!=null)
                }
                return failed
            }
            val offlineFailure=attempt()
            assertTrue("Expected offline server-edit rejection; got ${offlineFailure?.javaClass?.name}: ${offlineFailure?.message}",offlineFailure is IllegalStateException)
            assertTrue("Expected the server-configuration reason; got ${offlineFailure?.message}",offlineFailure?.message?.contains("Configure server URL and token")==true)
            assertEquals(remote.sessionLabel,database.recording(remote.id)?.sessionLabel)
            val requests=java.util.concurrent.CopyOnWriteArrayList<String>()
            java.net.ServerSocket(0,10,java.net.InetAddress.getByName("127.0.0.1")).use { server ->
                val responder=Thread {
                    try { while(!server.isClosed) server.accept().use { socket ->
                        socket.soTimeout=5000
                        val input=socket.getInputStream();val headers=java.io.ByteArrayOutputStream()
                        while(!headers.toString("UTF-8").endsWith("\r\n\r\n")) { val byte=input.read();if(byte<0)error("Unexpected EOF");headers.write(byte) }
                        val text=headers.toString("UTF-8");requests+=text.lineSequence().first()
                        val size=Regex("""(?i)Content-Length: (\d+)""").find(text)?.groupValues?.get(1)?.toInt()?:0
                        repeat(size) { check(input.read()>=0) }
                        val body=JSONObject().put("detail",JSONObject().put("code","recording_not_found")).toString()
                        socket.getOutputStream().write(("HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: ${body.toByteArray().size}\r\nConnection: close\r\n\r\n"+body).toByteArray())
                    } } catch (_:java.net.SocketException) { }
                }.apply { isDaemon=true;start() }
                store.save("http://127.0.0.1:${server.localPort}","synthetic-review-token",true)
                val missingFailure=attempt()
                assertTrue("Expected HTTP404 without local fallback; got ${missingFailure?.javaClass?.name}: ${missingFailure?.message}",missingFailure is com.example.myapplication.sync.ServerHttpException)
                assertEquals(404,(missingFailure as com.example.myapplication.sync.ServerHttpException).status)
                assertTrue(requests.any {it.startsWith("PUT /v1/recordings/${remote.id}/questionnaire ")})
                assertEquals(remote.sessionLabel,database.recording(remote.id)?.sessionLabel)
                store.clearToken();server.close();responder.join(2000)
            }
        }
        context.getSharedPreferences("woona_server",android.content.Context.MODE_PRIVATE).edit().clear().commit()
    }

    @Test fun startupRecoveryKeepsMainResponsiveBlocksCaptureAndPreservesUnknownEnd() {
        database.close();root.deleteRecursively()
        val context=ApplicationProvider.getApplicationContext<android.content.Context>()
        root=File(context.filesDir,"Woona");root.deleteRecursively()
        context.getSharedPreferences("woona_server",android.content.Context.MODE_PRIVATE).edit().clear().commit()
        database=WoonaDatabase(context,root)
        val dog=database.saveProfile(completeDogQuestionnaire("Cold recovery"))
        val session=database.beginRecording(dog.id,RecordingSource.LIVE,completeSessionQuestionnaire())
        val video=File(database.recordingDirectory(session.relativeDirectory),"video.mp4")
        java.io.RandomAccessFile(video,"rw").use {it.setLength(256L*1024*1024)}
        database.close()
        val lock=com.example.myapplication.sync.serverOperationLock
        lock.lock()
        var scenario:androidx.test.core.app.ActivityScenario<com.example.myapplication.MainActivity>?=null
        try {
            scenario=androidx.test.core.app.ActivityScenario.launch(com.example.myapplication.MainActivity::class.java)
            val responsive=java.util.concurrent.CountDownLatch(1)
            android.os.Handler(android.os.Looper.getMainLooper()).post {responsive.countDown()}
            assertTrue("Main thread stays responsive while recovery waits",responsive.await(2,java.util.concurrent.TimeUnit.SECONDS))
            scenario.onActivity {activity ->
                assertTrue(activity.javaClass.getDeclaredField("startupReady\$delegate").apply {isAccessible=true}.let {(it.get(activity) as androidx.compose.runtime.State<*>).value}==false)
                val toggle=activity.javaClass.getDeclaredMethod("toggleCapture").apply {isAccessible=true}
                assertTrue(runCatching {toggle.invoke(activity)}.exceptionOrNull()?.cause is IllegalStateException)
            }
        } finally { lock.unlock() }
        requireNotNull(scenario).use {
            awaitStartupReady(it)
            database=WoonaDatabase(context,root)
            val recovered=requireNotNull(database.recording(session.id))
            assertEquals(RecordingStatus.INTERRUPTED,recovered.status)
            assertEquals(null,recovered.endedAtUtc)
            assertEquals("process_interrupted",recovered.captureErrorCode)
            assertEquals(256L*1024*1024,recovered.artifacts.single().sizeBytes)
            assertEquals(sha256(video),recovered.artifacts.single().sha256)
            assertEquals(completeSessionQuestionnaire().toJson(),requireNotNull(recovered.questionnaire).toJson())
        }
    }

    private fun awaitStartupReady(scenario:androidx.test.core.app.ActivityScenario<com.example.myapplication.MainActivity>) {
        val deadline=android.os.SystemClock.elapsedRealtime()+30_000
        while(true) {
            var ready=false
            scenario.onActivity {activity ->ready=activity.javaClass.getDeclaredField("startupReady\$delegate").apply {isAccessible=true}.let {(it.get(activity) as androidx.compose.runtime.State<*>).value}==true}
            if(ready)return
            check(android.os.SystemClock.elapsedRealtime()<deadline) {"Startup recovery did not finish"}
            Thread.sleep(25)
        }
    }

    @Test fun restoreSkipsRetirementRacesReportsUnknown404AndPreservesOtherAccountOriginals() {
        val original=completedPacketRecording("Other account source")
        database.writableDatabase.execSQL("UPDATE dogs SET account_id='account-b' WHERE id=?",arrayOf(original.dogId))
        val dogId=java.util.UUID.randomUUID().toString();val recordId=java.util.UUID.randomUUID().toString()
        val profileId=java.util.UUID.randomUUID().toString();val retiredDog=java.util.UUID.randomUUID().toString();val retiredRecord=java.util.UUID.randomUUID().toString()
        val template=com.example.myapplication.sync.ServerApiClient(com.example.myapplication.sync.ServerSettings("https://invalid.example","synthetic","device",true,"account-a"))
        template.javaClass.getDeclaredField("authenticatedDeviceId").apply {isAccessible=true}.set(template,"00000000-0000-0000-0000-000000000099")
        val manifest=template.javaClass.getDeclaredMethod("recordingManifest",RecordingSyncRecord::class.java).apply {isAccessible=true}.invoke(template,original) as JSONObject
        val profile=manifest.getJSONObject("dogProfileVersion").put("id",profileId)
        val dog=JSONObject().put("id",dogId).put("accountId","account-a").put("numberOrName","Restored active").put("revision",1).put("profileVersion",profile)
        val record=manifest.getJSONObject("recording").put("id",recordId).put("dogId",dogId).put("accountId","account-a").put("profileVersion",profile)
            .put("sync",manifest.getJSONObject("sync")).put("artifacts",org.json.JSONArray()).put("receiptSha256","a".repeat(64)).put("serverVerifiedAtUtc","2026-10-27T00:00:00Z")
        fun page(vararg ids:String)=JSONObject().put("items",org.json.JSONArray(ids.map {JSONObject().put("id",it)})).put("nextCursor",JSONObject.NULL)
        fun hash(id:String)=java.security.MessageDigest.getInstance("SHA-256").digest(id.toByteArray()).joinToString(""){"%02x".format(it)}
        val requested=mutableListOf<String>();val headers=mutableListOf<String?>()
        val client=syntheticRestoreClient({url->
            val path=url.file;requested+=path
            when(path) {
                "/v1/dogs?limit=200"->200 to page(dogId,retiredDog).toString()
                "/v1/dogs/$dogId"->200 to dog.toString()
                "/v1/dogs/$retiredDog"->410 to "{}"
                "/v1/dogs/$dogId/recordings?limit=200"->200 to page(recordId,retiredRecord,original.id).toString()
                "/v1/recordings/$recordId"->200 to record.toString()
                "/v1/recordings/$retiredRecord"->410 to "{}"
                "/v1/recordings/${original.id}"->404 to "{}"
                "/v1/deletions"->200 to JSONObject().put("entities",org.json.JSONArray(listOf(JSONObject().put("kind","dog").put("id_sha256",hash(retiredDog)),JSONObject().put("kind","recording").put("id_sha256",hash(retiredRecord))))).toString()
                else->error("Unexpected fixture path $path")
            }
        },headers)
        val snapshot=client.fetchRestoreSnapshot()
        assertEquals(1,snapshot.dogs.size);assertEquals(1,snapshot.recordings.size)
        assertEquals(3,snapshot.warnings.size);assertEquals(1,snapshot.warnings.count {!it.confirmedRetirement})
        assertEquals("/v1/deletions",requested.last());assertTrue(headers.all {it=="account-a"})
        assertTrue(requireNotNull(com.example.myapplication.sync.restoreWarningsText(snapshot.warnings,com.example.myapplication.localization.AppLanguage.ENGLISH)).contains("partially"))
        database.restoreServerMetadata(snapshot.dogs,snapshot.recordings);database.applyServerDeletions(snapshot.deletions)
        assertEquals(original.sessionLabel,database.recording(original.id)?.sessionLabel)
        assertEquals("packet data",database.resolveRelativePath(original.artifacts.single().relativePath).readText())
        assertEquals("account-b",database.profile(original.dogId)?.accountId)
    }

    @Test fun restoreNeverMasksAuthOrServerFailureAndRepeatedCursorsAreBounded() {
        val id=java.util.UUID.randomUUID().toString()
        for(status in listOf(401,403,500)) {
            val client=syntheticRestoreClient({url->if(url.file.startsWith("/v1/dogs?")) 200 to JSONObject().put("items",org.json.JSONArray(listOf(JSONObject().put("id",id)))).toString() else status to "{}"})
            val error=org.junit.Assert.assertThrows(com.example.myapplication.sync.ServerHttpException::class.java) {client.fetchRestoreSnapshot()}
            assertEquals(status,error.status)
        }
        var calls=0
        val stalled=syntheticRestoreClient({_->calls++;200 to JSONObject().put("items",org.json.JSONArray()).put("nextCursor",id).toString()})
        val error=org.junit.Assert.assertThrows(com.example.myapplication.sync.ServerTransferException::class.java) {stalled.fetchRestoreSnapshot()}
        assertEquals("pagination_stalled",error.code);assertEquals(2,calls)
    }

    private fun syntheticRestoreClient(response:(java.net.URL)->Pair<Int,String>,headers:MutableList<String?> = mutableListOf()) =
        com.example.myapplication.sync.ServerApiClient(com.example.myapplication.sync.ServerSettings("https://invalid.example","synthetic","device",true,"account-a"),connectionFactory={url->
            val reply=response(url)
            object:java.net.HttpURLConnection(url) {
                override fun connect() {}
                override fun disconnect() {}
                override fun usingProxy()=false
                override fun getResponseCode():Int {headers+=getRequestProperty("X-Woona-Account");return reply.first}
                override fun getInputStream()=reply.second.byteInputStream()
                override fun getErrorStream()=reply.second.byteInputStream()
                override fun getHeaderFields():Map<String,List<String>> = emptyMap()
            }
        })

    private fun completedPacketRecording(name: String): RecordingSyncRecord {
        val profile = database.saveProfile(completeDogQuestionnaire(name))
        val recording = database.beginRecording(profile.id, RecordingSource.LIVE, completeSessionQuestionnaire())
        File(database.recordingDirectory(recording.relativeDirectory), "packets.bin").writeText("packet data")
        database.writeSyncMetadata(recording.id, CaptureSyncMetadata(recordingId = recording.id, profileId = profile.id,
            source = "live", timezone = recording.timezone, selectedSessionStartUtc = recording.startedAtUtc))
        database.finishRecording(recording.id, RecordingStatus.COMPLETED)
        return requireNotNull(database.recordingSyncRecord(recording.id)).let { it.copy(artifacts = it.artifacts.filter { artifact -> artifact.type == "packet" }) }
    }

    private fun remoteCompletedRecording(local: RecordingSyncRecord) = RemoteRecording(
        id = local.id, dogId = local.dogId,
        profile = RemoteProfileVersion(local.profileVersionId, local.profile.schemaVersion, local.profile.validationState,
            local.profile.questionnaireJson, local.profile.contentSha256, local.profile.clientCreatedAtUtc),
        source = local.source, captureStatus = local.captureStatus, startedAtUtc = local.startedAtUtc,
        endedAtUtc = local.endedAtUtc, timezone = local.timezone, sessionLabel = local.sessionLabel,
        questionnaireSchemaVersion = local.questionnaireSchemaVersion, questionnaireValidationState = local.questionnaireValidationState,
        sessionQuestionnaireJson = local.sessionQuestionnaireJson, videoRequested = local.videoRequested,
        sensorHardwareId = local.sensorHardwareId, appVersion = local.appVersion, protocolVersion = local.protocolVersion,
        captureErrorCode = local.captureErrorCode, captureErrorMessage = local.captureErrorMessage,
        receiptSha256 = "b".repeat(64), verifiedAtUtc = "2026-10-09T12:00:00Z", sync = local.sync,
        artifacts = local.artifacts.map { RemoteArtifact(it.id, it.type, it.fileName, it.mimeType, it.sizeBytes, it.sha256, "available") },
    )
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

private fun completeSessionQuestionnaire() = SessionQuestionnaire(
    sessionLabel = "Remote session",
    operatorName = "Operator",
    activityGroup = "stationary",
    activityType = "rest",
    location = "indoors",
    surface = "concrete",
    airTemperatureStatus = "not_measured",
    sensorPosition = "dorsal_neck",
    collarTightness = "snug",
    preMeasurementState = "rest",
    pulseStatus = "not_measured",
    respirationStatus = "not_measured",
    bodyTemperatureStatus = "not_measured",
    videoRequested = false,
)
