package com.example.myapplication.sync

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.hasScrollAction
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performScrollToIndex
import androidx.compose.ui.semantics.SemanticsProperties
import com.example.myapplication.BuildConfig
import com.example.myapplication.data.ArtifactSyncRecord
import com.example.myapplication.data.DogQuestionnaire
import com.example.myapplication.data.ProfileSyncRecord
import com.example.myapplication.data.RecordingSyncClock
import com.example.myapplication.data.RecordingSyncRecord
import com.example.myapplication.data.SessionQuestionnaire
import com.example.myapplication.data.canonicalJsonSha256
import com.example.myapplication.data.toJson
import com.example.myapplication.data.recordingSyncRecord
import com.example.myapplication.data.sessionQuestionnaireFromJson
import com.example.myapplication.data.HeartQuestionnaire
import com.example.myapplication.data.HEART_OPTIONS
import com.example.myapplication.data.profileSyncRecord
import com.example.myapplication.data.WoonaDatabase
import com.example.myapplication.data.restoreServerMetadata
import com.example.myapplication.data.remoteArtifacts
import com.example.myapplication.data.artifactDownloadTarget
import com.example.myapplication.data.markArtifactDownloaded
import com.example.myapplication.data.serverSyncCounts
import com.example.myapplication.data.resetFailedSync
import com.example.myapplication.data.RecordingSource
import com.example.myapplication.data.RecordingStatus
import com.example.myapplication.data.CaptureSyncMetadata
import com.example.myapplication.data.hashPendingArtifacts
import androidx.test.core.app.ActivityScenario
import com.example.myapplication.MainActivity
import androidx.work.WorkManager
import java.io.IOException
import android.util.Log
import java.net.URL
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.Rule
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ServerApiClientIntegrationTest {
    @get:Rule
    val composeRule = createEmptyComposeRule()

    @Test
    fun accountHeadersScopeDogsAndManualLink() {
        val arguments = InstrumentationRegistry.getArguments()
        val url = arguments.getString("serverBaseUrl")
        assumeTrue("Local API was not supplied", url != null)
        val settings = ServerSettings(requireNotNull(url), arguments.getString("serverToken") ?: "change-me-local-token", "unused", false)
        val account = "android-${UUID.randomUUID()}"
        val first = ServerApiClient(settings.copy(accountId = account))
        val other = ServerApiClient(settings.copy(accountId = "$account-other"))
        first.applyAccount(account); other.applyAccount("$account-other")
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val root = File(context.cacheDir, "account-api-${System.nanoTime()}")
        val database = WoonaDatabase(context, root)
        try {
            val assigned = database.saveProfile(completeDog().copy(numberOrName = "Assigned"), accountId = account)
            val unassigned = database.saveProfile(completeDog().copy(numberOrName = "Unassigned"))
            first.uploadProfile(requireNotNull(database.profileSyncRecord(assigned.profileVersionId)))
            ServerApiClient(settings).uploadProfile(requireNotNull(database.profileSyncRecord(unassigned.profileVersionId)))
            assertEquals(account, first.fetchDog(assigned.id).accountId)
            org.junit.Assert.assertThrows(ServerHttpException::class.java) { other.fetchDog(assigned.id) }
            org.junit.Assert.assertThrows(ServerHttpException::class.java) { first.fetchDog(unassigned.id) }
            first.linkDogAccount(unassigned.id, account)
            assertEquals(account, first.fetchDog(unassigned.id).accountId)
            org.junit.Assert.assertThrows(ServerHttpException::class.java) { ServerApiClient(settings).fetchDog(unassigned.id) }
            first.linkDogAccount(unassigned.id, account)
            listOf("activity", "heart").forEach { kind ->
                val q = if (kind == "heart") SessionQuestionnaire(schemaVersion = 2, sessionLabel = "Heart", sessionKind = kind,
                    videoRequested = false, heartQuestionnaire = HeartQuestionnaire(
                        answers = HEART_OPTIONS.keys.filter { it != "acuteHeartRateFactors" }.associateWith { "unknown" },
                        acuteHeartRateFactors = listOf("unknown")))
                    else completeSession().copy(schemaVersion = 2, sessionKind = kind, videoRequested = false, plannedActivities = listOf("Аллюр/движение"))
                val local = database.beginRecording(assigned.id, RecordingSource.LIVE, q)
                database.writeSyncMetadata(local.id, CaptureSyncMetadata(recordingId = local.id, profileId = assigned.id,
                    source = "live", timezone = local.timezone, selectedSessionStartUtc = local.startedAtUtc))
                database.finishRecording(local.id, RecordingStatus.FAILED)
                database.hashPendingArtifacts()
                val upload = requireNotNull(database.recordingSyncRecord(local.id))
                first.uploadRecording(upload, { id -> database.resolveRelativePath(upload.artifacts.single { it.id == id }.relativePath) }, { _, _, _ -> })
                val shown = first.fetchRecording(local.id)
                val shownQ = sessionQuestionnaireFromJson(shown.sessionQuestionnaireJson)
                val editedQ = if (kind == "heart") shownQ.copy(heartQuestionnaire = shownQ.heartQuestionnaire?.let { it.copy(answers = it.answers + ("actualActivity" to "rest")) })
                    else shownQ.copy(notes = "Edited activity", sessionLabel = "Edited activity label")
                val edited = first.editQuestionnaire(local.id, shown.questionnaireRevision, editedQ)
                assertEquals(shown.questionnaireRevision + 1, edited.questionnaireRevision)
                assertEquals(editedQ, sessionQuestionnaireFromJson(edited.sessionQuestionnaireJson))
                org.junit.Assert.assertThrows(ServerHttpException::class.java) { first.editQuestionnaire(local.id, shown.questionnaireRevision, shownQ) }
                database.restoreServerMetadata(listOf(first.fetchDog(assigned.id)), listOf(edited))
                assertEquals(edited.questionnaireRevision, database.recording(local.id)?.questionnaireRevision)
                assertEquals(editedQ, database.recording(local.id)?.questionnaire)
                assertEquals(editedQ.sessionLabel, database.recording(local.id)?.sessionLabel)
            }
        } finally { database.close(); root.deleteRecursively() }
    }

    @Test
    fun realWorkManager_invalidTokenIsVisibleAndManualRetrySucceeds() {
        val arguments = InstrumentationRegistry.getArguments()
        val baseUrl = arguments.getString("serverBaseUrl")
        assumeTrue("Local API was not supplied", baseUrl != null)
        val token = arguments.getString("serverToken") ?: "change-me-local-token"
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val settingsStore = ServerSettingsStore(context)
        val original = settingsStore.get()
        val preferences = context.getSharedPreferences("woona_server", android.content.Context.MODE_PRIVATE)
        val database = WoonaDatabase(context)
        fun configure(value: String, url: String? = baseUrl) {
            settingsStore.save("https://local-worker-test.invalid", value, false)
            preferences.edit().putString("base_url", url).commit()
        }
        val profile = database.saveProfile(completeDog().copy(schemaVersion = 2, species = "собака", animalId = "worker-${UUID.randomUUID()}"))
        fun state(): String = database.readableDatabase.rawQuery("SELECT server_sync_state FROM dog_profile_versions WHERE id=?", arrayOf(profile.profileVersionId)).use { cursor ->
            check(cursor.moveToFirst())
            cursor.getString(0)
        }
        fun waitFor(expected: String, seconds: Long = 30) {
            val deadline = System.nanoTime() + seconds * 1_000_000_000L
            while (state() != expected && System.nanoTime() < deadline) Thread.sleep(100)
            assertEquals(expected, state())
        }
        try {
            configure("invalid-test-token")
            ServerSyncScheduler.enqueueProfile(context, profile.profileVersionId)
            waitFor("permanent_error")
            assertTrue(database.serverSyncCounts().failed > 0)
            assertTrue(database.serverSyncCounts().lastErrorMessage.orEmpty().contains("invalid_bearer_token"))
            ActivityScenario.launch(MainActivity::class.java).use {
                val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
                fun find(node: android.view.accessibility.AccessibilityNodeInfo?, label: String): android.view.accessibility.AccessibilityNodeInfo? {
                    if (node == null) return null
                    if (node.isVisibleToUser && node.text?.contains(label) == true) return node
                    return (0 until node.childCount).firstNotNullOfOrNull { find(node.getChild(it), label) }
                }
                fun visible(label: String) = find(automation.rootInActiveWindow, label)
                fun screenshot(name: String) = File(context.cacheDir, name).outputStream().use { output -> automation.takeScreenshot().compress(android.graphics.Bitmap.CompressFormat.PNG, 100, output) }
                val startDeadline = System.nanoTime() + 10_000_000_000L
                while (visible("Settings") == null && visible("Настройки") == null && System.nanoTime() < startDeadline) Thread.sleep(100)
                screenshot("actual-worker-before-settings.png")
                var settingsNode = requireNotNull(visible("Settings") ?: visible("Настройки"))
                while (!settingsNode.isClickable && settingsNode.parent != null) settingsNode = settingsNode.parent
                assertTrue(settingsNode.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK))
                composeRule.waitUntil(10_000) {
                    composeRule.onAllNodes(hasText("BLE transport profile") or hasText("Профиль BLE-транспорта"))
                        .fetchSemanticsNodes().isNotEmpty()
                }
                composeRule.onNode(hasScrollAction()).performScrollToIndex(3)
                val errorNode = composeRule.onNode(hasText("invalid_bearer_token", substring = true))
                    .performScrollTo().assertIsDisplayed().fetchSemanticsNode()
                composeRule.onNode(hasText("Retry uploads") or hasText("Повторить выгрузку"))
                    .performScrollTo().assertIsDisplayed().assertIsEnabled()
                File(context.cacheDir, "actual-worker-401.png").outputStream().use { output -> automation.takeScreenshot().compress(android.graphics.Bitmap.CompressFormat.PNG, 100, output) }
                File(context.cacheDir, "actual-worker-401.txt").writeText("${errorNode.config[SemanticsProperties.Text].joinToString { it.text }}\nRetry enabled=true\n")
                Log.i("WOONA_E2E", "PASS actualMainActivity worker401Visible=true retryEnabled=true screenshot=actual-worker-401.png")
            }
            val work = WorkManager.getInstance(context)
            val deadline = System.nanoTime() + 10_000_000_000L
            while (work.getWorkInfosForUniqueWork("server-profile-${profile.profileVersionId}").get().any { !it.state.isFinished } && System.nanoTime() < deadline) Thread.sleep(100)
            configure(token)
            database.resetFailedSync()
            val faultUrl = arguments.getString("serverFaultBaseUrl")
            if (faultUrl != null) {
                URL("$faultUrl/__fault/503").openStream().use { it.readBytes() }
                configure(token, faultUrl)
            }
            ServerSyncScheduler.enqueueProfile(context, profile.profileVersionId)
            if (faultUrl != null) {
                waitFor("retryable_error")
                assertTrue(database.serverSyncCounts().lastErrorMessage.orEmpty().contains("HTTP 503"))
                Log.i("WOONA_E2E", "PASS WorkManager http503Persisted=retryable_error beforeAutomaticRetry")
            }
            waitFor("synced", 60)
            Log.i("WOONA_E2E", "PASS WorkManager profile401Visible=true manualRetry=synced")
            configure(token)
            val recording = database.beginRecording(profile.id, RecordingSource.LIVE, completeSession().copy(
                schemaVersion = 2,
                animalId = profile.questionnaire.animalId,
                plannedActivities = listOf("Аллюр/движение"),
            ))
            val directory = database.recordingDirectory(recording.relativeDirectory)
            listOf("packets.bin", "packet_timeline.bin", "raw_fragments.binlog", "diagnostics.log", "channel.csv", "polar_hr.csv", "polar_ecg.csv", "polar_acc.csv").forEach { name -> File(directory, name).writeText("mock capture $name") }
            database.writeSyncMetadata(recording.id, CaptureSyncMetadata(
                recordingId = recording.id, profileId = profile.id, source = "live", timezone = recording.timezone, selectedSessionStartUtc = recording.startedAtUtc,
            ))
            database.finishRecording(recording.id, RecordingStatus.COMPLETED)
            database.hashPendingArtifacts()
            ActivityScenario.launch(MainActivity::class.java).use {
                ServerSyncScheduler.enqueueRecording(context, recording.id)
                val finishDeadline = System.nanoTime() + 30_000_000_000L
                while (database.recording(recording.id)?.serverSyncState != "synced" && System.nanoTime() < finishDeadline) Thread.sleep(100)
                assertEquals("synced", database.recording(recording.id)?.serverSyncState)
            }
            val remote = ServerApiClient(ServerSettings(requireNotNull(baseUrl), token, "worker", false)).fetchRestoreSnapshot().recordings.single { it.id == recording.id }
            assertEquals(9, remote.artifacts.size)
            assertEquals(setOf("channel.csv", "polar_hr.csv", "polar_ecg.csv", "polar_acc.csv"), remote.artifacts.filter { it.type == "csv" }.map { it.fileName }.toSet())
            assertTrue(!remote.receiptSha256.isNullOrBlank())
            assertTrue(remote.artifacts.all { it.storageStatus == "available" })
            Log.i("WOONA_E2E", "PASS WorkManager recordingUploadBytes=9Artifacts polarCsvAll=true receiptVerified=true recording=${recording.id}")

            fun retryCompletedRecording(expected: String) {
                val finishDeadline = System.nanoTime() + 10_000_000_000L
                while (work.getWorkInfosForUniqueWork("server-sync-${recording.id}").get().any { !it.state.isFinished } && System.nanoTime() < finishDeadline) Thread.sleep(100)
                assertTrue(work.getWorkInfosForUniqueWork("server-sync-${recording.id}").get().all { it.state.isFinished })
                database.writableDatabase.execSQL("UPDATE server_sync_state SET state='pending' WHERE recording_id=?", arrayOf(recording.id))
                ServerSyncScheduler.enqueueRecording(context, recording.id)
                val stateDeadline = System.nanoTime() + 10_000_000_000L
                while (database.recording(recording.id)?.serverSyncState != expected && System.nanoTime() < stateDeadline) Thread.sleep(100)
                assertEquals(expected, database.recording(recording.id)?.serverSyncState)
            }
            val draft = database.saveProfile(profile.questionnaire.copy(numberOrName = "Local draft"), profile.id)
            retryCompletedRecording("synced")
            assertEquals(draft.profileVersionId, database.profile(profile.id)?.profileVersionId)
            val packets = File(directory, "packets.bin")
            val localBytes = "local packet bytes retained".toByteArray()
            packets.writeBytes(localBytes)
            database.registerArtifact(recording.id, com.example.myapplication.data.ArtifactType.PACKET, packets)
            database.hashPendingArtifacts()
            retryCompletedRecording("permanent_error")
            database.readableDatabase.rawQuery("SELECT last_error_code,last_error_message FROM server_sync_state WHERE recording_id=?", arrayOf(recording.id)).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals("metadata_conflict", cursor.getString(0))
                assertTrue(cursor.getString(1).contains("Локальные файлы сохранены"))
            }
            assertArrayEquals(localBytes, packets.readBytes())
            assertEquals(9, database.recording(recording.id)?.artifacts?.size)
            assertEquals(draft.profileVersionId, database.profile(profile.id)?.profileVersionId)
            Log.i("WOONA_E2E", "PASS WorkManager completedReceiptIgnoresDogDraft=true artifactConflict=permanent_error filesPreserved=true")
        } finally {
            if (original.isConfigured) settingsStore.save(original.baseUrl, original.token, original.wifiOnly) else settingsStore.clearToken()
            preferences.edit().putString("base_url", original.baseUrl).putBoolean("wifi_only", original.wifiOnly).commit()
            database.close()
        }
    }

    @Test
    fun embeddedServerDefaults_configureFreshInstall() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val store = ServerSettingsStore(context)
        store.clearToken()

        val settings = store.get()

        assertEquals(BuildConfig.WOONA_SERVER_BASE_URL, settings.baseUrl)
        assertEquals(BuildConfig.WOONA_SERVER_TOKEN, settings.token)
        assertEquals(BuildConfig.WOONA_SERVER_TOKEN.isNotBlank(), settings.isConfigured)
    }

    @Test
    fun uploadRestoreAndRangeDownload_roundTripAgainstDockerApi() {
        val baseUrl = InstrumentationRegistry.getArguments()
            .getString("serverBaseUrl")
            ?: "http://10.0.2.2:8080"
        val token = InstrumentationRegistry.getArguments()
            .getString("serverToken")
            ?: "change-me-local-token"
        val client = ServerApiClient(
            ServerSettings(
                baseUrl = baseUrl,
                token = token,
                deviceId = "unused",
                wifiOnly = false,
            ),
            chunkBytes = 1024 * 1024,
        )
        assumeTrue("Docker API is not reachable at $baseUrl", runCatching(client::readiness).getOrDefault(false))
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val directory = File(context.cacheDir, "server-e2e-${System.nanoTime()}").apply { mkdirs() }
        val dogId = UUID.randomUUID().toString()
        val profileId = UUID.randomUUID().toString()
        val recordingId = UUID.randomUUID().toString()
        val animalId = "android-e2e-$dogId"
        val dogJson = completeDog().copy(schemaVersion = 2, animalId = animalId).toJson()
        val profile = ProfileSyncRecord(
            dogId = dogId,
            dogName = "Android E2E",
            expectedRevision = 0,
            profileVersionId = profileId,
            schemaVersion = 2,
            validationState = "complete",
            questionnaireJson = dogJson,
            contentSha256 = canonicalJsonSha256(dogJson),
            clientCreatedAtUtc = "2026-07-30T20:00:00Z",
        )
        val contents = linkedMapOf(
            "packet" to "packet".toByteArray(),
            "packet_timeline" to "timeline".toByteArray(),
            "raw" to ByteArray(2 * 1024 * 1024 + 17) { (it % 251).toByte() },
            "diagnostic" to "diagnostic".toByteArray(),
            "csv" to "time,value\n0,12\n".toByteArray(),
            "imported_source" to "replay source".toByteArray(),
            "sync" to """{"schemaVersion":2}""".toByteArray(),
        )
        val artifacts = contents.entries.map { (type, bytes) ->
            val extension = when (type) {
                "packet", "packet_timeline" -> "bin"
                "raw" -> "binlog"
                "diagnostic" -> "log"
                "csv" -> "csv"
                "imported_source" -> "bin"
                else -> "json"
            }
            val file = File(directory, "$type.$extension").apply { writeBytes(bytes) }
            ArtifactSyncRecord(
                id = UUID.randomUUID().toString(),
                type = type,
                fileName = file.name,
                mimeType = when (type) {
                    "diagnostic" -> "text/plain"
                    "sync" -> "application/json"
                    "csv" -> "text/csv"
                    else -> "application/octet-stream"
                },
                relativePath = file.absolutePath,
                sizeBytes = file.length(),
                sha256 = sha256(bytes),
                uploadedBytes = 0,
                uploadState = "pending",
                clientCreatedAtUtc = "2026-07-30T20:00:00Z",
            )
        }
        val recording = RecordingSyncRecord(
            id = recordingId,
            dogId = dogId,
            profileVersionId = profileId,
            source = "live",
            captureStatus = "completed",
            sessionLabel = "Android server E2E",
            questionnaireSchemaVersion = 2,
            questionnaireValidationState = "complete",
            sessionQuestionnaireJson = completeSession().copy(
                schemaVersion = 2,
                animalId = animalId,
                plannedActivities = listOf("Аллюр/движение"),
            ).toJson(),
            videoRequested = false,
            startedAtUtc = "2026-07-30T20:00:00Z",
            endedAtUtc = "2026-07-30T20:01:00Z",
            timezone = "UTC",
            sensorHardwareId = "fake",
            appVersion = "instrumentation",
            protocolVersion = "1",
            captureErrorCode = null,
            captureErrorMessage = null,
            profile = profile,
            sync = RecordingSyncClock(
                schemaVersion = 2,
                sessionZeroAtUtc = "2026-07-30T20:00:00Z",
                sessionZeroWallClockMs = 1_785_441_600_000,
                sessionZeroMonotonicNs = 100,
                sessionZeroUncertaintyNs = 1,
                firstSensorPacketMonotonicNs = 110,
                lastSensorPacketMonotonicNs = 120,
                videoRequestedMonotonicNs = null,
                mediaRecorderStartedMonotonicNs = null,
                videoFirstFrameMonotonicNs = null,
                videoFirstFrameCameraTimestampNs = null,
                videoOffsetFromSensorNs = null,
                cameraTimestampSource = null,
                cameraClockQuality = "unavailable",
                sensorClockQuality = "first_packet_arrival",
                overallSyncQuality = "unavailable",
                calibrationOffsetNs = 0,
                estimatedDriftPpm = null,
            ),
            artifacts = artifacts,
        )

        client.uploadProfile(profile)
        expectFailure(409, "animal_id_already_exists") {
            client.uploadProfile(profile.copy(dogId = UUID.randomUUID().toString(), profileVersionId = UUID.randomUUID().toString()))
        }
        expectFailure(409, "revision_conflict") {
            client.uploadProfile(profile.copy(profileVersionId = UUID.randomUUID().toString(), expectedRevision = 999))
        }
        val invalidClient = ServerApiClient(ServerSettings(baseUrl, "invalid-test-token", "unused", false))
        expectFailure(401, "invalid_bearer_token") { invalidClient.uploadProfile(profile) }
        InstrumentationRegistry.getArguments().getString("serverRevokedToken")?.let { revoked ->
            expectFailure(401, "invalid_bearer_token") { ServerApiClient(ServerSettings(baseUrl, revoked, "unused", false)).uploadProfile(profile) }
        }
        InstrumentationRegistry.getArguments().getString("serverFaultBaseUrl")?.let { faultUrl ->
            val faultSettings = ServerSettings(faultUrl, token, "unused", false)
            val faultClient = ServerApiClient(faultSettings)
            URL("$faultUrl/__fault/503").openStream().use { it.readBytes() }
            expectFailure(503, "intentional_e2e_fault") { faultClient.uploadProfile(profile) }
            faultClient.uploadProfile(profile)
            URL("$faultUrl/__fault/delay").openStream().use { it.readBytes() }
            // Keep the short deadline only on the deliberately delayed request.
            val timeoutClient = ServerApiClient(faultSettings, readTimeoutMillis = 500)
            assertTrue(runCatching { timeoutClient.uploadProfile(profile) }.exceptionOrNull() is IOException)
            faultClient.uploadProfile(profile)
            Log.i("WOONA_E2E", "PASS server503Retry=true readTimeoutRetry=true")
        }
        expectFailure(422, "missing_required_artifacts") {
            client.uploadRecording(recording.copy(id = UUID.randomUUID().toString(), artifacts = artifacts.take(1)), { error("unexpected file read") }, { _, _, _ -> })
        }
        val changedSize = recording.copy(id = UUID.randomUUID().toString(), artifacts = artifacts.map { it.copy(id = UUID.randomUUID().toString(), sizeBytes = it.sizeBytes + 1) })
        val sizeFailure = runCatching { client.uploadRecording(changedSize, { id -> File(changedSize.artifacts.first { it.id == id }.relativePath) }, { _, _, _ -> }) }.exceptionOrNull()
        assertTrue(sizeFailure is IllegalArgumentException && sizeFailure.message.orEmpty().contains("missing or changed"))
        val badHash = recording.copy(id = UUID.randomUUID().toString(), artifacts = artifacts.map { it.copy(id = UUID.randomUUID().toString(), sha256 = "0".repeat(64)) })
        expectFailure(422, "hash_mismatch") {
            client.uploadRecording(badHash, { id -> File(badHash.artifacts.first { it.id == id }.relativePath) }, { _, _, _ -> })
        }
        var interruptedOffset = 0L
        val interrupted = runCatching {
            client.uploadRecording(recording, { id -> File(artifacts.first { it.id == id }.relativePath) }) { id, bytes, available ->
                if (id == artifacts.first { it.type == "raw" }.id && bytes > 0 && !available) {
                    interruptedOffset = bytes
                    throw IOException("Intentional E2E interruption after persisted upload chunk")
                }
            }
        }.exceptionOrNull()
        assertTrue(interrupted is IOException)
        assertEquals(1024 * 1024L, interruptedOffset)
        var resumedOffset = -1L
        client.uploadRecording(
            record = recording,
            fileForArtifact = { id -> File(requireNotNull(artifacts.find { it.id == id }).relativePath) },
            onProgress = { id, bytes, _ -> if (id == artifacts.first { it.type == "raw" }.id && resumedOffset < 0) resumedOffset = bytes },
        )
        assertEquals(interruptedOffset, resumedOffset)
        client.uploadRecording(recording, { id -> File(artifacts.first { it.id == id }.relativePath) }, { _, _, _ -> })
        listOf("replay", "camera_failed", "interrupted", "failed").forEach { scenario ->
            val variant = recording.copy(
                id = UUID.randomUUID().toString(),
                source = if (scenario == "replay") "replay" else "live",
                captureStatus = if (scenario in listOf("interrupted", "failed")) scenario else "completed",
                captureErrorCode = if (scenario == "camera_failed") "camera_failed" else null,
                captureErrorMessage = if (scenario == "camera_failed") "Intentional mocked camera failure" else null,
                videoRequested = scenario == "camera_failed",
                artifacts = artifacts.filter { scenario != "replay" || it.type in setOf("packet", "diagnostic", "sync", "imported_source") }.map { it.copy(id = UUID.randomUUID().toString()) },
            )
            client.uploadRecording(variant, { id -> File(variant.artifacts.first { it.id == id }.relativePath) }, { _, _, _ -> })
            val remote = client.fetchRestoreSnapshot().recordings.single { it.id == variant.id }
            assertEquals(variant.captureStatus, remote.captureStatus)
            assertEquals(variant.source, remote.source)
            assertEquals(variant.artifacts.size, remote.artifacts.size)
            Log.i("WOONA_E2E", "PASS recordingScenario=$scenario artifacts=${variant.artifacts.size}")
        }
        InstrumentationRegistry.getArguments().getString("serverSecondaryToken")?.let { secondary ->
            val secondaryClient = ServerApiClient(ServerSettings(baseUrl, secondary, "unused", false))
            secondaryClient.uploadRecording(recording, { error("Completed capture must not be uploaded again") }, { _, _, _ -> error("Unexpected capture upload") })
        }
        val snapshot = client.fetchRestoreSnapshot()
        assertTrue(snapshot.dogs.any { it.id == dogId })
        assertTrue(snapshot.recordings.any { it.id == recordingId })

        val raw = requireNotNull(artifacts.find { it.type == "raw" })
        val rawBytes = contents.getValue("raw")
        InstrumentationRegistry.getArguments().getString("serverFaultBaseUrl")?.let { faultUrl ->
            val faultClient = ServerApiClient(ServerSettings(faultUrl, token, "unused", false))
            val throughCompressionProxy = File(directory, "identity-download.bin")
            faultClient.downloadArtifact(raw.id, raw.sizeBytes, raw.sha256, throughCompressionProxy)
            assertArrayEquals(rawBytes, throughCompressionProxy.readBytes())
            Log.i("WOONA_E2E", "PASS compressedETagProxyIdentityDownload=true")
        }
        val target = File(directory, "downloaded-${raw.fileName}")
        File(directory, "${target.name}.download.part").writeBytes(rawBytes.copyOfRange(0, 3))
        client.downloadArtifact(raw.id, raw.sizeBytes, raw.sha256, target)
        assertArrayEquals(rawBytes, target.readBytes())
        client.downloadArtifact(raw.id, raw.sizeBytes, raw.sha256, target)
        val conflicting = File(directory, "conflicting.bin").apply { writeText("keep local data") }
        val conflict = org.junit.Assert.assertThrows(ServerTransferException::class.java) {
            client.downloadArtifact(raw.id, raw.sizeBytes, raw.sha256, conflicting)
        }
        assertEquals("local_artifact_conflict", conflict.code)
        assertEquals("keep local data", conflicting.readText())
        val corrupt = File(directory, "corrupt.bin")
        File(directory, "${corrupt.name}.download.part").writeBytes(byteArrayOf(0, 0, 0))
        assertTrue(runCatching { client.downloadArtifact(raw.id, raw.sizeBytes, raw.sha256, corrupt) }.exceptionOrNull() is IOException)
        assertTrue(!File(directory, "${corrupt.name}.download.part").exists())
        client.downloadArtifact(raw.id, raw.sizeBytes, raw.sha256, corrupt)
        assertArrayEquals(rawBytes, corrupt.readBytes())
        val restoreRoot = File(directory, "restored-db-$recordingId")
        val database = WoonaDatabase(context, restoreRoot)
        try {
            val remoteDog = snapshot.dogs.single { it.id == dogId }
            val remoteRecording = snapshot.recordings.single { it.id == recordingId }
            val restored = database.restoreServerMetadata(listOf(remoteDog), listOf(remoteRecording))
            assertEquals(1, restored.dogs)
            assertEquals(1, restored.recordings)
            assertEquals(artifacts.size, restored.artifacts)
            val repeated = database.restoreServerMetadata(listOf(remoteDog), listOf(remoteRecording))
            assertEquals(0, repeated.dogs + repeated.recordings + repeated.artifacts + repeated.conflicts)
            database.remoteArtifacts(recordingId).forEach { artifact ->
                val destination = database.artifactDownloadTarget(artifact)
                client.downloadArtifact(artifact.id, artifact.sizeBytes, requireNotNull(artifact.sha256), destination)
                database.markArtifactDownloaded(artifact.id)
                assertArrayEquals(contents.getValue(artifact.type.value), destination.readBytes())
            }
            assertTrue(database.remoteArtifacts(recordingId).isEmpty())
            val targetBytes = "utc,bpm,rr_ms\n2026-07-30T20:00:30Z,120,500\n".toByteArray()
            val targetFile = File(directory, "polar-rr.csv").apply { writeBytes(targetBytes) }
            val referenceMetadata = com.example.myapplication.data.ReferenceMetadata("Polar H10", recording.startedAtUtc, requireNotNull(recording.endedAtUtc)).toJson()
            val reference = artifacts.first().copy(id = UUID.randomUUID().toString(), type = "rr", fileName = targetFile.name,
                relativePath = targetFile.absolutePath, sizeBytes = targetBytes.size.toLong(), sha256 = sha256(targetBytes), referenceMetadataJson = referenceMetadata)
            val secondary = InstrumentationRegistry.getArguments().getString("serverSecondaryToken") ?: token
            val referenceClient = ServerApiClient(ServerSettings(baseUrl, secondary, "unused", false))
            val captureReceipt = client.uploadRecording(recording, { error("Unexpected capture read") }, { _, _, _ -> })
            val referenceReceipt = referenceClient.uploadRecording(recording.copy(artifacts = listOf(reference)),
                { assertEquals(reference.id, it); targetFile }, { id, _, _ -> assertEquals(reference.id, id) })
            assertEquals(captureReceipt.receiptSha256, referenceReceipt.receiptSha256)
            val updated = referenceClient.fetchRestoreSnapshot().recordings.single { it.id == recordingId }
            assertEquals(canonicalJsonSha256(referenceMetadata), canonicalJsonSha256(requireNotNull(updated.artifacts.single { it.id == reference.id }.referenceMetadataJson)))
            database.restoreServerMetadata(listOf(remoteDog), listOf(updated))
            val restoredReference = database.remoteArtifacts(recordingId).single { it.id == reference.id }
            val referenceDestination = database.artifactDownloadTarget(restoredReference)
            referenceClient.downloadArtifact(reference.id, reference.sizeBytes, reference.sha256, referenceDestination)
            assertArrayEquals(targetBytes, referenceDestination.readBytes())
            Log.i("WOONA_E2E", "PASS recording=$recordingId artifactTypes=${contents.keys} rawBytes=${raw.sizeBytes} resumedOffset=$resumedOffset invalidAuth=401 missing=422 hash=422 sqliteRestoreTwice=PASS downloadAll=PASS")
        } finally {
            database.close()
            directory.deleteRecursively()
        }
    }
}

private fun expectFailure(status: Int, code: String, action: () -> Unit) {
    val exception = runCatching(action).exceptionOrNull()
    assertTrue("Expected HTTP $status/$code, received $exception", exception is ServerHttpException)
    exception as ServerHttpException
    assertEquals(status, exception.status)
    assertTrue(exception.responseBody, exception.responseBody.contains(code))
}

private fun completeDog() = DogQuestionnaire(
    numberOrName = "Android E2E",
    shelterOrPlace = "Test",
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

private fun completeSession() = SessionQuestionnaire(
    sessionLabel = "Android server E2E",
    operatorName = "Instrumentation",
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

private fun sha256(bytes: ByteArray): String =
    MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
