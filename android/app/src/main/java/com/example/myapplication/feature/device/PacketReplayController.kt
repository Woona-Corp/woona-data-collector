package com.example.myapplication.feature.device

import com.example.myapplication.R
import com.example.myapplication.localization.EnglishTextResolver
import com.example.myapplication.localization.TextResolver
import com.example.myapplication.protocol.RecordedPacketFileParser
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.min

fun interface ReplayInputSource {
    fun open(cancellationToken: ReplayCancellationToken): InputStream?
}

class ReplayCancellationToken {
    private val cancelled = AtomicBoolean(false)
    private val cancellationAction = AtomicReference<(() -> Unit)?>(null)

    fun isCancelled(): Boolean = cancelled.get()

    fun invokeOnCancellation(action: () -> Unit) {
        if (cancelled.get()) {
            action()
            return
        }

        cancellationAction.set(action)
        if (cancelled.get() && cancellationAction.compareAndSet(action, null)) {
            action()
        }
    }

    internal fun cancel() {
        if (cancelled.compareAndSet(false, true)) {
            cancellationAction.getAndSet(null)?.invoke()
        }
    }
}

interface PacketReplayController : AutoCloseable {
    fun startReplay(source: ReplayInputSource)

    fun startReplay(fileBytes: ByteArray) {
        startReplay(ReplayInputSource { ByteArrayInputStream(fileBytes) })
    }

    fun stop()
    /** A stopped replay may still have a worker or dispatched lifecycle callback in flight. */
    fun hasPendingWork(): Boolean = false
}

class DebugPacketReplayController(
    private val submitFragment: (ByteArray) -> PacketSubmitResult,
    private val onReplayPreparing: () -> Unit,
    private val onReplayStarted: () -> Unit,
    private val onReplayCompleted: () -> Unit,
    private val onReplayStopped: () -> Unit,
    private val onError: (String, Throwable?) -> Unit,
    private val appTextResolver: TextResolver = EnglishTextResolver,
    private val packetFileParser: RecordedPacketFileParser = RecordedPacketFileParser(),
    private val chunkSize: Int = DEFAULT_CHUNK_SIZE,
    private val chunkDelayMs: Long = DEFAULT_CHUNK_DELAY_MS,
    private val packetIntervalMs: Long = DEFAULT_PACKET_INTERVAL_MS,
    private val callbackDispatcher: ((() -> Unit) -> Boolean) = { callback ->
        callback()
        true
    },
    private val cancellationDispatcher: ((() -> Unit) -> Unit) = { action ->
        Thread(action, REPLAY_CANCEL_THREAD_NAME).apply {
            isDaemon = true
            start()
        }
    },
    private val replayTempFileFactory: () -> File = {
        File.createTempFile(REPLAY_TEMP_FILE_PREFIX, REPLAY_TEMP_FILE_SUFFIX)
    },
    private val preparedInputStreamFactory: (File) -> InputStream = { replayFile ->
        BufferedInputStream(FileInputStream(replayFile), FILE_BUFFER_SIZE_BYTES)
    },
) : PacketReplayController {
    private val workerLock = Any()

    private var activeRun: ReplayRun? = null
    private val workerThreads = mutableSetOf<Thread>()
    private var pendingLifecycleCallbacks = 0

    override fun hasPendingWork(): Boolean = synchronized(workerLock) {
        workerThreads.isNotEmpty() || pendingLifecycleCallbacks != 0
    }

    override fun startReplay(source: ReplayInputSource) {
        val predecessorThreads = stopActiveRun()
        val run = ReplayRun(predecessorThreads)
        val thread = Thread(
            {
                var preparedReplayFile: File? = null
                try {
                    announcePreparation(run)
                    preparedReplayFile = prepareReplayFile(run, source)
                    waitForPredecessor(run)
                    replayPreparedFile(run, preparedReplayFile)
                    if (run.isStopRequested()) {
                        reportStopped(run)
                    } else {
                        reportCompleted(run)
                    }
                } catch (exception: EmptyReplayFileException) {
                    reportFailure(run, appTextResolver.getString(R.string.replay_file_empty), exception)
                } catch (exception: IllegalArgumentException) {
                    reportFailure(run, appTextResolver.getString(R.string.replay_file_invalid), exception)
                } catch (exception: InterruptedException) {
                    if (run.isStopRequested()) {
                        reportStopped(run)
                    } else {
                        Thread.currentThread().interrupt()
                        reportFailure(run, appTextResolver.getString(R.string.replay_interrupted), exception)
                    }
                } catch (exception: Exception) {
                    reportFailure(run, appTextResolver.getString(R.string.replay_failed), exception)
                } finally {
                    preparedReplayFile?.delete()
                    synchronized(workerLock) {
                        if (activeRun === run) {
                            activeRun = null
                        }
                        // Dispatched lifecycle callbacks have their own barrier;
                        // this worker can make no further submissions or posts.
                        workerThreads.remove(Thread.currentThread())
                    }
                }
            },
            REPLAY_THREAD_NAME,
        )
        run.thread = thread

        synchronized(workerLock) {
            activeRun = run
            workerThreads.add(thread)
        }
        try {
            thread.start()
        } catch (exception: Exception) {
            synchronized(workerLock) { workerThreads.remove(thread) }
            if (claimTerminalCallback(run)) {
                onError(appTextResolver.getString(R.string.replay_failed), exception)
            }
        }
    }

    override fun stop() {
        stopActiveRun()
    }

    override fun close() {
        stop()
    }

    private fun stopActiveRun(): List<Thread> {
        val (run, inputStream) = synchronized(workerLock) {
            val currentRun = activeRun ?: return emptyList()
            activeRun = null
            currentRun to currentRun.requestStop()
        }
        run.thread.interrupt()
        dispatchCancellation(run, inputStream)
        if (run.hasAnnouncedPreparation()) {
            onReplayStopped()
        }
        return (run.predecessorThreads + run.thread).distinct()
    }

    private fun dispatchCancellation(
        run: ReplayRun,
        inputStream: InputStream?,
    ) {
        try {
            cancellationDispatcher {
                cancelRunInput(run, inputStream)
            }
        } catch (_: Exception) {
            cancelRunInput(run, inputStream)
        }
    }

    private fun cancelRunInput(
        run: ReplayRun,
        inputStream: InputStream?,
    ) {
        try {
            run.cancellationToken.cancel()
        } catch (_: Exception) {
            // Closing the stream remains the fallback cancellation mechanism.
        } finally {
            try {
                inputStream?.close()
            } catch (_: Exception) {
                // Cancellation is best-effort for provider-backed streams.
            }
        }
    }

    private fun announcePreparation(run: ReplayRun) {
        dispatchLifecycleCallback(run) {
            run.markPreparationAnnounced()
            onReplayPreparing()
        }
    }

    private fun prepareReplayFile(
        run: ReplayRun,
        source: ReplayInputSource,
    ): File {
        ensureNotStopped(run)
        val preparedReplayFile = replayTempFileFactory()
        try {
            var packetCount = 0
            val inputStream = source.open(run.cancellationToken) ?: throw EmptyReplayFileException()
            useReplayInputStream(run, inputStream) { stream ->
                BufferedOutputStream(
                    FileOutputStream(preparedReplayFile),
                    FILE_BUFFER_SIZE_BYTES,
                ).use { output ->
                    packetFileParser.forEachPacket(stream) { packet ->
                        ensureNotStopped(run)
                        output.write(packet)
                        packetCount++
                    }
                }
            }
            if (packetCount == 0) {
                throw EmptyReplayFileException()
            }
            return preparedReplayFile
        } catch (throwable: Throwable) {
            preparedReplayFile.delete()
            throw throwable
        }
    }

    private fun waitForPredecessor(run: ReplayRun) {
        run.predecessorThreads.forEach { predecessorThread ->
            while (predecessorThread.isAlive) {
                ensureNotStopped(run)
                predecessorThread.join(PREDECESSOR_JOIN_SLICE_MS)
            }
        }
    }

    private fun replayPreparedFile(
        run: ReplayRun,
        preparedReplayFile: File,
    ) {
        ensureNotStopped(run)
        val inputStream = preparedInputStreamFactory(preparedReplayFile)
        useReplayInputStream(run, inputStream) { stream ->
            startReplaySession(run)
            packetFileParser.forEachPacket(stream) { packet ->
                ensureNotStopped(run)
                replayPacket(run, packet)
            }
        }
    }

    private fun startReplaySession(run: ReplayRun) {
        dispatchLifecycleCallback(run) {
            onReplayStarted()
        }
    }

    private fun dispatchLifecycleCallback(
        run: ReplayRun,
        callback: () -> Unit,
    ) {
        ensureNotStopped(run)
        val callbackFinished = CountDownLatch(1)
        val callbackFailure = AtomicReference<Exception?>()
        val callbackRetired = AtomicBoolean(false)
        synchronized(workerLock) { pendingLifecycleCallbacks++ }
        fun retireCallback() {
            if (callbackRetired.compareAndSet(false, true)) {
                synchronized(workerLock) { pendingLifecycleCallbacks-- }
            }
        }
        val dispatched = try {
            callbackDispatcher {
                try {
                    if (isCurrentRun(run) && !run.isStopRequested()) {
                        callback()
                    }
                } catch (exception: Exception) {
                    callbackFailure.set(exception)
                } finally {
                    callbackFinished.countDown()
                    retireCallback()
                }
            }
        } catch (exception: Exception) {
            retireCallback()
            throw exception
        }
        if (!dispatched) {
            retireCallback()
            throw IllegalStateException("Replay lifecycle callback could not be dispatched")
        }

        callbackFinished.await()
        callbackFailure.get()?.let { exception ->
            throw IllegalStateException("Replay lifecycle callback failed", exception)
        }
        ensureNotStopped(run)
    }

    private fun <T> useReplayInputStream(
        run: ReplayRun,
        inputStream: InputStream,
        action: (InputStream) -> T,
    ): T {
        if (!run.attachInputStream(inputStream)) {
            inputStream.close()
            throw InterruptedException("Replay stopped")
        }

        return try {
            action(inputStream)
        } finally {
            if (run.detachInputStream(inputStream)) {
                inputStream.close()
            }
        }
    }

    private fun replayPacket(
        run: ReplayRun,
        packet: ByteArray,
    ) {
        ensureNotStopped(run)
        val packetStartNanos = System.nanoTime()

        var offset = 0
        while (offset < packet.size) {
            ensureNotStopped(run)
            val endOffset = min(offset + chunkSize, packet.size)
            val submitResult = submitFragment(packet.copyOfRange(offset, endOffset))
            when (submitResult) {
                PacketSubmitResult.ACCEPTED -> Unit
                PacketSubmitResult.REJECTED -> {
                    if (!run.isStopRequested()) {
                        throw IllegalStateException("Replay fragment was rejected by capture pipeline")
                    }
                    return
                }

                PacketSubmitResult.OVERFLOW -> {
                    throw IllegalStateException("Replay overflowed the capture queue")
                }
            }

            offset = endOffset
            if (offset < packet.size) {
                Thread.sleep(chunkDelayMs)
            }
        }

        val elapsedMs = (System.nanoTime() - packetStartNanos) / NANOS_PER_MILLISECOND
        val remainingMs = packetIntervalMs - elapsedMs
        if (remainingMs > 0) {
            Thread.sleep(remainingMs)
        }
    }

    private fun ensureNotStopped(run: ReplayRun) {
        if (run.isStopRequested()) {
            throw InterruptedException("Replay stopped")
        }
    }

    private fun reportCompleted(run: ReplayRun) {
        if (claimTerminalCallback(run)) {
            onReplayCompleted()
        }
    }

    private fun reportStopped(run: ReplayRun) {
        if (run.hasAnnouncedPreparation() && claimTerminalCallback(run)) {
            onReplayStopped()
        }
    }

    private fun reportFailure(
        run: ReplayRun,
        message: String,
        exception: Throwable,
    ) {
        if (!claimTerminalCallback(run)) return
        if (run.isStopRequested()) {
            if (run.hasAnnouncedPreparation()) {
                onReplayStopped()
            }
            return
        }
        onError(message, exception)
        if (run.hasAnnouncedPreparation()) {
            onReplayStopped()
        }
    }

    private fun claimTerminalCallback(run: ReplayRun): Boolean = synchronized(workerLock) {
        if (activeRun === run) {
            activeRun = null
            true
        } else {
            false
        }
    }

    private fun isCurrentRun(run: ReplayRun): Boolean = synchronized(workerLock) {
        activeRun === run
    }

    private companion object {
        const val DEFAULT_CHUNK_SIZE = 247
        const val DEFAULT_CHUNK_DELAY_MS = 15L
        const val DEFAULT_PACKET_INTERVAL_MS = 1_000L
        const val NANOS_PER_MILLISECOND = 1_000_000L
        const val FILE_BUFFER_SIZE_BYTES = 65_536
        const val PREDECESSOR_JOIN_SLICE_MS = 50L
        const val REPLAY_THREAD_NAME = "debug-packet-replay"
        const val REPLAY_CANCEL_THREAD_NAME = "debug-packet-replay-cancel"
        const val REPLAY_TEMP_FILE_PREFIX = "debug-replay-"
        const val REPLAY_TEMP_FILE_SUFFIX = ".bin"
    }
}

private class EmptyReplayFileException : IllegalArgumentException("Replay file is empty")

private class ReplayRun(
    val predecessorThreads: List<Thread>,
) {
    lateinit var thread: Thread
    val cancellationToken = ReplayCancellationToken()
    private val stopRequested = AtomicBoolean(false)
    private val preparationAnnounced = AtomicBoolean(false)
    private val inputStreamLock = Any()
    private var activeInputStream: InputStream? = null

    fun requestStop(): InputStream? {
        stopRequested.set(true)
        return synchronized(inputStreamLock) {
            activeInputStream
        }
    }

    fun isStopRequested(): Boolean = stopRequested.get()

    fun markPreparationAnnounced() {
        preparationAnnounced.set(true)
    }

    fun hasAnnouncedPreparation(): Boolean = preparationAnnounced.get()

    fun attachInputStream(inputStream: InputStream): Boolean = synchronized(inputStreamLock) {
        if (stopRequested.get()) {
            false
        } else {
            activeInputStream = inputStream
            true
        }
    }

    fun detachInputStream(inputStream: InputStream): Boolean = synchronized(inputStreamLock) {
        if (activeInputStream === inputStream) {
            activeInputStream = null
            true
        } else {
            false
        }
    }
}
