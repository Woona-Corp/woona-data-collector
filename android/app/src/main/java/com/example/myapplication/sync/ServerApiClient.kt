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
import java.nio.file.StandardCopyOption

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
)

class ServerHttpException(
    val status: Int,
    val responseBody: String,
    val responseHeaders: Map<String, List<String>>,
) : IOException("Server returned HTTP $status: ${responseBody.take(500)}")

class ServerApiClient(
    private val settings: ServerSettings,
    private val connectTimeoutMillis: Int = 15_000,
    private val readTimeoutMillis: Int = 30_000,
    private val chunkBytes: Int = 8 * 1024 * 1024,
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
            var offset = uploadOffset(artifact.id)
            require(offset in 0..artifact.sizeBytes) { "Invalid server offset $offset" }
            onProgress(artifact.id, offset, false)
            RandomAccessFile(file, "r").use { input ->
                val buffer = ByteArray(chunkBytes)
                while (offset < artifact.sizeBytes) {
                    val wanted = minOf(buffer.size.toLong(), artifact.sizeBytes - offset).toInt()
                    input.seek(offset)
                    input.readFully(buffer, 0, wanted)
                    offset = patch(artifact.id, offset, buffer, wanted)
                    require(offset in 0..artifact.sizeBytes) { "Invalid server offset $offset" }
                    onProgress(artifact.id, offset, false)
                }
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
        if (target.isFile) {
            require(target.length() == expectedSize && sha256(target) == expectedSha256) {
                "A different local artifact already exists"
            }
            return target
        }
        val partial = File(target.parentFile, "${target.name}.download.part")
        partial.parentFile?.mkdirs()
        var offset = partial.takeIf(File::isFile)?.length() ?: 0L
        if (offset > expectedSize) {
            partial.delete()
            offset = 0L
        }
        val connection = open("GET", "/v1/artifacts/$artifactId/content").apply {
            setRequestProperty("Accept-Encoding", "identity")
            if (offset > 0L) setRequestProperty("Range", "bytes=$offset-")
        }
        val status = connection.responseCode
        if (status !in setOf(HttpURLConnection.HTTP_OK, HttpURLConnection.HTTP_PARTIAL)) {
            throw error(connection, status)
        }
        val etag = connection.getHeaderField("ETag")?.trim('"')
        require(etag == null || etag == expectedSha256) { "Server artifact hash changed" }
        if (offset > 0L && status != HttpURLConnection.HTTP_PARTIAL) {
            partial.delete()
            connection.disconnect()
            return downloadArtifact(artifactId, expectedSize, expectedSha256, target)
        }
        if (offset > 0L) {
            require(connection.getHeaderField("Content-Range")?.startsWith("bytes $offset-") == true) {
                "Server returned a different download range"
            }
        }
        connection.inputStream.use { input ->
            FileOutputStream(partial, offset > 0L).buffered().use { output ->
                input.copyTo(output)
            }
        }
        connection.disconnect()
        require(partial.length() == expectedSize) { "Downloaded artifact size mismatch" }
        if (sha256(partial) != expectedSha256) {
            partial.delete()
            throw IOException("Downloaded artifact hash mismatch")
        }
        try {
            Files.move(
                partial.toPath(),
                target.toPath(),
                StandardCopyOption.ATOMIC_MOVE,
            )
        } catch (_: java.nio.file.AtomicMoveNotSupportedException) {
            Files.move(partial.toPath(), target.toPath())
        }
        return target
    }

    fun fetchRestoreSnapshot(): ServerRestoreSnapshot {
        val dogs = mutableListOf<RemoteDog>()
        val recordings = mutableListOf<RemoteRecording>()
        var dogCursor: String? = null
        do {
            val page = jsonRequest(
                "GET",
                "/v1/dogs?limit=200${dogCursor?.let { "&cursor=$it" }.orEmpty()}",
                null,
            )
            val items = page.getJSONArray("items")
            repeat(items.length()) { index ->
                val dogId = items.getJSONObject(index).getString("id")
                val dog = parseDog(jsonRequest("GET", "/v1/dogs/$dogId", null))
                dogs += dog
                var recordingCursor: String? = null
                do {
                    val recordingPage = jsonRequest(
                        "GET",
                        "/v1/dogs/$dogId/recordings?limit=200${recordingCursor?.let { "&cursor=$it" }.orEmpty()}",
                        null,
                    )
                    val recordingItems = recordingPage.getJSONArray("items")
                    repeat(recordingItems.length()) { recordingIndex ->
                        recordings += parseRecording(
                            jsonRequest(
                                "GET",
                                "/v1/recordings/${recordingItems.getJSONObject(recordingIndex).getString("id")}",
                                null,
                            ),
                        )
                    }
                    recordingCursor = recordingPage.nullableString("nextCursor")
                } while (recordingCursor != null)
            }
            dogCursor = page.nullableString("nextCursor")
        } while (dogCursor != null)
        return ServerRestoreSnapshot(dogs, recordings, fetchDeletions())
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
        } finally { connection.disconnect() }
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
            connection.disconnect()
        }
    }

    private fun uploadOffset(artifactId: String): Long {
        val connection = open("HEAD", "/v1/artifacts/$artifactId/content")
        val status = connection.responseCode
        if (status !in 200..299) throw error(connection, status)
        return connection.getHeaderField("Upload-Offset")?.toLongOrNull()
            ?: throw IOException("Server omitted Upload-Offset")
    }

    private fun patch(
        artifactId: String,
        offset: Long,
        bytes: ByteArray,
        length: Int,
    ): Long {
        val connection = open("PATCH", "/v1/artifacts/$artifactId/content").apply {
            setRequestProperty("Content-Type", "application/offset+octet-stream")
            setRequestProperty("Upload-Offset", offset.toString())
            setFixedLengthStreamingMode(length)
            doOutput = true
        }
        connection.outputStream.use { it.write(bytes, 0, length) }
        val status = connection.responseCode
        if (status == HttpURLConnection.HTTP_CONFLICT) {
            connection.disconnect()
            return uploadOffset(artifactId)
        }
        if (status !in 200..299) throw error(connection, status)
        return connection.getHeaderField("Upload-Offset")?.toLongOrNull()
            ?: throw IOException("Server omitted Upload-Offset")
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
        if (encoded != null) connection.outputStream.use { it.write(encoded) }
        val status = connection.responseCode
        if (status !in 200..299) throw error(connection, status)
        val response = connection.inputStream.bufferedReader().use { it.readText() }
        connection.disconnect()
        return if (response.isBlank()) JSONObject() else JSONObject(response)
    }

    private fun open(
        method: String,
        path: String,
        authenticated: Boolean = true,
    ): HttpURLConnection = (URL(settings.baseUrl + path).openConnection() as HttpURLConnection).apply {
        requestMethod = method
        connectTimeout = connectTimeoutMillis
        readTimeout = readTimeoutMillis
        useCaches = false
        setRequestProperty("Accept", "application/json")
        if (authenticated) setRequestProperty("Authorization", "Bearer ${settings.token}")
        settings.accountId?.let { setRequestProperty("X-Woona-Account", it) }
    }

    private fun error(connection: HttpURLConnection, status: Int): ServerHttpException {
        val body = connection.errorStream?.bufferedReader()?.use { it.readText() }.orEmpty()
        val exception = ServerHttpException(status, body, connection.headerFields)
        connection.disconnect()
        return exception
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
                put("monotonicClock", "android.elapsedRealtimeNanos")
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

private fun sha256(file: File): String {
    val digest = java.security.MessageDigest.getInstance("SHA-256")
    file.inputStream().buffered().use { input ->
        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            digest.update(buffer, 0, read)
        }
    }
    return digest.digest().joinToString("") { "%02x".format(it) }
}
