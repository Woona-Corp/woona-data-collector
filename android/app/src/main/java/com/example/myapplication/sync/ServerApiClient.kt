package com.example.myapplication.sync

import com.example.myapplication.data.toJson
import com.example.myapplication.data.ProfileSyncRecord
import com.example.myapplication.data.RecordingSyncClock
import com.example.myapplication.data.RecordingSyncRecord
import com.example.myapplication.data.RemoteArtifact
import com.example.myapplication.data.RemoteDog
import com.example.myapplication.data.RemoteProfileVersion
import com.example.myapplication.data.RemoteRecording
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.RandomAccessFile
import java.net.HttpURLConnection
import java.net.URL
import java.nio.file.Files

data class ProfileServerReceipt(
    val dogRevision: Long,
    val serverTimestampUtc: String,
    val profileVersion: RemoteProfileVersion? = null,
)

data class RecordingServerReceipt(
    val receiptSha256: String,
    val verifiedAtUtc: String,
)

data class ServerRestoreSnapshot(
    val dogs: List<RemoteDog>,
    val recordings: List<RemoteRecording>,
    val deletions: List<Pair<String, String>> = emptyList(),
    val warnings: List<RestoreSkippedEntity> = emptyList(),
)

class ServerHttpException(
    val status: Int,
    val responseBody: String,
    val responseHeaders: Map<String, List<String>>,
) : IOException("Server returned HTTP $status: ${responseBody.take(500)}")

class ServerTransferException(val code: String, message: String, val retryable: Boolean = false) : IOException("$code: $message")

internal class TransferCursorGuard {
    private val seen = HashSet<String>()
    fun next(cursor: String?): String? {
        if (cursor == null) return null
        val parsed = runCatching { java.util.UUID.fromString(cursor).toString() }.getOrNull()
        if (parsed == null || !parsed.equals(cursor, ignoreCase = true)) throw ServerTransferException("pagination_cursor_invalid", "Server returned an invalid restore cursor")
        if (!seen.add(parsed)) throw ServerTransferException("pagination_stalled", "Server repeated a restore cursor. Previously restored local data is preserved.")
        return parsed
    }
}

class ServerApiClient(
    private val settings: ServerSettings,
    private val connectTimeoutMillis: Int = 15_000,
    private val readTimeoutMillis: Int = 30_000,
    private val chunkBytes: Int = 8 * 1024 * 1024,
    private val connectionFactory: (URL) -> HttpURLConnection = { it.openConnection() as HttpURLConnection },
    private val checkCancelled: () -> Unit = {
        if (Thread.currentThread().isInterrupted) throw java.io.InterruptedIOException("Transfer interrupted; local data is preserved")
    },
) {
    private var authenticatedDeviceId: String? = null

    init {
        require(settings.isConfigured)
        require(chunkBytes in 1 * 1024 * 1024..16 * 1024 * 1024)
    }

    fun applyAccount(identifier: String) {
        jsonRequest("PUT", "/v1/accounts/${com.example.myapplication.data.normalizeAccountId(identifier)}", JSONObject())
    }

    fun linkDogAccount(dogId: String, accountId: String) {
        jsonRequest("PUT", "/v1/dogs/$dogId/account", JSONObject().put("accountId", accountId))
    }

    fun editQuestionnaire(recordingId: String, revision: Int, questionnaire: com.example.myapplication.data.SessionQuestionnaire): RemoteRecording =
        parseRecording(jsonRequest("PUT", "/v1/recordings/$recordingId/questionnaire", JSONObject()
            .put("expectedRevision", revision).put("questionnaire", JSONObject(questionnaire.toJson()))))

    fun uploadProfile(record: ProfileSyncRecord): ProfileServerReceipt {
        val response = jsonRequest(
            method = "PUT",
            path = "/v1/dogs/${record.dogId}/profile-versions/${record.profileVersionId}",
            body = profilePayload(record),
        )
        return ProfileServerReceipt(
            dogRevision = response.getLong("dogRevision"),
            serverTimestampUtc = response.getString("serverTimestampUtc"),
            profileVersion = response.optJSONObject("profileVersion")?.let(::parseProfile),
        )
    }

    fun uploadRecording(
        record: RecordingSyncRecord,
        fileForArtifact: (String) -> File,
        onProgress: (artifactId: String, uploadedBytes: Long, available: Boolean) -> Unit,
    ): RecordingServerReceipt {
        val existing = try { jsonRequest("GET", "/v1/recordings/${record.id}/sync-status", null) }
            catch (error: ServerHttpException) { if (error.status == 404) null else throw error }
        val alreadyComplete = existing?.optString("ingestStatus") == "complete"
        if (!alreadyComplete) jsonRequest(
            method = "PUT",
            path = "/v1/recordings/${record.id}",
            body = recordingManifest(record),
        )
        val references = record.artifacts.filter { it.type in setOf("ecg", "heart_rate", "rr") && it.uploadState != "available" }
        if (alreadyComplete) references.forEach { artifact ->
            val payload = recordingManifest(record).getJSONArray("artifacts").let { items ->
                (0 until items.length()).map { items.getJSONObject(it) }.first { it.getString("id") == artifact.id }
            }
            jsonRequest("POST", "/v1/recordings/${record.id}/references", payload)
        }
        (if (alreadyComplete) references else record.artifacts).forEach { artifact ->
            val file = fileForArtifact(artifact.id)
            require(file.isFile && file.length() == artifact.sizeBytes) {
                "Artifact ${artifact.id} is missing or changed"
            }
            uploadArtifactBytes(artifact.id, artifact.sizeBytes, file) { offset ->
                onProgress(artifact.id, offset, false)
            }
            jsonRequest("POST", "/v1/artifacts/${artifact.id}/complete", JSONObject())
            onProgress(artifact.id, artifact.sizeBytes, true)
        }
        val receipt = if (alreadyComplete) requireNotNull(existing) else jsonRequest("POST", "/v1/recordings/${record.id}/complete", JSONObject())
        return RecordingServerReceipt(
            receiptSha256 = receipt.getString("receiptSha256"),
            verifiedAtUtc = receipt.getString("verifiedAtUtc"),
        )
    }

    fun downloadArtifact(
        artifactId: String,
        expectedSize: Long,
        expectedSha256: String,
        target: File,
    ): File {
        ensureTransferActive()
        require(expectedSize >= 0) { "Artifact size cannot be negative" }
        if (target.isFile) {
            if (target.length() != expectedSize || sha256(target, ::ensureTransferActive) != expectedSha256) {
                throw ServerTransferException("local_artifact_conflict", "A different local file exists. It was preserved; choose another destination.")
            }
            return target
        }
        val partial = File(target.parentFile, "${target.name}.download.part")
        partial.parentFile?.let { if (!it.isDirectory && !it.mkdirs()) throw IOException("Cannot create download directory") }
        var offset = partial.takeIf(File::isFile)?.length() ?: 0L
        if (offset == expectedSize && partial.isFile) {
            if (sha256(partial, ::ensureTransferActive) == expectedSha256) return finishDownload(partial, target)
            check(partial.delete()) { "Cannot remove an invalid incomplete download" }
            offset = 0L
        }
        if (offset > expectedSize) {
            check(partial.delete()) { "Cannot remove an oversized incomplete download" }
            offset = 0L
        }
        val connection = open("GET", "/v1/artifacts/$artifactId/content").apply {
            setRequestProperty("Accept-Encoding", "identity")
            if (offset > 0L) {
                setRequestProperty("Range", "bytes=$offset-")
                setRequestProperty("If-Range", "\"$expectedSha256\"")
            }
        }
        try {
            val status = connection.responseCode
            if (status !in setOf(HttpURLConnection.HTTP_OK, HttpURLConnection.HTTP_PARTIAL)) throw error(connection, status)
            validateDownloadHeaders(connection, status, offset, expectedSize, expectedSha256)
            // A server may ignore Range and return the complete representation. Reuse this
            // response from byte zero; do not recursively request it or append it to a prefix.
            if (status == HttpURLConnection.HTTP_OK) offset = 0
            var written = offset
            connection.inputStream.use { input ->
                FileOutputStream(partial, offset > 0L).buffered().use { output ->
                    val buffer = ByteArray(65_536)
                    while (true) {
                        ensureTransferActive()
                        val count = input.read(buffer)
                        if (count < 0) break
                        if (count.toLong() > expectedSize - written) {
                            throw ServerTransferException("download_size_invalid", "Server sent more data than the declared artifact size")
                        }
                        output.write(buffer, 0, count)
                        written += count
                    }
                }
            }
            if (written != expectedSize) throw ServerTransferException("download_incomplete", "Download ended at $written of $expectedSize bytes. The received prefix is preserved for retry.", retryable = true)
        } catch (failure: ServerTransferException) {
            if (failure.code == "download_size_invalid") partial.delete()
            throw failure
        } finally { ServerTransferRegistry.release(connection) }
        ensureTransferActive()
        if (sha256(partial, ::ensureTransferActive) != expectedSha256) {
            partial.delete()
            throw ServerTransferException("download_hash_mismatch", "Downloaded file failed SHA-256 verification; the incomplete copy was discarded and original data is preserved", retryable = true)
        }
        return finishDownload(partial, target)
    }

    private fun finishDownload(partial: File, target: File): File {
        ensureTransferActive()
        // No REPLACE_EXISTING: a concurrently created local file must be preserved too.
        Files.move(partial.toPath(), target.toPath())
        return target
    }

    private fun validateDownloadHeaders(connection: HttpURLConnection, status: Int, offset: Long, size: Long, sha256: String) {
        val encoding = connection.getHeaderField("Content-Encoding")
        if (encoding != null && !encoding.equals("identity", ignoreCase = true)) {
            throw ServerTransferException("download_encoding_invalid", "The server ignored identity encoding; byte ranges cannot be trusted")
        }
        val etag = connection.getHeaderField("ETag")?.trim()
        if (etag != null && etag != sha256 && etag != "\"$sha256\"") {
            throw ServerTransferException("download_etag_mismatch", "Server artifact ETag differs from its saved SHA-256. Existing local data is preserved.")
        }
        val remaining = if (status == HttpURLConnection.HTTP_PARTIAL) {
            val match = Regex("bytes ([0-9]+)-([0-9]+)/([0-9]+)").matchEntire(connection.getHeaderField("Content-Range").orEmpty())
            val start = match?.groupValues?.get(1)?.toLongOrNull()
            val end = match?.groupValues?.get(2)?.toLongOrNull()
            val total = match?.groupValues?.get(3)?.toLongOrNull()
            if (start != offset || total != size || size == 0L || end != size - 1) {
                throw ServerTransferException("download_range_invalid", "Server returned a different or malformed byte range. The existing partial copy is preserved.")
            }
            size - offset
        } else size
        val length = connection.getHeaderField("Content-Length")
        if (length != null && length.toLongOrNull() != remaining) {
            throw ServerTransferException("download_length_invalid", "Server response length differs from its byte range and saved artifact size")
        }
    }

    fun fetchRestoreSnapshot(): ServerRestoreSnapshot {
        val dogs = mutableListOf<RemoteDog>()
        val recordings = mutableListOf<RemoteRecording>()
        val skipped = mutableListOf<RestoreSkippedEntity>()
        fun detail(path: String, kind: String, id: String, dogId: String? = null): JSONObject? = try {
            jsonRequest("GET", path, null)
        } catch (error: ServerHttpException) {
            if (error.status !in setOf(404,410)) throw error
            skipped += RestoreSkippedEntity(kind,id,error.status,dogId)
            null
        }
        var dogCursor: String? = null
        val dogCursors = TransferCursorGuard()
        do {
            val page = jsonRequest("GET", "/v1/dogs?limit=200${dogCursor?.let { "&cursor=$it" }.orEmpty()}", null)
            val items = page.getJSONArray("items")
            repeat(items.length()) { index ->
                val dogId = items.getJSONObject(index).getString("id")
                val value = detail("/v1/dogs/$dogId", "dog", dogId) ?: return@repeat
                dogs += parseDog(value)
                var recordingCursor: String? = null
                val recordingCursors = TransferCursorGuard()
                do {
                    val recordingPage = detail("/v1/dogs/$dogId/recordings?limit=200${recordingCursor?.let { "&cursor=$it" }.orEmpty()}", "dog", dogId) ?: break
                    val recordingItems = recordingPage.getJSONArray("items")
                    repeat(recordingItems.length()) recording@{ recordingIndex ->
                        val id = recordingItems.getJSONObject(recordingIndex).getString("id")
                        val recording = detail("/v1/recordings/$id", "recording", id, dogId) ?: return@recording
                        recordings += parseRecording(recording)
                    }
                    recordingCursor = recordingCursors.next(recordingPage.nullableString("nextCursor"))
                } while (recordingCursor != null)
            }
            dogCursor = dogCursors.next(page.nullableString("nextCursor"))
        } while (dogCursor != null)
        // Fetch negative knowledge last: an item can be retired between list and detail.
        val deletions = fetchDeletions()
        val markers = deletions.toSet()
        fun hasMarker(kind: String, id: String): Boolean = kind to java.security.MessageDigest.getInstance("SHA-256")
            .digest(id.lowercase().toByteArray()).joinToString("") { "%02x".format(it) } in markers
        return ServerRestoreSnapshot(dogs, recordings, deletions, skipped.map {
            it.copy(confirmedRetirement = it.status == 410 || hasMarker(it.kind,it.id) || it.dogId?.let { dog -> hasMarker("dog",dog) } == true)
        })
    }

    fun fetchDeletions(): List<Pair<String, String>> {
        val entities = jsonRequest("GET", "/v1/deletions", null).getJSONArray("entities")
        return (0 until entities.length()).map { index ->
            val item = entities.getJSONObject(index)
            item.getString("kind") to item.getString("id_sha256")
        }
    }

    fun fetchRecording(recordingId: String): RemoteRecording =
        parseRecording(jsonRequest("GET", "/v1/recordings/$recordingId", null))

    fun fetchDog(dogId: String): RemoteDog = parseDog(jsonRequest("GET", "/v1/dogs/$dogId",null))

    fun checkConnection() {
        val connection = open("GET", "/health/ready", authenticated = false)
        try {
            val status = connection.responseCode
            if (status !in 200..299) throw error(connection, status)
        } finally { ServerTransferRegistry.release(connection) }
        // Readiness is public; an authenticated read verifies the token and account too.
        jsonRequest("GET", "/v1/dogs?limit=1", null)
    }

    fun syncStatus(recordingId: String): org.json.JSONObject =
        jsonRequest("GET", "/v1/recordings/$recordingId/sync-status", null)

    fun readiness(): Boolean {
        val connection = open("GET", "/health/ready", authenticated = false)
        return try {
            connection.responseCode == HttpURLConnection.HTTP_OK
        } finally {
            ServerTransferRegistry.release(connection)
        }
    }

    internal fun uploadArtifactBytes(artifactId: String, size: Long, file: File, onProgress: (Long) -> Unit = {}) {
        require(size >= 0 && file.isFile && file.length() == size) { "Local artifact is missing or changed" }
        var offset = uploadOffset(artifactId, size)
        var resynchronizations = 0
        onProgress(offset)
        RandomAccessFile(file, "r").use { input ->
            val buffer = ByteArray(chunkBytes)
            while (offset < size) {
                ensureTransferActive()
                val wanted = minOf(buffer.size.toLong(), size - offset).toInt()
                input.seek(offset)
                try { input.readFully(buffer, 0, wanted) }
                catch (_: java.io.EOFException) { throw ServerTransferException("local_artifact_truncated", "The source file ended before its saved size; original files are preserved") }
                val acknowledged = patch(artifactId, offset, buffer, wanted)
                offset = if (acknowledged == null) {
                    if (++resynchronizations > 3) throw ServerTransferException("upload_conflict_stalled", "Server repeatedly rejected the upload offset. Retry will resume from its confirmed position.", retryable = true)
                    uploadOffset(artifactId, size)
                } else {
                    if (acknowledged != offset + wanted) throw ServerTransferException("upload_offset_invalid", "PATCH acknowledged $acknowledged bytes; expected ${offset + wanted}. Upload completion is not confirmed.")
                    acknowledged
                }
                onProgress(offset)
            }
        }
    }

    private fun uploadOffset(artifactId: String, size: Long): Long {
        val connection = open("HEAD", "/v1/artifacts/$artifactId/content")
        return try {
            val status = connection.responseCode
            if (status !in 200..299) throw error(connection, status)
            val offset = requiredOffset(connection)
            if (offset !in 0..size) throw ServerTransferException("upload_offset_invalid", "HEAD returned $offset bytes for a $size-byte artifact")
            offset
        } finally { ServerTransferRegistry.release(connection) }
    }

    private fun requiredOffset(connection: HttpURLConnection): Long = connection.getHeaderField("Upload-Offset")?.toLongOrNull()
        ?: throw ServerTransferException("upload_offset_missing", "Server omitted a valid Upload-Offset. Its accepted position must be checked before continuing.")

    /** A conflict is recovered only through a fresh bounded HEAD, never by guessing. */
    private fun patch(artifactId: String, offset: Long, bytes: ByteArray, length: Int): Long? {
        val connection = open("PATCH", "/v1/artifacts/$artifactId/content").apply {
            setRequestProperty("Content-Type", "application/offset+octet-stream")
            setRequestProperty("Upload-Offset", offset.toString())
            setFixedLengthStreamingMode(length)
            doOutput = true
        }
        return try {
            connection.outputStream.use { output ->
                var position = 0
                while (position < length) {
                    ensureTransferActive()
                    val count = minOf(65_536, length - position)
                    output.write(bytes, position, count)
                    position += count
                }
            }
            val status = connection.responseCode
            if (status == HttpURLConnection.HTTP_CONFLICT) null
            else {
                if (status !in 200..299) throw error(connection, status)
                requiredOffset(connection)
            }
        } finally { ServerTransferRegistry.release(connection) }
    }

    private fun jsonRequest(method: String, path: String, body: JSONObject?): JSONObject {
        val encoded = body?.toString()?.toByteArray(Charsets.UTF_8)
        val connection = open(method, path).apply {
            if (encoded != null) {
                setRequestProperty("Content-Type", "application/json")
                setFixedLengthStreamingMode(encoded.size)
                doOutput = true
            }
        }
        return try {
            if (encoded != null) connection.outputStream.use { it.write(encoded) }
            val status = connection.responseCode
            if (status !in 200..299) throw error(connection, status)
            val response = connection.inputStream.bufferedReader().use { it.readText() }
            if (response.isBlank()) JSONObject() else JSONObject(response)
        } finally { ServerTransferRegistry.release(connection) }
    }

    private fun ensureTransferActive() {
        checkCancelled()
        ServerTransferRegistry.ensureActive(settings.transferGeneration)
    }

    private fun open(method: String, path: String, authenticated: Boolean = true): HttpURLConnection {
        ensureTransferActive()
        return connectionFactory(URL(settings.baseUrl + path)).apply {
            requestMethod = method
            connectTimeout = connectTimeoutMillis
            readTimeout = readTimeoutMillis
            useCaches = false
            instanceFollowRedirects = false // Never forward device credentials to another host.
            setRequestProperty("Accept", "application/json")
            if (authenticated) setRequestProperty("Authorization", "Bearer ${settings.token}")
            settings.accountId?.let { setRequestProperty("X-Woona-Account", it) }
            ServerTransferRegistry.register(this, settings.transferGeneration)
        }
    }

    private fun error(connection: HttpURLConnection, status: Int): ServerHttpException {
        // Bound untrusted error payloads; callers always release the connection in finally.
        val body = try { connection.errorStream?.bufferedReader()?.use { reader ->
            val buffer = CharArray(16_384)
            var size = 0
            while (size < buffer.size) {
                ensureTransferActive()
                val read = reader.read(buffer, size, buffer.size - size)
                if (read < 0) break
                size += read
            }
            String(buffer, 0, size)
        }.orEmpty() } catch (failure: IOException) {
            if (Thread.currentThread().isInterrupted) throw failure
            "The error response body could not be read (${failure.javaClass.simpleName}); HTTP status $status was received."
        }
        return ServerHttpException(status, body, connection.headerFields)
    }

    private fun profilePayload(record: ProfileSyncRecord): JSONObject = JSONObject().apply {
        put(
            "dog",
            JSONObject().apply {
                put("id", record.dogId)
                put("numberOrName", record.dogName)
                put("expectedRevision", record.expectedRevision)
            },
        )
        put(
            "profileVersion",
            JSONObject().apply {
                put("id", record.profileVersionId)
                put("schemaVersion", record.schemaVersion)
                put("validationState", record.validationState)
                put("questionnaire", JSONObject(record.questionnaireJson))
                put("contentSha256", record.contentSha256)
                put("clientCreatedAtUtc", record.clientCreatedAtUtc)
            },
        )
    }

    private fun recordingManifest(record: RecordingSyncRecord): JSONObject = JSONObject().apply {
        put("schemaVersion", 1)
        put(
            "captureDeviceId",
            authenticatedDeviceId ?: jsonRequest("GET", "/v1/me", null)
                .getString("deviceId")
                .also { authenticatedDeviceId = it },
        )
        put("dog", profilePayload(record.profile).getJSONObject("dog"))
        put("dogProfileVersion", profilePayload(record.profile).getJSONObject("profileVersion"))
        put(
            "recording",
            JSONObject().apply {
                put("source", record.source)
                put("captureStatus", record.captureStatus)
                put("startedAtUtc", record.startedAtUtc)
                putNullable("endedAtUtc", record.endedAtUtc)
                put("timezone", record.timezone)
                put("sessionLabel", record.sessionLabel)
                put("videoRequested", record.videoRequested)
                putNullable("sensorHardwareId", record.sensorHardwareId)
                put("appVersion", record.appVersion)
                putNullable("protocolVersion", record.protocolVersion)
                put("questionnaireSchemaVersion", record.questionnaireSchemaVersion)
                put("questionnaireValidationState", record.questionnaireValidationState)
                put("sessionQuestionnaire", JSONObject(record.sessionQuestionnaireJson))
                putNullable("captureErrorCode", record.captureErrorCode)
                putNullable("captureErrorMessage", record.captureErrorMessage)
            },
        )
        put(
            "sync",
            JSONObject().apply {
                val sync = record.sync
                put("schemaVersion", sync.schemaVersion)
                put("monotonicClock", sync.monotonicClock)
                put("sessionZeroAtUtc", sync.sessionZeroAtUtc)
                put("sessionZeroWallClockMs", sync.sessionZeroWallClockMs)
                put("sessionZeroMonotonicNs", sync.sessionZeroMonotonicNs)
                put("sessionZeroUncertaintyNs", sync.sessionZeroUncertaintyNs)
                putNullable("firstSensorPacketMonotonicNs", sync.firstSensorPacketMonotonicNs)
                putNullable("firstSensorDeviceTimerMs", sync.firstSensorDeviceTimerMillis)
                putNullable("lastSensorPacketMonotonicNs", sync.lastSensorPacketMonotonicNs)
                putNullable("videoRequestedMonotonicNs", sync.videoRequestedMonotonicNs)
                putNullable("mediaRecorderStartedMonotonicNs", sync.mediaRecorderStartedMonotonicNs)
                putNullable("videoFirstFrameMonotonicNs", sync.videoFirstFrameMonotonicNs)
                putNullable("videoFirstFrameCameraTimestampNs", sync.videoFirstFrameCameraTimestampNs)
                putNullable("videoFirstFrameCallbackMonotonicNs", sync.videoFirstFrameCallbackMonotonicNs)
                putNullable("videoFirstSamplePtsUs", sync.videoFirstSamplePtsUs)
                putNullable("videoOffsetFromSensorNs", sync.videoOffsetFromSensorNs)
                putNullable("cameraTimestampSource", sync.cameraTimestampSource)
                put("cameraClockQuality", sync.cameraClockQuality)
                put("sensorClockQuality", sync.sensorClockQuality)
                put("overallSyncQuality", sync.overallSyncQuality)
                put("calibrationOffsetNs", sync.calibrationOffsetNs)
                putNullable("estimatedDriftPpm", sync.estimatedDriftPpm)
            },
        )
        put(
            "artifacts",
            JSONArray().apply {
                record.artifacts.forEach { artifact ->
                    put(
                        JSONObject().apply {
                            put("id", artifact.id)
                            put("type", artifact.type)
                            put("fileName", artifact.fileName)
                            put("mimeType", artifact.mimeType)
                            put("sizeBytes", artifact.sizeBytes)
                            put("sha256", artifact.sha256)
                            put("clientCreatedAtUtc", artifact.clientCreatedAtUtc)
                            artifact.referenceMetadataJson?.let { put("referenceMetadata", JSONObject(it)) }
                        },
                    )
                }
            },
        )
    }

    private fun parseDog(value: JSONObject): RemoteDog {
        val profile = value.getJSONObject("profileVersion")
        return RemoteDog(
            id = value.getString("id"),
            accountId = value.nullableString("accountId"),
            numberOrName = value.getString("numberOrName"),
            revision = value.getLong("revision"),
            profile = parseProfile(profile),
            profileVersions = value.optJSONArray("profileVersions")?.let { versions ->
                buildList {
                    repeat(versions.length()) { index ->
                        add(parseProfile(versions.getJSONObject(index)))
                    }
                }
            } ?: listOf(parseProfile(profile)),
        )
    }

    private fun parseProfile(value: JSONObject): RemoteProfileVersion = RemoteProfileVersion(
        id = value.getString("id"),
        schemaVersion = value.getInt("schemaVersion"),
        validationState = value.optString("validationState", "complete"),
        questionnaireJson = value.getJSONObject("questionnaire").toString(),
        contentSha256 = value.getString("contentSha256"),
        clientCreatedAtUtc = value.getString("clientCreatedAtUtc"),
        supersededAtUtc = value.nullableString("supersededAtUtc"),
    )

    private fun parseRecording(value: JSONObject): RemoteRecording {
        val sync = value.getJSONObject("sync")
        val artifactValues = value.getJSONArray("artifacts")
        return RemoteRecording(
            id = value.getString("id"),
            dogId = value.getString("dogId"),
            profile = parseProfile(value.getJSONObject("profileVersion")),
            source = value.getString("source"),
            captureStatus = value.getString("captureStatus"),
            startedAtUtc = value.getString("startedAtUtc"),
            endedAtUtc = value.nullableString("endedAtUtc"),
            timezone = value.getString("timezone"),
            sessionLabel = value.getString("sessionLabel"),
            questionnaireSchemaVersion = value.getInt("questionnaireSchemaVersion"),
            questionnaireValidationState = value.getString("questionnaireValidationState"),
            sessionQuestionnaireJson = value.getJSONObject("sessionQuestionnaire").toString(),
            questionnaireRevision = value.optInt("questionnaireRevision", 1),
            accountId = value.nullableString("accountId"),
            videoRequested = value.getBoolean("videoRequested"),
            sensorHardwareId = value.nullableString("sensorHardwareId"),
            appVersion = value.getString("appVersion"),
            protocolVersion = value.nullableString("protocolVersion"),
            captureErrorCode = value.nullableString("captureErrorCode"),
            captureErrorMessage = value.nullableString("captureErrorMessage"),
            receiptSha256 = value.nullableString("receiptSha256"),
            verifiedAtUtc = value.nullableString("serverVerifiedAtUtc"),
            sync = RecordingSyncClock(
                schemaVersion = sync.getInt("schemaVersion"),
                monotonicClock = sync.getString("monotonicClock"),
                sessionZeroAtUtc = sync.getString("sessionZeroAtUtc"),
                sessionZeroWallClockMs = sync.getLong("sessionZeroWallClockMs"),
                sessionZeroMonotonicNs = sync.getLong("sessionZeroMonotonicNs"),
                sessionZeroUncertaintyNs = sync.getLong("sessionZeroUncertaintyNs"),
                firstSensorPacketMonotonicNs = sync.nullableLong("firstSensorPacketMonotonicNs"),
                firstSensorDeviceTimerMillis = sync.nullableLong("firstSensorDeviceTimerMs"),
                lastSensorPacketMonotonicNs = sync.nullableLong("lastSensorPacketMonotonicNs"),
                videoRequestedMonotonicNs = sync.nullableLong("videoRequestedMonotonicNs"),
                mediaRecorderStartedMonotonicNs = sync.nullableLong("mediaRecorderStartedMonotonicNs"),
                videoFirstFrameMonotonicNs = sync.nullableLong("videoFirstFrameMonotonicNs"),
                videoFirstFrameCameraTimestampNs = sync.nullableLong("videoFirstFrameCameraTimestampNs"),
                videoFirstFrameCallbackMonotonicNs = sync.nullableLong("videoFirstFrameCallbackMonotonicNs"),
                videoFirstSamplePtsUs = sync.nullableLong("videoFirstSamplePtsUs"),
                videoOffsetFromSensorNs = sync.nullableLong("videoOffsetFromSensorNs"),
                cameraTimestampSource = sync.nullableString("cameraTimestampSource"),
                cameraClockQuality = sync.getString("cameraClockQuality"),
                sensorClockQuality = sync.getString("sensorClockQuality"),
                overallSyncQuality = sync.getString("overallSyncQuality"),
                calibrationOffsetNs = sync.getLong("calibrationOffsetNs"),
                estimatedDriftPpm = sync.nullableDouble("estimatedDriftPpm"),
            ),
            artifacts = buildList {
                repeat(artifactValues.length()) { index ->
                    val artifact = artifactValues.getJSONObject(index)
                    add(
                        RemoteArtifact(
                            id = artifact.getString("id"),
                            type = artifact.getString("type"),
                            fileName = artifact.getString("fileName"),
                            mimeType = artifact.getString("mimeType"),
                            sizeBytes = artifact.getLong("sizeBytes"),
                            sha256 = artifact.getString("sha256"),
                            storageStatus = artifact.getString("storageStatus"),
                            referenceMetadataJson = artifact.optJSONObject("referenceMetadata")?.toString(),
                        ),
                    )
                }
            },
        )
    }
}

private fun JSONObject.putNullable(key: String, value: Any?) {
    put(key, value ?: JSONObject.NULL)
}

private fun JSONObject.nullableString(key: String): String? =
    if (!has(key) || isNull(key)) null else getString(key)

private fun JSONObject.nullableLong(key: String): Long? =
    if (!has(key) || isNull(key)) null else getLong(key)

private fun JSONObject.nullableDouble(key: String): Double? =
    if (!has(key) || isNull(key)) null else getDouble(key)

private fun sha256(file: File, checkCancelled: () -> Unit = {}): String {
    val digest = java.security.MessageDigest.getInstance("SHA-256")
    file.inputStream().buffered().use { input ->
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        while (true) {
            checkCancelled()
            val read = input.read(buffer)
            if (read < 0) break
            digest.update(buffer, 0, read)
        }
    }
    return digest.digest().joinToString("") { "%02x".format(it) }
}
