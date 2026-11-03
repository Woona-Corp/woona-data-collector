package com.example.myapplication.feature.device

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import android.content.Context
import com.example.myapplication.storage.BleDiagnosticLogFileStore
import com.example.myapplication.storage.BlePacketFileStore
import com.example.myapplication.storage.BleRawFragmentFileStore
import java.io.DataInputStream
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class PacketRecoveryDeviceTest {
    @Test fun admittedFragmentsAreSyncedToRecoveryArtifactAfterWriteFailure() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val root = File(context.cacheDir, "packet-recovery-test-${UUID.randomUUID()}").apply { mkdirs() }
        val invalidDirectory = File(root, "not-a-directory").apply { writeText("fixture") }
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val failure = CountDownLatch(1)
        val processor = PacketCaptureProcessor(
            packetFileStore = BlePacketFileStore(root),
            rawFragmentFileStore = BleRawFragmentFileStore(invalidDirectory, timestampProvider = {
                entered.countDown(); release.await(5, TimeUnit.SECONDS); 1L
            }),
            diagnosticLogFileStore = BleDiagnosticLogFileStore(root),
            onPacketProcessed = {},
            onError = { _, _ -> failure.countDown() },
            maxPendingFragments = 4,
        )
        try {
            assertEquals(PacketSubmitResult.ACCEPTED, processor.submit(byteArrayOf(1, 2), 10L, 100L))
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            assertEquals(PacketSubmitResult.ACCEPTED, processor.submit(byteArrayOf(3, 4, 5), 20L, 200L))
            release.countDown()
            assertTrue(failure.await(5, TimeUnit.SECONDS))
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            var result: PacketRecoveryResult = PacketRecoveryResult.Busy
            while (result == PacketRecoveryResult.Busy && System.nanoTime() < deadline) {
                result = processor.recoverPendingFragments(root)
                if (result == PacketRecoveryResult.Busy) Thread.sleep(10)
            }
            assertTrue("Recovery file could not be durably published on Android", result is PacketRecoveryResult.Recovered)
            val saved = (result as PacketRecoveryResult.Recovered).file
            DataInputStream(saved.inputStream()).use { input ->
                val magic = ByteArray(8).also(input::readFully)
                assertArrayEquals(byteArrayOf(87, 80, 82, 69, 67, 79, 86, 0), magic)
                assertEquals(1, input.readInt())
                assertEquals(2, input.readInt())
                assertEquals(10L, input.readLong()); assertEquals(100L, input.readLong())
                assertArrayEquals(byteArrayOf(1, 2), ByteArray(input.readInt()).also(input::readFully))
                assertEquals(20L, input.readLong()); assertEquals(200L, input.readLong())
                assertArrayEquals(byteArrayOf(3, 4, 5), ByteArray(input.readInt()).also(input::readFully))
                assertEquals(-1, input.read())
            }
            assertEquals(saved, (processor.recoverPendingFragments(root) as PacketRecoveryResult.Recovered).file)
        } finally {
            release.countDown()
            processor.close()
            root.deleteRecursively()
        }
    }
}
