package com.example.myapplication.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID

class ServerRequestIdTest {
    private class Connection(
        url: URL,
        private val status: Int,
        private val headers: Map<String, String>,
        private val body: String = """{"code":"server_busy"}""",
    ) : HttpURLConnection(url) {
        val requestHeaders = mutableMapOf<String, String>()

        override fun setRequestMethod(value: String) {
            method = value
        }

        override fun setRequestProperty(key: String, value: String) {
            requestHeaders[key] = value
        }

        override fun getOutputStream() = throw IOException("unexpected write")

        override fun getInputStream(): InputStream = ByteArrayInputStream(ByteArray(0))

        override fun getErrorStream(): InputStream = ByteArrayInputStream(body.toByteArray())

        override fun getResponseCode() = status

        override fun getHeaderField(name: String): String? =
            headers.entries.firstOrNull { it.key.equals(name, ignoreCase = true) }?.value

        override fun getHeaderFields(): Map<String, List<String>>? = headers.mapValues { listOf(it.value) }

        override fun usingProxy() = false

        override fun connect() {}

        override fun disconnect() {}
    }

    private fun failure(status: Int = 503, headers: Map<String, String> = emptyMap()): Pair<ServerHttpException, Connection> {
        lateinit var connection: Connection
        val client = ServerApiClient(
            ServerSettings("https://network.test", "fixture", "fixture", false),
            connectionFactory = { url -> Connection(url, status, headers).also { connection = it } },
        )
        val error = assertThrows(ServerHttpException::class.java) { client.fetchDeletions() }
        return error to connection
    }

    @Test fun httpErrorIsSanitizedBeforeWorkerCanPersistItAndCodeRemainsJson() {
        val token = "sentinel-configured-token"
        val body = """{"detail":{"code":"animal_id_already_exists","message":"reflected $token https://host.test/path?X-Amz-Credential=sentinel-signed&unknown=sentinel-unknown#sentinel-fragment","requestId":"req-fixture","apiKey":"sentinel-api"}}"""
        val client = ServerApiClient(
            ServerSettings("https://network.test", token, "fixture", false),
            connectionFactory = { url -> Connection(url, 409, mapOf("X-Request-ID" to "req-fixture"), body) },
        )
        val error = assertThrows(ServerHttpException::class.java) { client.fetchDeletions() }
        assertEquals(409, error.status)
        assertEquals("req-fixture", error.requestId)
        assertFalse(error.message.orEmpty().contains("sentinel"))
        assertFalse(error.responseBody.contains("sentinel"))
        // Android's JSONObject is a JVM stub here. Exact valid JSON proves code and
        // string delimiters survived; native persistence tests exercise the parser.
        assertEquals("""{"detail":{"code":"animal_id_already_exists","message":"reflected [redacted] https://host.test/path[redacted]","requestId":"req-fixture","apiKey":"[redacted]"}}""", error.responseBody)
        assertTrue(error.responseBody.contains("host.test/path"))
        assertTrue(error.message.orEmpty().contains("req-fixture"))
    }

    @Test
    fun everyRequestCarriesACorrelatableRequestId() {
        val (_, connection) = failure()
        val sent = requireNotNull(connection.requestHeaders["X-Request-ID"])
        assertTrue("Every request must send X-Request-ID", sent.isNotBlank())
        assertEquals("The header must stay a plain UUID", sent.lowercase(), UUID.fromString(sent).toString())
    }

    @Test
    fun serverEchoedRequestIdIsExposedAndKeptInTheMessage() {
        val (error, _) = failure(headers = mapOf("X-Request-ID" to "server-request-123"))
        assertEquals(503, error.status)
        assertEquals("server-request-123", error.requestId)
        assertTrue(error.message.orEmpty().contains("(requestId=server-request-123)"))
    }

    @Test
    fun missingRequestIdLeavesTheMessageUnchanged() {
        val (error, _) = failure()
        assertNull(error.requestId)
        assertFalse(error.message.orEmpty().contains("requestId="))
    }

    @Test
    fun untrustedRequestIdIsBounded() {
        val oversized = "x".repeat(200)
        val (error, _) = failure(headers = mapOf("X-Request-ID" to oversized))
        assertEquals(64, error.requestId?.length)
    }
}
