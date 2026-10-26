package com.example.myapplication.sync

import android.content.Context
import android.util.Log
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.example.myapplication.data.WoonaDatabase
import com.example.myapplication.data.restoreServerMetadata
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

@RunWith(AndroidJUnit4::class)
class ServerConnectionDiagnosticTest {
    @Test
    fun readProductionMetadata() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val tokenFile = File(context.cacheDir, "connection-test.token")
        assumeTrue("Live credential was not supplied", tokenFile.isFile)
        try {
            val account = InstrumentationRegistry.getArguments().getString("serverAccount")
            assumeTrue("Supply the intended read-only serverAccount explicitly", !account.isNullOrBlank())
            val accountId = com.example.myapplication.data.normalizeAccountId(requireNotNull(account))
            val token = tokenFile.readText().trim()
            require(token.isNotEmpty() && !token.contains('\n') && !token.contains('\r')) { "Diagnostic token must be a nonempty single line" }
            // Remove disk credentials before networking, including timeout/crash paths.
            check(tokenFile.delete()) { "Cannot remove the temporary diagnostic credential" }
            val client = ServerApiClient(ServerSettings("https://cool-trams.digital", token, "diagnostic", false, accountId))
            val started = System.nanoTime()
            assertTrue(client.readiness())
            val snapshot = client.fetchRestoreSnapshot()
            val root = File(context.cacheDir, "connection-test-db-${System.nanoTime()}")
            val database = WoonaDatabase(context, root)
            try {
                val restored = database.restoreServerMetadata(snapshot.dogs, snapshot.recordings)
                assertEquals(snapshot.dogs.size, restored.dogs)
                assertEquals(snapshot.recordings.size, restored.recordings)
                val repeated = database.restoreServerMetadata(snapshot.dogs, snapshot.recordings)
                assertEquals(0, repeated.dogs)
                assertEquals(0, repeated.recordings)
                val artifacts = snapshot.recordings.flatMap { it.artifacts }.filter { it.storageStatus == "available" }
                artifacts.filter { it.sizeBytes <= 5 * 1024 * 1024 }.groupBy { it.type }.forEach { (type, candidates) ->
                    val artifact = candidates.minBy { it.sizeBytes }
                    val target = File(root, "live-${artifact.id}-${artifact.fileName}")
                    client.downloadArtifact(artifact.id, artifact.sizeBytes, artifact.sha256, target)
                    assertEquals(artifact.sizeBytes, target.length())
                    Log.i("WOONA_CONNECTION_TEST", "downloadType=$type bytes=${target.length()} shaVerified=true")
                    target.delete()
                }
                artifacts.filter { it.type == "video" && it.sizeBytes > 0 }.minByOrNull { it.sizeBytes }?.let { video ->
                    val connection = URL("https://cool-trams.digital/v1/artifacts/${video.id}/content").openConnection() as HttpURLConnection
                    try {
                        connection.connectTimeout = 15_000
                        connection.readTimeout = 30_000
                        connection.instanceFollowRedirects = false
                        connection.setRequestProperty("Authorization", "Bearer $token")
                        connection.setRequestProperty("X-Woona-Account", accountId)
                        connection.setRequestProperty("Accept-Encoding", "identity")
                        val rangeBytes = minOf(65536L, video.sizeBytes)
                        connection.setRequestProperty("Range", "bytes=0-${rangeBytes - 1}")
                        connection.setRequestProperty("If-Range", "\"${video.sha256}\"")
                        assertEquals(206, connection.responseCode)
                        assertEquals("bytes 0-${rangeBytes - 1}/${video.sizeBytes}", connection.getHeaderField("Content-Range"))
                        // Read one extra byte to detect oversized responses without unbounded allocation.
                        val received = connection.inputStream.use { input ->
                            val buffer = ByteArray((rangeBytes + 1).toInt())
                            var count = 0
                            while (count < buffer.size) {
                                val next = input.read(buffer, count, buffer.size - count)
                                if (next < 0) break
                                count += next
                            }
                            count
                        }
                        assertEquals(rangeBytes, received.toLong())
                        assertEquals(video.sha256, connection.getHeaderField("ETag").trim('"'))
                        Log.i("WOONA_CONNECTION_TEST", "videoRangeBytes=$received etagVerified=true")
                    } finally {
                        connection.disconnect()
                    }
                }
                Log.i("WOONA_CONNECTION_TEST", "dogs=${restored.dogs} recordings=${restored.recordings} artifacts=${restored.artifacts} elapsedMs=${(System.nanoTime() - started) / 1_000_000}")
            } finally {
                database.close()
                root.deleteRecursively()
            }
        } finally {
            // Also covers malformed/missing account arguments, parse and setup failures.
            if (tokenFile.exists()) check(tokenFile.delete()) { "Temporary diagnostic credential was not removed" }
        }
    }
}
