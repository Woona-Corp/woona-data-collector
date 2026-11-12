package com.example.myapplication.sync

import android.content.Context
import androidx.lifecycle.Observer
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.work.NetworkType
import androidx.work.WorkInfo
import androidx.work.WorkManager
import com.example.myapplication.data.CaptureSyncMetadata
import com.example.myapplication.data.DogQuestionnaire
import com.example.myapplication.data.RecordingSource
import com.example.myapplication.data.RecordingStatus
import com.example.myapplication.data.RecordingSyncRecord
import com.example.myapplication.data.SessionQuestionnaire
import com.example.myapplication.data.WoonaDatabase
import com.example.myapplication.data.hashPendingArtifacts
import com.example.myapplication.data.markRecordingSyncError
import com.example.myapplication.data.recordingSyncRecord
import com.example.myapplication.data.restoreServerMetadata
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.concurrent.thread
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RecordingSyncWorkerTest {
    private lateinit var context: Context
    private lateinit var database: WoonaDatabase
    private lateinit var originalSettings: ServerSettings
    private var server: UploadServer? = null

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        originalSettings = ServerSettingsStore(context).get()
        clearSyncState()
        com.example.myapplication.data.ActivityDatabase.resetForTesting()
        check(File(context.filesDir, "Woona").deleteRecursively()) { "Could not clear worker test database" }
        database = WoonaDatabase(context)
    }

    @After
    fun tearDown() {
        server?.close()
        try {
            clearSyncState()
        } finally {
            if (::database.isInitialized) database.close()
            com.example.myapplication.data.ActivityDatabase.resetForTesting()
            val store = ServerSettingsStore(context)
            if (originalSettings.isConfigured) {
                store.save(originalSettings.baseUrl, originalSettings.token, originalSettings.wifiOnly)
            } else {
                store.clearToken()
            }
            context.getSharedPreferences("woona_server", Context.MODE_PRIVATE).edit()
                .putString("base_url", originalSettings.baseUrl)
                .putBoolean("wifi_only", originalSettings.wifiOnly)
                .putString("account_id", originalSettings.accountId)
                .commit()
        }
        check(File(context.filesDir, "Woona").deleteRecursively()) { "Could not remove worker test database" }
    }

    private fun clearSyncState() {
        val manager = WorkManager.getInstance(context)
        serverOperationLock.lock()
        try {
            manager.cancelAllWorkByTag(ServerSyncScheduler.WORK_TAG).result.get(30, TimeUnit.SECONDS)
            manager.cancelUniqueWork(LocalRetirementCleanupWorker.WORK_NAME).result.get(30, TimeUnit.SECONDS)
            val work = manager.getWorkInfosByTag(ServerSyncScheduler.WORK_TAG).get(10, TimeUnit.SECONDS) +
                manager.getWorkInfosForUniqueWork(LocalRetirementCleanupWorker.WORK_NAME).get(10, TimeUnit.SECONDS)
            val unfinished = work.filterNot { it.state.isFinished }
            if (unfinished.isNotEmpty()) {
                throw AssertionError("Sync work survived cancellation: ${workTrace(unfinished)}")
            }
            manager.pruneWork().result.get(10, TimeUnit.SECONDS)
            val remaining = manager.getWorkInfosByTag(ServerSyncScheduler.WORK_TAG).get(10, TimeUnit.SECONDS) +
                manager.getWorkInfosForUniqueWork(LocalRetirementCleanupWorker.WORK_NAME).get(10, TimeUnit.SECONDS)
            if (remaining.isNotEmpty()) {
                throw AssertionError("Sync work survived pruning: ${workTrace(remaining)}")
            }
        } finally {
            serverOperationLock.unlock()
        }
    }

    @Test
    fun receiptSurvivesPostCompletionRecording404() {
        val local = completedRecording()
        val fixture = startServer(local, postReceiptStatus = 404)

        ActivityScenario.launch(com.example.myapplication.MainActivity::class.java).use {
            awaitAutomaticScheduling()
            awaitRecordingWork(local.id)
        }

        val restored = requireNotNull(database.recording(local.id))
        assertEquals("synced", restored.serverSyncState)
        assertEquals(RECEIPT, restored.serverReceiptSha256)
        assertEquals(2, fixture.recordingReads.get())
        assertUploadPreservesLocalDeclarations(local)
    }

    @Test
    fun postCompletionRecording409RemainsTerminalWithoutLosingReceipt() {
        val local = completedRecording()
        startServer(local, postReceiptStatus = 409)

        ActivityScenario.launch(com.example.myapplication.MainActivity::class.java).use {
            awaitAutomaticScheduling()
            awaitRecordingWork(local.id)
        }

        val restored = requireNotNull(database.recording(local.id))
        assertEquals("permanent_error", restored.serverSyncState)
        assertEquals(RECEIPT, restored.serverReceiptSha256)
        database.readableDatabase.rawQuery(
            "SELECT last_error_code FROM server_sync_state WHERE recording_id=?",
            arrayOf(local.id),
        ).use { cursor ->
            assertTrue(cursor.moveToFirst())
            assertEquals("http_409", cursor.getString(0))
        }
        assertUploadPreservesLocalDeclarations(local)
    }

    @Test
    fun postCompletionCancellationIsCancelledAndKeepsReceipt() {
        val local = completedRecording()
        val fixture = startServer(local, postReceiptStatus = 404, holdPostReceipt = true)
        ActivityScenario.launch(com.example.myapplication.MainActivity::class.java).use {
            assertTrue("Post-receipt GET was not reached", fixture.postReceiptRead.await(30, TimeUnit.SECONDS))
            awaitAutomaticScheduling()

            val manager = WorkManager.getInstance(context)
            manager.cancelUniqueWork("server-sync-${local.id}").result.get(10, TimeUnit.SECONDS)
            fixture.releasePostReceipt.countDown()
            awaitWorkState(local.id, WorkInfo.State.CANCELLED)
        }

        val restored = requireNotNull(database.recording(local.id))
        assertEquals(RECEIPT, restored.serverReceiptSha256)
        assertEquals("retryable_error", restored.serverSyncState)
        database.readableDatabase.rawQuery(
            "SELECT last_error_code FROM server_sync_state WHERE recording_id=?",
            arrayOf(local.id),
        ).use { cursor ->
            assertTrue(cursor.moveToFirst())
            assertEquals("transfer_paused", cursor.getString(0))
        }
        assertUploadPreservesLocalDeclarations(local)
    }

    @Test
    fun authoritativeRestore404IsScheduled() {
        val local = completedRecording()
        startServer(local, postReceiptStatus = 404)
        database.markRecordingSyncError(local.id, false, "http_404", "Stale account scope")

        ActivityScenario.launch(com.example.myapplication.MainActivity::class.java).use {
            awaitAutomaticScheduling()
            serverOperationLock.lock()
            try {
                database.restoreServerMetadata(emptyList(), listOf(remoteWithoutReceipt(local)))
                val work = WorkManager.getInstance(context)
                    .getWorkInfosForUniqueWork("server-sync-${local.id}")
                    .get(10, TimeUnit.SECONDS)
                if (work.size != 1) {
                    throw AssertionError("Restore must schedule one worker: ${failureDiagnostics(local.id)}")
                }
                assertTrue("Requeued restore was not scheduled", work.single().state.isFinished.not())
                assertEquals(NetworkType.CONNECTED, work.single().constraints.requiredNetworkType)
            } finally {
                serverOperationLock.unlock()
            }
        }
    }

    private fun remoteWithoutReceipt(local: RecordingSyncRecord) = com.example.myapplication.data.RemoteRecording(
        id = local.id,
        dogId = local.dogId,
        profile = com.example.myapplication.data.RemoteProfileVersion(
            local.profileVersionId,
            local.profile.schemaVersion,
            local.profile.validationState,
            local.profile.questionnaireJson,
            local.profile.contentSha256,
            local.profile.clientCreatedAtUtc,
        ),
        source = local.source,
        captureStatus = local.captureStatus,
        startedAtUtc = local.startedAtUtc,
        endedAtUtc = local.endedAtUtc,
        timezone = local.timezone,
        sessionLabel = local.sessionLabel,
        questionnaireSchemaVersion = local.questionnaireSchemaVersion,
        questionnaireValidationState = local.questionnaireValidationState,
        sessionQuestionnaireJson = local.sessionQuestionnaireJson,
        videoRequested = local.videoRequested,
        sensorHardwareId = local.sensorHardwareId,
        appVersion = local.appVersion,
        protocolVersion = local.protocolVersion,
        captureErrorCode = local.captureErrorCode,
        captureErrorMessage = local.captureErrorMessage,
        receiptSha256 = null,
        verifiedAtUtc = null,
        sync = local.sync,
        artifacts = local.artifacts.map {
            com.example.myapplication.data.RemoteArtifact(
                it.id,
                it.type,
                it.fileName,
                it.mimeType,
                it.sizeBytes,
                it.sha256,
                "available",
            )
        },
    )

    private fun completedRecording(): RecordingSyncRecord {
        val profile = database.saveProfile(DogQuestionnaire(
            numberOrName = "Worker regression",
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
        ))
        val recording = database.beginRecording(
            profile.id,
            RecordingSource.LIVE,
            SessionQuestionnaire(
                sessionLabel = "Worker regression",
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
            ),
        )
        File(database.recordingDirectory(recording.relativeDirectory), "packets.bin").writeText("packet data")
        database.writeSyncMetadata(
            recording.id,
            CaptureSyncMetadata(
                recordingId = recording.id,
                profileId = profile.id,
                source = "live",
                timezone = recording.timezone,
                selectedSessionStartUtc = recording.startedAtUtc,
            ),
        )
        database.finishRecording(recording.id, RecordingStatus.COMPLETED)
        database.hashPendingArtifacts()
        return requireNotNull(database.recordingSyncRecord(recording.id))
    }

    private fun startServer(
        local: RecordingSyncRecord,
        postReceiptStatus: Int,
        holdPostReceipt: Boolean = false,
    ): UploadServer = UploadServer(local, postReceiptStatus, holdPostReceipt).also {
        server = it
        ServerSettingsStore(context).save(it.baseUrl, "worker-regression-token", false)
    }

    private fun awaitAutomaticScheduling() {
        val manager = WorkManager.getInstance(context)
        val workName = "server-artifact-hash"
        val liveData = manager.getWorkInfosForUniqueWorkLiveData(workName)
        val completed = CountDownLatch(1)
        var failure: AssertionError? = null
        val observer = Observer<List<WorkInfo>> { work ->
            when {
                work.size > 1 -> {
                    failure = AssertionError("Automatic scheduling created extra hash workers: ${workTrace(work)}")
                    completed.countDown()
                }
                work.size == 1 && work.single().state == WorkInfo.State.SUCCEEDED -> completed.countDown()
                work.size == 1 && work.single().state.isFinished -> {
                    failure = AssertionError("Automatic hash worker did not succeed: ${workTrace(work)}")
                    completed.countDown()
                }
            }
        }
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.runOnMainSync { liveData.observeForever(observer) }
        try {
            if (!completed.await(45, TimeUnit.SECONDS)) {
                val work = manager.getWorkInfosForUniqueWork(workName).get(5, TimeUnit.SECONDS)
                throw AssertionError("Automatic scheduling did not finish: ${workTrace(work)}, requests=${server?.requests}")
            }
            failure?.let { throw it }
        } finally {
            instrumentation.runOnMainSync { liveData.removeObserver(observer) }
        }
    }

    private fun awaitRecordingWork(id: String) {
        val manager = WorkManager.getInstance(context)
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(45)
        while (System.nanoTime() < deadline) {
            val work = manager.getWorkInfosForUniqueWork("server-sync-$id").get(5, TimeUnit.SECONDS)
            if (work.isNotEmpty() && work.all { it.state.isFinished }) {
                if (work.size != 1) {
                    throw AssertionError("Recording must have one worker generation: ${failureDiagnostics(id)}")
                }
                assertEquals(NetworkType.CONNECTED, work.single().constraints.requiredNetworkType)
                return
            }
            Thread.sleep(50)
        }
        throw AssertionError("Recording worker did not finish: ${failureDiagnostics(id)}")
    }

    private fun awaitWorkState(id: String, expected: WorkInfo.State) {
        val manager = WorkManager.getInstance(context)
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(30)
        while (System.nanoTime() < deadline) {
            val work = manager.getWorkInfosForUniqueWork("server-sync-$id").get(5, TimeUnit.SECONDS)
            if (work.size == 1 && work.single().state == expected) {
                assertEquals(NetworkType.CONNECTED, work.single().constraints.requiredNetworkType)
                return
            }
            if (work.size > 1 && work.all { it.state.isFinished }) {
                throw AssertionError("Recording must have one worker generation: ${failureDiagnostics(id)}")
            }
            Thread.sleep(50)
        }
        throw AssertionError("Recording worker did not reach $expected: ${failureDiagnostics(id)}")
    }

    private fun assertUploadPreservesLocalDeclarations(local: RecordingSyncRecord) {
        try {
            val current = requireNotNull(database.recordingSyncRecord(local.id))
            assertEquals(local.id, current.id)
            assertEquals(local.artifacts.map { it.id }.toSet(), current.artifacts.map { it.id }.toSet())
            local.artifacts.forEach { original ->
                val artifact = current.artifacts.single { it.id == original.id }
                assertEquals(original.sha256, artifact.sha256)
                assertEquals(original.sizeBytes, artifact.sizeBytes)
                assertEquals("available", artifact.uploadState)
            }
            database.readableDatabase.rawQuery(
                "SELECT attempt_count FROM server_sync_state WHERE recording_id=?",
                arrayOf(local.id),
            ).use { cursor ->
                assertTrue(cursor.moveToFirst())
                assertEquals(1, cursor.getInt(0))
            }
        } catch (error: AssertionError) {
            throw AssertionError("${error.message}; ${failureDiagnostics(local.id)}").apply { initCause(error) }
        }
    }

    private fun failureDiagnostics(id: String): String {
        val work = WorkManager.getInstance(context).getWorkInfosForUniqueWork("server-sync-$id")
            .get(5, TimeUnit.SECONDS)
        return "work=${workTrace(work)}, requests=${server?.requests}, failures=${server?.failures}"
    }

    private fun workTrace(work: List<WorkInfo>) =
        work.map { "id=${it.id},state=${it.state},generation=${it.generation}" }

    private class UploadServer(
        local: RecordingSyncRecord,
        private val postReceiptStatus: Int,
        private val holdPostReceipt: Boolean,
    ) {
        private val socket = ServerSocket(0, 10, InetAddress.getByName("127.0.0.1"))
        private val offsets = ConcurrentHashMap<String, Long>()
        private val recordingPath = "/v1/recordings/${local.id}"
        val recordingReads = AtomicInteger()
        val postReceiptRead = CountDownLatch(1)
        val releasePostReceipt = CountDownLatch(1)
        val requests = java.util.Collections.synchronizedList(mutableListOf<String>())
        val failures = java.util.Collections.synchronizedList(mutableListOf<Throwable>())
        val baseUrl = "http://127.0.0.1:${socket.localPort}"
        private val worker = thread(isDaemon = true, name = "recording-upload-fixture") {
            try {
                while (!socket.isClosed) {
                    try {
                        socket.accept().use(::respond)
                    } catch (error: Throwable) {
                        if (!socket.isClosed) failures += error
                    }
                }
            } catch (_: SocketException) {
            }
        }

        fun close() {
            releasePostReceipt.countDown()
            socket.close()
            worker.join(2_000)
        }

        private fun respond(client: Socket) {
            val input = client.getInputStream()
            val headerBytes = ByteArrayOutputStream()
            while (!headerBytes.toString("UTF-8").endsWith("\r\n\r\n")) {
                val next = input.read()
                check(next >= 0) { "Unexpected end of HTTP headers" }
                headerBytes.write(next)
            }
            val headers = headerBytes.toString("UTF-8")
            val parts = headers.lineSequence().first().split(" ")
            val method = parts[0]
            val path = parts[1]
            requests += "$method $path"
            val contentLength = Regex("(?i)Content-Length: (\\d+)").find(headers)?.groupValues?.get(1)?.toInt() ?: 0
            var remaining = contentLength
            while (remaining > 0) {
                val buffer = ByteArray(minOf(65_536, remaining))
                val read = input.read(buffer)
                check(read >= 0) { "Unexpected end of HTTP body" }
                remaining -= read
            }
            val status: Int
            var body = "{}"
            var uploadOffset: Long? = null
            when {
                method == "GET" && path.startsWith("/v1/deletions") -> {
                    status = 200
                    body = """{"entities":[],"nextCursor":null}"""
                }
                method == "GET" && path == recordingPath -> {
                    status = if (recordingReads.incrementAndGet() == 1) 404 else {
                        postReceiptRead.countDown()
                        if (holdPostReceipt) releasePostReceipt.await(20, TimeUnit.SECONDS)
                        postReceiptStatus
                    }
                }
                method == "PUT" && path.startsWith("/v1/dogs/") -> {
                    status = 200
                    body = """{"dogRevision":1,"serverTimestampUtc":"2026-11-12T00:00:00Z"}"""
                }
                method == "GET" && path == "$recordingPath/sync-status" -> status = 404
                method == "GET" && path == "/v1/me" -> {
                    status = 200
                    body = """{"deviceId":"00000000-0000-0000-0000-000000000001"}"""
                }
                method == "PUT" && path == recordingPath -> status = 200
                method == "HEAD" && path.startsWith("/v1/artifacts/") -> {
                    val id = path.removePrefix("/v1/artifacts/").removeSuffix("/content")
                    status = 200
                    uploadOffset = offsets[id] ?: 0L
                }
                method == "PATCH" && path.startsWith("/v1/artifacts/") -> {
                    val id = path.removePrefix("/v1/artifacts/").removeSuffix("/content")
                    status = 200
                    uploadOffset = offsets.merge(id, contentLength.toLong(), Long::plus) ?: contentLength.toLong()
                }
                method == "POST" && path.startsWith("/v1/artifacts/") -> status = 200
                method == "POST" && path == "$recordingPath/complete" -> {
                    status = 200
                    body = """{"receiptSha256":"$RECEIPT","verifiedAtUtc":"2026-11-12T00:00:00Z"}"""
                }
                else -> status = 500
            }
            val bytes = if (method == "HEAD") ByteArray(0) else body.toByteArray()
            val response = StringBuilder("HTTP/1.1 $status Fixture\r\nContent-Type: application/json\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n")
            uploadOffset?.let { response.append("Upload-Offset: $it\r\n") }
            response.append("\r\n")
            client.getOutputStream().apply {
                write(response.toString().toByteArray())
                write(bytes)
                flush()
            }
        }
    }

    private companion object {
        const val RECEIPT = "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    }
}
