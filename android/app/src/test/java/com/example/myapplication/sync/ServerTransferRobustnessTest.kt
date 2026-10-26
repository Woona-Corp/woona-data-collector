package com.example.myapplication.sync

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.SocketTimeoutException
import java.net.URL
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.CancellationException

class ServerTransferRobustnessTest {
    private data class Response(val status: Int = 200, val headers: Map<String, String> = emptyMap(), val body: ByteArray = byteArrayOf(), val stream: InputStream? = null)
    private class Connection(url: URL, val respond: (Connection) -> Response) : HttpURLConnection(url) {
        var disconnected = false
        val sent = ByteArrayOutputStream()
        private val response by lazy { respond(this) }
        override fun setRequestMethod(value: String) { method = value }
        override fun getOutputStream() = sent
        override fun getInputStream(): InputStream = response.stream ?: ByteArrayInputStream(response.body)
        override fun getErrorStream(): InputStream = ByteArrayInputStream(response.body)
        override fun getResponseCode() = response.status
        override fun getHeaderField(name: String): String? = response.headers.entries.firstOrNull { it.key.equals(name, true) }?.value
        override fun getHeaderFields(): Map<String, List<String>> = response.headers.mapValues { listOf(it.value) }
        override fun disconnect() { disconnected = true }
        override fun usingProxy() = false
        override fun connect() {}
    }
    private class Transport(val respond: (Connection) -> Response) {
        val connections = mutableListOf<Connection>()
        fun client(cancel: () -> Unit = {}): ServerApiClient = ServerApiClient(ServerSettings("https://network.test", "fixture", "fixture", false),
            chunkBytes = 1024 * 1024, connectionFactory = { url -> Connection(url, respond).also { connections.add(it) } }, checkCancelled = cancel)
        fun assertReleased() = assertTrue("Every connection must be disconnected, including failed ones", connections.all { it.disconnected })
    }
    private fun fixture(run: (File, File) -> Unit) {
        val directory = Files.createTempDirectory("woona-network-test").toFile()
        val source = File(directory, "source.bin").apply { writeText("abcdef") }
        try { run(directory, source) } finally { directory.deleteRecursively() }
    }
    private fun hash(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    private fun assertCode(code: String, action: () -> Unit) {
        val failure = assertThrows(ServerTransferException::class.java, action)
        assertEquals(code, failure.code)
    }
    @Test fun transferFailureDescriptionsDistinguishServerRepairRetryAndPreservedLocalConflict() {
        val ru = com.example.myapplication.localization.AppLanguage.RUSSIAN
        val describe = { code: String -> com.example.myapplication.localization.recordingUploadErrorText("$code: fixture details", ru) }
        assertTrue(describe("upload_offset_invalid").contains("Проверьте сервер"))
        assertTrue(describe("upload_conflict_stalled").contains("повтор продолжит"))
        assertTrue(describe("local_artifact_conflict").contains("не перезаписан"))
        assertTrue(describe("orphaned_upload_recovered").contains("Очередь восстановлена"))
    }

    @Test fun repeatedOrMalformedRestoreCursorsCannotLoopForeverOrInjectQueryParameters() {
        val guard = TransferCursorGuard()
        val cursor = "00000000-0000-0000-0000-000000000001"
        assertEquals(cursor, guard.next(cursor))
        assertNull(guard.next(null))
        assertCode("pagination_stalled") { guard.next(cursor) }
        assertCode("pagination_cursor_invalid") { TransferCursorGuard().next("bad&limit=1000000") }
    }
    @Test fun headRejectsNegativeOversizedMissingAndOverflowOffsetsWithoutPatch() = fixture { _, file ->
        for (header in listOf<String?>("-1", "7", null, "9999999999999999999999999999")) {
            val transport = Transport { Response(headers = header?.let { mapOf("Upload-Offset" to it) } ?: emptyMap()) }
            assertThrows(ServerTransferException::class.java) { transport.client().uploadArtifactBytes("a", 6, file) }
            assertEquals(1, transport.connections.size)
            assertEquals("HEAD", transport.connections.single().requestMethod)
            transport.assertReleased()
        }
    }
    @Test fun successfulPatchMustAcknowledgeExactlySentBytes() = fixture { _, file ->
        for (header in listOf<String?>("-1", "0", "2", "7", null, "overflow")) {
            val progress = mutableListOf<Long>()
            val transport = Transport { connection -> Response(headers = if (connection.requestMethod == "HEAD") mapOf("Upload-Offset" to "0") else header?.let { mapOf("Upload-Offset" to it) } ?: emptyMap()) }
            assertThrows(ServerTransferException::class.java) { transport.client().uploadArtifactBytes("a", 6, file, progress::add) }
            assertEquals(listOf(0L), progress)
            assertEquals(2, transport.connections.size)
            transport.assertReleased()
        }
    }
    @Test fun conflictWithUnchangedHeadIsBoundedAndRetryable() = fixture { _, file ->
        val transport = Transport { connection -> if (connection.requestMethod == "HEAD") Response(headers = mapOf("Upload-Offset" to "0")) else Response(409) }
        val failure = assertThrows(ServerTransferException::class.java) { transport.client().uploadArtifactBytes("a", 6, file) }
        assertEquals("upload_conflict_stalled", failure.code)
        assertTrue(failure.retryable)
        assertEquals(4, transport.connections.count { it.requestMethod == "PATCH" })
        transport.assertReleased()
    }
    @Test fun conflictRecoveryReseeksFileInsteadOfSkippingOrDuplicatingBytes() = fixture { _, file ->
        var heads = 0
        var patches = 0
        val transport = Transport { connection ->
            if (connection.requestMethod == "HEAD") Response(headers = mapOf("Upload-Offset" to if (++heads == 1) "4" else "1"))
            else if (++patches == 1) { assertEquals("ef", connection.sent.toString("UTF-8")); Response(409) }
            else { assertEquals("1", connection.getRequestProperty("Upload-Offset")); assertEquals("bcdef", connection.sent.toString("UTF-8")); Response(204, mapOf("Upload-Offset" to "6")) }
        }
        transport.client().uploadArtifactBytes("a", 6, file)
        assertEquals(2, patches)
        transport.assertReleased()
    }
    @Test fun resumedUploadSendsOnlyRemainingBytesAndPreservesOriginal() = fixture { _, file ->
        val transport = Transport { connection ->
            if (connection.requestMethod == "HEAD") Response(headers = mapOf("Upload-Offset" to "3"))
            else { assertEquals("def", connection.sent.toString("UTF-8")); Response(204, mapOf("Upload-Offset" to "6")) }
        }
        val progress = mutableListOf<Long>()
        transport.client().uploadArtifactBytes("a", 6, file, progress::add)
        assertEquals(listOf(3L, 6L), progress)
        assertEquals("abcdef", file.readText())
        transport.assertReleased()
    }
    @Test fun timeoutAndCancellationReleaseConnectionWithoutPretendingSuccess() = fixture { _, file ->
        val timeout = Transport { throw SocketTimeoutException("fixture read timeout") }
        assertThrows(SocketTimeoutException::class.java) { timeout.client().uploadArtifactBytes("a", 6, file) }
        timeout.assertReleased()
        var checks = 0
        val cancel = Transport { Response(headers = mapOf("Upload-Offset" to "0")) }
        assertThrows(CancellationException::class.java) { cancel.client { if (++checks >= 4) throw CancellationException("paused") }.uploadArtifactBytes("a", 6, file) }
        cancel.assertReleased()
        assertEquals("abcdef", file.readText())
    }
    @Test fun alreadyCompletePartialIsVerifiedAndFinalizedWithoutNetwork() = fixture { base, file ->
        val target = File(base, "target.bin")
        File(base, "target.bin.download.part").writeBytes(file.readBytes())
        val transport = Transport { error("Complete partial must not make a request") }
        transport.client().downloadArtifact("a", 6, hash(file.readBytes()), target)
        assertEquals("abcdef", target.readText())
        assertTrue(transport.connections.isEmpty())
    }
    @Test fun validResumeChecksFullRangeHashAndIdentityEncoding() = fixture { base, file ->
        val target = File(base, "target.bin")
        File(base, "target.bin.download.part").writeText("ab")
        val expectedHash = hash(file.readBytes())
        val transport = Transport { connection ->
            assertEquals("bytes=2-", connection.getRequestProperty("Range"))
            assertEquals("identity", connection.getRequestProperty("Accept-Encoding"))
            assertEquals("\"$expectedHash\"", connection.getRequestProperty("If-Range"))
            Response(206, mapOf("Content-Range" to "bytes 2-5/6", "Content-Length" to "4", "ETag" to "\"$expectedHash\""), "cdef".toByteArray())
        }
        transport.client().downloadArtifact("a", 6, expectedHash, target)
        assertEquals("abcdef", target.readText())
        transport.assertReleased()
    }
    @Test fun ignoredRangeRestartsFromSameResponseWithoutRecursionOrConcatenation() = fixture { base, file ->
        val target = File(base, "target.bin")
        File(base, "target.bin.download.part").writeText("ab")
        val transport = Transport { Response(200, mapOf("Content-Length" to "6"), file.readBytes()) }
        transport.client().downloadArtifact("a", 6, hash(file.readBytes()), target)
        assertEquals("abcdef", target.readText())
        assertEquals(1, transport.connections.size)
        transport.assertReleased()
    }
    @Test fun invalidRangesEtagsAndCompressedResponsesPreservePrefix() = fixture { base, file ->
        for (headers in listOf(mapOf("Content-Range" to "bytes 1-4/6"), mapOf("Content-Range" to "bytes 2-5/7"), emptyMap(),
            mapOf("Content-Range" to "bytes 2-5/6", "ETag" to "different"), mapOf("Content-Range" to "bytes 2-5/6", "Content-Encoding" to "gzip"),
            mapOf("Content-Range" to "bytes 2-5/6", "Content-Length" to "5"))) {
            val target = File(base, "target.bin")
            val partial = File(base, "target.bin.download.part").apply { writeText("ab") }
            val transport = Transport { Response(206, headers, "cdef".toByteArray()) }
            assertThrows(ServerTransferException::class.java) { transport.client().downloadArtifact("a", 6, hash(file.readBytes()), target) }
            assertEquals("ab", partial.readText())
            assertFalse(target.exists())
            transport.assertReleased()
        }
    }
    @Test fun earlyEofPreservesReceivedPrefixAndTimeoutAlsoReleasesConnection() = fixture { base, file ->
        val target = File(base, "target.bin")
        val partial = File(base, "target.bin.download.part")
        val short = Transport { Response(body = "abc".toByteArray()) }
        assertCode("download_incomplete") { short.client().downloadArtifact("a", 6, hash(file.readBytes()), target) }
        assertEquals("abc", partial.readText())
        assertFalse(target.exists())
        short.assertReleased()
        val broken = object : InputStream() { override fun read(): Int = throw SocketTimeoutException("fixture") }
        val timeout = Transport { Response(206, mapOf("Content-Range" to "bytes 3-5/6"), stream = broken) }
        assertThrows(SocketTimeoutException::class.java) { timeout.client().downloadArtifact("a", 6, hash(file.readBytes()), target) }
        assertEquals("abc", partial.readText())
        timeout.assertReleased()
    }
    @Test fun hashMismatchAndOversizedBodyNeverPublishBadFiles() = fixture { base, file ->
        val target = File(base, "target.bin")
        val hashMismatch = Transport { Response(body = "abcdeg".toByteArray()) }
        assertCode("download_hash_mismatch") { hashMismatch.client().downloadArtifact("a", 6, hash(file.readBytes()), target) }
        assertFalse(target.exists())
        assertFalse(File(base, "target.bin.download.part").exists())
        hashMismatch.assertReleased()
        val oversized = Transport { Response(body = "abcdefg".toByteArray()) }
        assertCode("download_size_invalid") { oversized.client().downloadArtifact("a", 6, hash(file.readBytes()), target) }
        assertFalse(target.exists())
        assertFalse(File(base, "target.bin.download.part").exists())
        oversized.assertReleased()
    }
    @Test fun existingDifferentTargetIsNeverOverwrittenAndMatchingTargetNeedsNoNetwork() = fixture { _, file ->
        val transport = Transport { error("Existing target must not contact network") }
        assertCode("local_artifact_conflict") { transport.client().downloadArtifact("a", 6, hash("other!".toByteArray()), file) }
        assertEquals("abcdef", file.readText())
        transport.client().downloadArtifact("a", 6, hash(file.readBytes()), file)
        assertTrue(transport.connections.isEmpty())
    }
}
