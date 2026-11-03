package com.example.myapplication.feature.device

import com.example.myapplication.protocol.RecordedPacketFileParser
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.io.InputStream
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class PacketReplayControllerTest {
    @Test
    fun stoppedReplayReportsWorkerUntilInFlightSubmissionExits() {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val controller = createController(submitFragment = {
            entered.countDown()
            // Simulate a source/submit already in progress that does not stop
            // immediately when its thread is interrupted.
            var done = false
            while (!done) {
                try { done = release.await(5, TimeUnit.SECONDS) }
                catch (_: InterruptedException) { }
            }
            PacketSubmitResult.OVERFLOW
        })
        try {
            controller.startReplay(validPacket())
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            controller.stop()
            assertTrue("A stopped worker can still be inside submit", controller.hasPendingWork())
            release.countDown()
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            while (controller.hasPendingWork() && System.nanoTime() < deadline) Thread.yield()
            assertFalse("Worker should be retired after it exits", controller.hasPendingWork())
        } finally { release.countDown(); controller.close() }
    }

    @Test
    fun stoppedReplayWaitsForLifecycleCallbackEvenAfterWorkerExits() {
        val started = CountDownLatch(1)
        val release = CountDownLatch(1)
        val worker = java.util.concurrent.atomic.AtomicReference<Thread>()
        val controller = createController(
            onReplayStarted = { started.countDown(); release.await(5, TimeUnit.SECONDS) },
            callbackDispatcher = { callback ->
                Thread(callback, "replay-lifecycle-test").apply { isDaemon = true; start() }
                true
            },
        )
        try {
            controller.startReplay { worker.set(Thread.currentThread()); validPacket().inputStream() }
            assertTrue(started.await(2, TimeUnit.SECONDS))
            controller.stop()
            requireNotNull(worker.get()).join(2_000)
            assertFalse("Replay worker should have exited", worker.get().isAlive)
            assertTrue("An already-running lifecycle callback must remain in the barrier", controller.hasPendingWork())
            release.countDown()
            eventually { !controller.hasPendingWork() }
        } finally { release.countDown(); controller.close() }
    }

    @Test
    fun startReplay_invalidFileFailsDuringPreparationWithoutSubmitting() {
        val errorLatch = CountDownLatch(1)
        val stoppedLatch = CountDownLatch(1)
        val errors = mutableListOf<String>()
        var preparing = false
        var started = false
        var submitted = false
        val controller = createController(
            submitFragment = {
                submitted = true
                PacketSubmitResult.ACCEPTED
            },
            onReplayPreparing = { preparing = true },
            onReplayStarted = { started = true },
            onReplayStopped = { stoppedLatch.countDown() },
            onError = { message, _ ->
                errors += message
                errorLatch.countDown()
            },
        )

        controller.startReplay(byteArrayOf(0x01, 0x02, 0x03))

        assertTrue(errorLatch.await(1, TimeUnit.SECONDS))
        assertTrue(stoppedLatch.await(1, TimeUnit.SECONDS))
        assertEquals(listOf("Replay file is not a valid packet dump"), errors)
        assertTrue(preparing)
        assertFalse(started)
        assertFalse(submitted)
    }

    @Test
    fun startReplay_corruptTailDoesNotSubmitValidatedPrefix() {
        val errorLatch = CountDownLatch(1)
        val stoppedLatch = CountDownLatch(1)
        val submittedFragments = mutableListOf<ByteArray>()
        var started = false
        val controller = createController(
            submitFragment = {
                submittedFragments += it
                PacketSubmitResult.ACCEPTED
            },
            onReplayStarted = { started = true },
            onReplayStopped = { stoppedLatch.countDown() },
            onError = { _, _ -> errorLatch.countDown() },
        )

        controller.startReplay(validPacket() + byteArrayOf(0x01, 0x02, 0x03))

        assertTrue(errorLatch.await(1, TimeUnit.SECONDS))
        assertTrue(stoppedLatch.await(1, TimeUnit.SECONDS))
        assertFalse(started)
        assertTrue(submittedFragments.isEmpty())
    }

    @Test
    fun startReplay_replaysValidatedPacketDump() {
        val submittedFragments = mutableListOf<ByteArray>()
        val completedLatch = CountDownLatch(1)
        val packet = validPacket()
        val controller = createController(
            submitFragment = {
                submittedFragments += it
                PacketSubmitResult.ACCEPTED
            },
            onReplayCompleted = { completedLatch.countDown() },
        )

        controller.startReplay(packet)

        assertTrue(completedLatch.await(1, TimeUnit.SECONDS))
        assertEquals(1, submittedFragments.size)
        assertArrayEquals(packet, submittedFragments.single())
    }

    @Test
    fun startReplay_opensSourceOnWorkerBetweenPreparingAndStartedCallbacks() {
        val events = mutableListOf<String>()
        val completedLatch = CountDownLatch(1)
        val controller = createController(
            onReplayPreparing = { events += "preparing:${Thread.currentThread().name}" },
            onReplayStarted = { events += "started:${Thread.currentThread().name}" },
            onReplayCompleted = { completedLatch.countDown() },
        )

        controller.startReplay {
            events += "opened:${Thread.currentThread().name}"
            validPacket().inputStream()
        }

        assertTrue(completedLatch.await(1, TimeUnit.SECONDS))
        val preparingIndex = events.indexOfFirst { it.startsWith("preparing:") }
        val openedIndex = events.indexOfFirst { it.startsWith("opened:") }
        val startedIndex = events.indexOfFirst { it.startsWith("started:") }
        assertTrue(preparingIndex >= 0)
        assertTrue(openedIndex > preparingIndex)
        assertTrue(startedIndex > openedIndex)
        assertTrue(events[openedIndex].contains("debug-packet-replay"))
    }

    @Test
    fun stop_cancelsBlockedSourceAcquisitionWithoutWaiting() {
        val source = CancellationAwareBlockingSource()
        val stopReturned = CountDownLatch(1)
        val stoppedLatch = CountDownLatch(1)
        val controller = createController(onReplayStopped = { stoppedLatch.countDown() })

        controller.startReplay(source)
        assertTrue(source.openStarted.await(1, TimeUnit.SECONDS))

        Thread {
            controller.stop()
            stopReturned.countDown()
        }.start()

        assertTrue(stopReturned.await(1, TimeUnit.SECONDS))
        assertTrue(source.cancelled.await(1, TimeUnit.SECONDS))
        assertTrue(stoppedLatch.await(1, TimeUnit.SECONDS))
    }

    @Test
    fun stop_fallsBackToSynchronousCancellationWhenDispatchFails() {
        val inputStream = CloseAwareBlockingInputStream()
        val tokenCancelled = CountDownLatch(1)
        val controller = createController(
            cancellationDispatcher = { throw IllegalStateException("dispatcher unavailable") },
        )
        controller.startReplay { cancellationToken ->
            cancellationToken.invokeOnCancellation { tokenCancelled.countDown() }
            inputStream
        }
        assertTrue(inputStream.readStarted.await(1, TimeUnit.SECONDS))

        controller.stop()

        assertTrue(tokenCancelled.await(1, TimeUnit.SECONDS))
        assertTrue(inputStream.closed.await(1, TimeUnit.SECONDS))
    }

    @Test
    fun startReplay_opensPreparedStreamBeforeStartedCallback() {
        val errorLatch = CountDownLatch(1)
        val stoppedLatch = CountDownLatch(1)
        var started = false
        val controller = createController(
            onReplayStarted = { started = true },
            onReplayStopped = { stoppedLatch.countDown() },
            onError = { _, _ -> errorLatch.countDown() },
            preparedInputStreamFactory = { throw IOException("cache open failed") },
        )

        controller.startReplay(validPacket())

        assertTrue(errorLatch.await(1, TimeUnit.SECONDS))
        assertTrue(stoppedLatch.await(1, TimeUnit.SECONDS))
        assertFalse(started)
    }

    @Test
    fun startReplay_waitsForLifecycleCallbacksBeforeAdvancing() {
        val callbacks = LinkedBlockingQueue<() -> Unit>()
        val sourceOpened = CountDownLatch(1)
        val completedLatch = CountDownLatch(1)
        val submittedFragments = mutableListOf<ByteArray>()
        val controller = createController(
            submitFragment = {
                submittedFragments += it
                PacketSubmitResult.ACCEPTED
            },
            onReplayCompleted = { completedLatch.countDown() },
            callbackDispatcher = { callback ->
                callbacks.put(callback)
                true
            },
        )

        controller.startReplay {
            sourceOpened.countDown()
            validPacket().inputStream()
        }

        val preparingCallback = callbacks.poll(1, TimeUnit.SECONDS)
        assertFalse(sourceOpened.await(50, TimeUnit.MILLISECONDS))
        requireNotNull(preparingCallback).invoke()
        assertTrue(sourceOpened.await(1, TimeUnit.SECONDS))

        val startedCallback = callbacks.poll(1, TimeUnit.SECONDS)
        assertTrue(submittedFragments.isEmpty())
        requireNotNull(startedCallback).invoke()

        assertTrue(completedLatch.await(1, TimeUnit.SECONDS))
        assertEquals(1, submittedFragments.size)
    }

    @Test
    fun rapidReplacement_waitsForEveryCancelledPredecessorBeforeSubmitting() {
        val firstSubmissionStarted = CountDownLatch(1)
        val releaseFirstSubmission = CountDownLatch(1)
        val replacementCompleted = CountDownLatch(1)
        val submissionCount = AtomicInteger(0)
        val controller = createController(
            submitFragment = {
                if (submissionCount.incrementAndGet() == 1) {
                    firstSubmissionStarted.countDown()
                    while (releaseFirstSubmission.count > 0) {
                        try {
                            releaseFirstSubmission.await()
                        } catch (_: InterruptedException) {
                            // Keep the oldest submission in flight across both replacements.
                        }
                    }
                }
                PacketSubmitResult.ACCEPTED
            },
            onReplayCompleted = { replacementCompleted.countDown() },
        )

        controller.startReplay(validPacket())
        assertTrue(firstSubmissionStarted.await(1, TimeUnit.SECONDS))

        controller.startReplay(validPacket())
        controller.startReplay(validPacket())

        try {
            Thread.sleep(100L)
            assertEquals(1, submissionCount.get())
        } finally {
            releaseFirstSubmission.countDown()
        }
        assertTrue(replacementCompleted.await(1, TimeUnit.SECONDS))
        assertEquals(2, submissionCount.get())
    }

    @Test
    fun startReplay_deletesTemporaryFileAfterSuccessAndValidationFailure() {
        val successFile = Files.createTempFile("replay-success", ".bin").toFile()
        val successCompleted = CountDownLatch(1)
        val successController = createController(
            onReplayCompleted = { successCompleted.countDown() },
            replayTempFileFactory = { successFile },
        )

        successController.startReplay(validPacket())

        assertTrue(successCompleted.await(1, TimeUnit.SECONDS))
        eventually { !successFile.exists() }

        val failureFile = Files.createTempFile("replay-failure", ".bin").toFile()
        val failureReported = CountDownLatch(1)
        val failureController = createController(
            onError = { _, _ -> failureReported.countDown() },
            replayTempFileFactory = { failureFile },
        )

        failureController.startReplay(validPacket() + byteArrayOf(0x01))

        assertTrue(failureReported.await(1, TimeUnit.SECONDS))
        eventually { !failureFile.exists() }
    }

    private fun createController(
        submitFragment: (ByteArray) -> PacketSubmitResult = { PacketSubmitResult.ACCEPTED },
        onReplayPreparing: () -> Unit = {},
        onReplayStarted: () -> Unit = {},
        onReplayCompleted: () -> Unit = {},
        onReplayStopped: () -> Unit = {},
        onError: (String, Throwable?) -> Unit = { message, throwable ->
            throw AssertionError(message, throwable)
        },
        callbackDispatcher: ((() -> Unit) -> Boolean) = { callback ->
            callback()
            true
        },
        cancellationDispatcher: ((() -> Unit) -> Unit) = { action ->
            Thread(action, "test-replay-cancel").apply {
                isDaemon = true
                start()
            }
        },
        replayTempFileFactory: () -> java.io.File = {
            Files.createTempFile("replay-controller", ".bin").toFile()
        },
        preparedInputStreamFactory: (java.io.File) -> InputStream = { file -> file.inputStream() },
    ): DebugPacketReplayController {
        return DebugPacketReplayController(
            submitFragment = submitFragment,
            onReplayPreparing = onReplayPreparing,
            onReplayStarted = onReplayStarted,
            onReplayCompleted = onReplayCompleted,
            onReplayStopped = onReplayStopped,
            onError = onError,
            packetFileParser = RecordedPacketFileParser(),
            packetIntervalMs = 1L,
            callbackDispatcher = callbackDispatcher,
            cancellationDispatcher = cancellationDispatcher,
            replayTempFileFactory = replayTempFileFactory,
            preparedInputStreamFactory = preparedInputStreamFactory,
        )
    }

    private fun eventually(condition: () -> Boolean) {
        repeat(100) {
            if (condition()) return
            Thread.sleep(10L)
        }
        assertTrue(condition())
    }

    private fun validPacket(): ByteArray {
        val length = 16
        return ByteArray(length).apply {
            this[0] = 0x33
            this[1] = 0x99.toByte()
            this[2] = 0xAA.toByte()
            this[3] = 0x55
            this[4] = (length and 0xFF).toByte()
            this[5] = ((length shr 8) and 0xFF).toByte()
            this[6] = 1
        }
    }
}

private class CloseAwareBlockingInputStream : InputStream() {
    val readStarted = CountDownLatch(1)
    val closed = CountDownLatch(1)

    override fun read(): Int {
        readStarted.countDown()
        while (closed.count > 0) {
            try {
                closed.await()
            } catch (_: InterruptedException) {
                // Stream closure, rather than interruption, releases this source.
            }
        }
        return -1
    }

    override fun close() {
        closed.countDown()
    }
}

private class CancellationAwareBlockingSource : ReplayInputSource {
    val openStarted = CountDownLatch(1)
    val cancelled = CountDownLatch(1)

    override fun open(cancellationToken: ReplayCancellationToken): InputStream? {
        cancellationToken.invokeOnCancellation { cancelled.countDown() }
        openStarted.countDown()
        while (cancelled.count > 0) {
            try {
                cancelled.await()
            } catch (_: InterruptedException) {
                // Source acquisition is released by the cancellation token, not thread interruption.
            }
        }
        throw InterruptedException("Replay source acquisition cancelled")
    }
}
