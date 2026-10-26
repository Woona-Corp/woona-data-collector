package com.example.myapplication.sync

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.net.HttpURLConnection
import java.net.URL

class ServerBaseUrlTest {
    @Test fun acceptsHttpsAndOnlyExactLocalHttpHostsPreservingBasePaths() {
        for (input in listOf("https://example.test", "HTTPS://Example.test:8443/api/root", "https://[2001:db8::1]:8443/api%20root",
                             "http://10.0.2.2:8080", "http://localhost:18088", "http://127.0.0.1:18088", "http://[::1]:18088")) {
            assertEquals(input, normalizedServerBaseUrl(" $input///\n"))
        }
    }

    @Test fun rejectsAmbiguousMissingHostCredentialsQueriesFragmentsPortsAndHttpLookalikes() {
        for (input in listOf("", "https://", "https:///v1", "https:example.test", "example.test", "ftp://example.test",
                             "https://user:secret@example.test", "https://@example.test", "https://example.test?x=1", "https://example.test?",
                             "https://example.test#fragment", "https://example.test#", "https://example.test:", "https://example.test:0",
                             "https://example.test:65536", "https://example.test:abc", "https://bad host", "https://bad_host",
                             "https://999.999.999.999", "https://[bad::g]", "https://example.test/has space", "https://example.test/\\escape",
                             "http://example.test", "http://10.0.2.2.evil", "http://10.0.2.20", "http://127.0.0.2", "http://localhost.evil")) {
            val error = assertThrows("Must reject $input", IllegalArgumentException::class.java) { normalizedServerBaseUrl(input) }
            assertTrue(error.message.orEmpty().contains("HTTPS"))
            assertFalse(error.message.orEmpty().contains("secret"))
        }
    }

    @Test fun configuredBasePrefixIsUsedByActualConnectionRequests() {
        val urls = mutableListOf<URL>()
        val client = ServerApiClient(ServerSettings(normalizedServerBaseUrl("https://network.test/api/root///"), "fixture", "fixture", false),
            connectionFactory = { url ->
                urls.add(url)
                object : HttpURLConnection(url) {
                    override fun setRequestMethod(value: String) { method = value }
                    override fun getResponseCode() = 200
                    override fun getInputStream() = ByteArrayInputStream("{}".toByteArray())
                    override fun connect() {}
                    override fun disconnect() {}
                    override fun usingProxy() = false
                }
            })
        client.checkConnection()
        assertEquals(listOf("/api/root/health/ready", "/api/root/v1/dogs"), urls.map { it.path })
        assertEquals("limit=1", urls.last().query)
    }
}
