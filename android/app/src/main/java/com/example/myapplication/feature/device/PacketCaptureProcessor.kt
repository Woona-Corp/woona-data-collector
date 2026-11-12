package com.example.myapplication.feature.device

import com.example.myapplication.R
import com.example.myapplication.localization.EnglishTextResolver
import com.example.myapplication.localization.TextResolver
import com.example.myapplication.protocol.PacketAssembler
import com.example.myapplication.protocol.PacketAssemblyFailureReason
import com.example.myapplication.protocol.PacketAssemblyResult
import com.example.myapplication.protocol.PacketSequenceGuard
import com.example.myapplication.protocol.PacketSequenceIssue
import com.example.myapplication.protocol.PacketStatsTracker
import com.example.myapplication.protocol.PacketValidationFailureReason
import com.example.myapplication.protocol.PacketValidationResult
import com.example.myapplication.protocol.PacketValidator
import com.example.myapplication.storage.BleDiagnosticLogFileStore
import com.example.myapplication.storage.BlePacketFileStore
import com.example.myapplication.storage.BlePacketTimelineFileStore
import com.example.myapplication.storage.BleRawFragmentFileStore
import java.io.File
import java.io.DataOutputStream
import java.io.FileOutputStream
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

data class PacketProcessingUpdate(
    val packetsReceived: Long,
    val packetsLost: Long,
    val packetsRejected: Long,
    val timerRegressionRejects: Long,
    val fragmentsReceived: Long = 0L,
    val rawBytesReceived: Long = 0L,
    val fragmentsPersisted: Long = 0L,
    val fragmentsDropped: Long = 0L,
    val chartSamplesByStream: Map<ChartStreamKey, List<ChartPoint>>,
    val lastPacketIssue: String? = null,
    val rejectionBreakdown: String? = null,
    val diagnosticEvents: List<PacketDiagnosticEvent> = emptyList(),
)

data class PacketDiagnosticEvent(
    val id: Long,
    val type: PacketDiagnosticType,
    val message: String,
)

enum class PacketDiagnosticType {
    INFO,
    ACCEPTED,
    GAP,
    REJECTED,
}

enum class PacketSubmitResult {
    ACCEPTED,
    OVERFLOW,
    REJECTED,
}

sealed class PacketRecoveryResult {
    data class Recovered(val file: File) : PacketRecoveryResult()
    object Unsupported : PacketRecoveryResult()
    object NoFailure : PacketRecoveryResult()
    object Busy : PacketRecoveryResult()
    object Failed : PacketRecoveryResult()
}

interface PacketCaptureController : AutoCloseable {
    /** Exports retained fragments after a failure; never repairs the original files. */
    fun recoverPendingFragments(directory: File): PacketRecoveryResult = PacketRecoveryResult.Unsupported
    fun submit(packetFragment: ByteArray): PacketSubmitResult
    fun submit(
        packetFragment: ByteArray,
        receivedAtMillis: Long,
        receivedAtMonotonicNs: Long,
    ): PacketSubmitResult = submit(packetFragment)
    fun recordDiagnosticEvent(type: PacketDiagnosticType, message: String)
    fun stopCapture()
    /** Count of fragments refused due to queue overflow in the current capture. */
    fun droppedFragments(): Long = 0L
    fun finishCapture(timeoutMillis: Long): Boolean {
        stopCapture()
        flush()
        return true
    }
    fun updateSelection(sensorType: Int, channel: Int)
    fun useSessionDirectory(directory: File) = Unit
    fun resetSession()
    fun flush()
    fun currentFile(): File?
    fun currentPacketFile(): File? = currentFile()
    fun currentPacketTimelineFile(): File? = null
    fun currentRawFile(): File? = null
    fun currentLogFile(): File? = null
}

class PacketCaptureProcessor(
    private val packetFileStore: BlePacketFileStore,
    private val rawFragmentFileStore: BleRawFragmentFileStore,
    private val diagnosticLogFileStore: BleDiagnosticLogFileStore,
    private val packetTimelineFileStore: BlePacketTimelineFileStore? = null,
    private val appTextResolver: TextResolver = EnglishTextResolver,
    private val onPacketProcessed: (PacketProcessingUpdate) -> Unit,
    private val onError: (String, Throwable?) -> Unit,
    private val onAcceptedPacketTimestamp: (
        wallClockMillis: Long,
        monotonicNs: Long,
        deviceTimerMillis: Long,
    ) -> Unit = { _, _, _ -> },
    packetAssembler: PacketAssembler? = null,
    private val packetStats: PacketStatsTracker = PacketStatsTracker(),
    private val packetValidator: PacketValidator = PacketValidator(),
    private val wallClockMillisProvider: () -> Long = System::currentTimeMillis,
    private val monotonicNanosProvider: () -> Long = System::nanoTime,
    private val summaryIntervalMillis: Long = DEFAULT_SUMMARY_INTERVAL_MS,
    private val maxPendingFragments: Int = MAX_PENDING_FRAGMENTS,
    private val flushRaw: () -> Unit = { rawFragmentFileStore.flush() },
) : PacketCaptureController {
    private val pendingResyncDiagnosticEvents = mutableListOf<PacketDiagnosticEvent>()
    private val packetAssembler = packetAssembler ?: PacketAssembler(
        onResyncDiagnostic = { diagnostic ->
            pendingResyncDiagnosticEvents += createDiagnosticEvent(
                type = PacketDiagnosticType.INFO,
                message = "Packet resync: ${diagnostic.summary()}",
            )
        },
    )
    private val processingLock = Any()
    private val queueAdmissionLock = Any()
    private val idleMonitor = Object()
    private val queue = ArrayBlockingQueue<QueuedFragment>(maxPendingFragments)

    @Volatile
    private var isAcceptingFragments = true

    @Volatile
    private var isRunning = true

    @Volatile
    private var sessionId = 0L

    @Volatile
    private var rejectedPackets = 0L

    @Volatile
    private var lastAcceptedTimerMillis = UNINITIALIZED_TIMER_MILLIS
    private val packetSequenceGuard = PacketSequenceGuard()

    @Volatile
    private var timerRegressionRejects = 0L

    @Volatile
    private var receivedFragmentCount = 0L

    @Volatile
    private var receivedRawBytes = 0L
    private val queuedFragmentCount = AtomicLong(0L)
    private val droppedFragmentCount = AtomicLong(0L)
    private val pendingQueueOverflowCount = AtomicLong(0L)
    private val pendingQueueOverflowFragmentBytes = AtomicInteger(0)
    private var acceptedPacketSequence = 0L

    private val rejectionCounts = linkedMapOf<String, Long>()
    private var nextDiagnosticEventId = 0L
    private var maxObservedQueueDepth = 0
    private var queueWarningLevel = -1
    private var lastSummaryWallClockMillis = wallClockMillisProvider()
    private var inFlightFragments = 0
    // A failed append may have partially written. Retain the failed fragment and the
    // bounded queue, but never retry blindly or report this session as successful.
    @Volatile private var processingFailure: Exception? = null
    // Protected by processingLock. A successful flush reaches the kernel, not fsync.
    private val unflushedFragments = mutableListOf<QueuedFragment>()
    private var unflushedBytes = 0
    private var failedFragment: QueuedFragment? = null
    private var recoveryFile: File? = null

    override fun recoverPendingFragments(directory: File): PacketRecoveryResult {
        // Same lock order as reset. Keep admission and polling frozen until publication.
        synchronized(processingLock) {
            synchronized(queueAdmissionLock) {
                synchronized(idleMonitor) {
                    recoveryFile?.let { return PacketRecoveryResult.Recovered(it) }
                    if (processingFailure == null) return PacketRecoveryResult.NoFailure
                    if (inFlightFragments != 0) return PacketRecoveryResult.Busy
                    var temporary: java.nio.file.Path? = null
                    try {
                        val dir = directory.toPath().toRealPath()
                        if (!Files.isDirectory(dir)) return PacketRecoveryResult.Failed
                        val name = "packet-recovery-${UUID.randomUUID()}.bin"
                        temporary = Files.createTempFile(dir, ".packet-recovery-", ".tmp")
                        val fragments = unflushedFragments.toList() +
                            listOfNotNull(failedFragment?.takeUnless { failed -> unflushedFragments.any { it === failed } }) + queue.toList()
                        FileOutputStream(temporary.toFile()).use { stream ->
                            val output = DataOutputStream(stream)
                            // Big endian: magic, version, count, then wall ms, monotonic ns,
                            // byte length and bytes for each fragment in admission order.
                            output.write(byteArrayOf(87, 80, 82, 69, 67, 79, 86, 0)) // WPRECOV\0
                            output.writeInt(1)
                            output.writeInt(fragments.size)
                            fragments.forEach { fragment ->
                                output.writeLong(fragment.receivedAtMillis)
                                output.writeLong(fragment.receivedAtMonotonicNs)
                                output.writeInt(fragment.bytes.size)
                                output.write(fragment.bytes)
                            }
                            output.flush()
                            stream.fd.sync()
                        }
                        val destination = dir.resolve(name)
                        Files.move(temporary, destination, StandardCopyOption.ATOMIC_MOVE)
                        temporary = null
                        // A synced file alone does not make the rename durable.
                        FileChannel.open(dir, StandardOpenOption.READ).use { it.force(true) }
                        val file = destination.toFile()
                        recoveryFile = file
                        unflushedFragments.clear()
                        unflushedBytes = 0
                        failedFragment = null
                        queue.clear()
                        idleMonitor.notifyAll()
                        return PacketRecoveryResult.Recovered(file)
                    } catch (_: Exception) {
                        // A published file may exist if directory sync failed. Keep memory
                        // and never overwrite or remove it on retry.
                        return PacketRecoveryResult.Failed
                    } finally {
                        temporary?.let { try { Files.deleteIfExists(it) } catch (_: Exception) { } }
                    }
                }
            }
        }
    }

    private val workerThread = Thread(::runLoop, WORKER_THREAD_NAME).apply {
        priority = Thread.MAX_PRIORITY
        start()
    }

    override fun submit(packetFragment: ByteArray): PacketSubmitResult {
        return submit(
            packetFragment = packetFragment,
            receivedAtMillis = wallClockMillisProvider(),
            receivedAtMonotonicNs = monotonicNanosProvider(),
        )
    }

    override fun submit(
        packetFragment: ByteArray,
        receivedAtMillis: Long,
        receivedAtMonotonicNs: Long,
    ): PacketSubmitResult {
        if (packetFragment.isEmpty()) return PacketSubmitResult.ACCEPTED
        if (packetFragment.size > MAX_UNFLUSHED_BYTES) return PacketSubmitResult.REJECTED

        val copiedFragment = packetFragment.clone()
        return synchronized(queueAdmissionLock) {
            if (!isAcceptingFragments) {
                PacketSubmitResult.REJECTED
            } else if (
                queue.offer(
                    QueuedFragment(
                        sessionId = sessionId,
                        bytes = copiedFragment,
                        receivedAtMillis = receivedAtMillis,
                        receivedAtMonotonicNs = receivedAtMonotonicNs,
                    ),
                )
            ) {
                queuedFragmentCount.incrementAndGet()
                PacketSubmitResult.ACCEPTED
            } else {
                droppedFragmentCount.incrementAndGet()
                pendingQueueOverflowCount.incrementAndGet()
                pendingQueueOverflowFragmentBytes.set(copiedFragment.size)
                PacketSubmitResult.OVERFLOW
            }
        }
    }

    override fun droppedFragments(): Long = droppedFragmentCount.get()

    override fun finishCapture(timeoutMillis: Long): Boolean {
        synchronized(queueAdmissionLock) {
            isAcceptingFragments = false
        }
        if (!awaitQueueIdle(timeoutMillis)) return false
        synchronized(processingLock) {
            checkProcessingFailure()
            emitPendingQueueOverflowDiagnostic()
            flush()
            try {
                // Transport callbacks can outlive capture drain and artifact hashing.
                diagnosticLogFileStore.finishSession()
            } catch (exception: Exception) {
                latchFailure(exception)
                throw exception
            }
        }
        return true
    }

    override fun recordDiagnosticEvent(
        type: PacketDiagnosticType,
        message: String,
    ) {
        val update = synchronized(processingLock) {
            val event = createDiagnosticEvent(type = type, message = message)
            createStatsUpdateLocked(diagnosticEvents = listOf(event))
        }

        onPacketProcessed(update)
    }

    override fun updateSelection(sensorType: Int, channel: Int) {
        // Chart history now keeps all streams, so selection is handled entirely in UI state.
    }

    override fun useSessionDirectory(directory: File) {
        synchronized(processingLock) {
            checkProcessingFailure()
            try {
                flushRawBatchLocked()
                packetFileStore.useSessionDirectory(directory)
                rawFragmentFileStore.useSessionDirectory(directory)
                diagnosticLogFileStore.useSessionDirectory(directory)
                packetTimelineFileStore?.useSessionDirectory(directory)
                // The preceding capture is drained before a new directory is
                // admitted; its overflow must not taint a new PREPARING row.
                droppedFragmentCount.set(0L)
            } catch (exception: Exception) {
                latchFailure(exception)
                throw exception
            }
        }
    }

    override fun stopCapture() {
        synchronized(queueAdmissionLock) {
            // Closing admission must not invalidate fragments already admitted.
            isAcceptingFragments = false
        }
        notifyQueueIdleWaiters()
    }

    override fun resetSession() {
        try {
            synchronized(processingLock) {
                synchronized(queueAdmissionLock) {
                    synchronized(idleMonitor) {
                        checkProcessingFailure()
                        check(queue.isEmpty() && inFlightFragments == 0) { "Cannot reset an undrained capture" }
                        isAcceptingFragments = false
                        // Reset stores before changing the generation or reopening admission.
                        try {
                            flushRawBatchLocked()
                            packetFileStore.resetSession()
                            rawFragmentFileStore.resetSession()
                            diagnosticLogFileStore.resetSession()
                            packetTimelineFileStore?.resetSession()
                        } catch (exception: Exception) {
                            processingFailure = exception
                            isAcceptingFragments = false
                            throw exception
                        }
                        sessionId++
                    }
                }
                packetAssembler.reset()
                packetStats.reset()
                packetSequenceGuard.reset()
                rejectedPackets = 0L
                lastAcceptedTimerMillis = UNINITIALIZED_TIMER_MILLIS
                timerRegressionRejects = 0L
                receivedFragmentCount = 0L
                receivedRawBytes = 0L
                queuedFragmentCount.set(0L)
                droppedFragmentCount.set(0L)
                pendingQueueOverflowCount.set(0L)
                pendingQueueOverflowFragmentBytes.set(0)
                acceptedPacketSequence = 0L
                rejectionCounts.clear()
                nextDiagnosticEventId = 0L
                maxObservedQueueDepth = 0
                queueWarningLevel = -1
                lastSummaryWallClockMillis = wallClockMillisProvider()
                synchronized(queueAdmissionLock) { isAcceptingFragments = true }
            }
            notifyQueueIdleWaiters()
        } catch (exception: Exception) {
            onError(appTextResolver.getString(R.string.failed_reset_capture_session), exception)
            throw exception
        }
    }

    override fun flush() {
        try {
            synchronized(processingLock) {
                checkProcessingFailure()
                try {
                    diagnosticLogFileStore.flush()
                    flushRawBatchLocked()
                    packetFileStore.flush()
                    packetTimelineFileStore?.flush()
                } catch (exception: Exception) {
                    latchFailure(exception)
                    throw exception
                }
            }
        } catch (exception: Exception) {
            latchFailure(exception)
            onError(appTextResolver.getString(R.string.failed_flush_buffered_output), exception)
            throw exception
        }
    }

    override fun currentFile(): File? = packetFileStore.currentFile()

    override fun currentPacketFile(): File? = packetFileStore.currentFile()

    override fun currentPacketTimelineFile(): File? = packetTimelineFileStore?.currentFile()

    override fun currentRawFile(): File? = rawFragmentFileStore.currentFile()

    override fun currentLogFile(): File? = diagnosticLogFileStore.currentFile()

    override fun close() {
        synchronized(queueAdmissionLock) { isAcceptingFragments = false }
        isRunning = false
        // Wake an idle worker without interrupting an in-flight callback or
        // append: interruption there would itself create a persistence failure.
        java.util.concurrent.locks.LockSupport.unpark(workerThread)

        try {
            workerThread.join()
        } catch (exception: InterruptedException) {
            Thread.currentThread().interrupt()
            onError(
                appTextResolver.getString(R.string.interrupted_waiting_packet_processor_shutdown),
                exception,
            )
        }

        try {
            synchronized(processingLock) {
                // Closing a buffered stream can retry a partially failed write.
                // Leave all originals untouched after any persistence failure.
                checkProcessingFailure()
                try {
                    emitPendingQueueOverflowDiagnostic()
                    diagnosticLogFileStore.flush()
                    flushRawBatchLocked()
                    packetFileStore.flush()
                    packetTimelineFileStore?.flush()
                    diagnosticLogFileStore.close()
                    rawFragmentFileStore.close()
                    packetFileStore.close()
                    packetTimelineFileStore?.close()
                } catch (exception: Exception) {
                    latchFailure(exception)
                    throw exception
                }
            }
        } catch (exception: Exception) {
            onError(appTextResolver.getString(R.string.failed_close_buffered_output), exception)
        }
    }

    private fun flushRawBatchLocked() {
        flushRaw()
        unflushedFragments.clear()
        unflushedBytes = 0
    }

    private fun runLoop() {
        while (processingFailure == null && (isRunning || !queue.isEmpty() || pendingQueueOverflowCount.get() > 0L)) {
            try {
                emitPendingQueueOverflowDiagnostic()
                val chunk = pollNextChunk()
                if (chunk == null) {
                    java.util.concurrent.locks.LockSupport.parkNanos(TimeUnit.MILLISECONDS.toNanos(QUEUE_POLL_TIMEOUT_MS))
                    continue
                }
                try {
                    processChunk(chunk)
                } catch (exception: Exception) {
                    failedFragment = chunk
                    latchFailure(exception)
                    onError(appTextResolver.getString(R.string.background_packet_processing_failed), exception)
                } finally {
                    markFragmentComplete()
                }
            } catch (exception: InterruptedException) {
                if (!isRunning) {
                    continue
                }
                Thread.currentThread().interrupt()
                return
            } catch (exception: Exception) {
                latchFailure(exception)
                onError(appTextResolver.getString(R.string.background_packet_processing_failed), exception)
            }
        }
    }

    private fun latchFailure(exception: Exception) {
        synchronized(queueAdmissionLock) {
            if (processingFailure == null) processingFailure = exception
            isAcceptingFragments = false
        }
        notifyQueueIdleWaiters()
    }

    private fun checkProcessingFailure() {
        processingFailure?.let { throw IllegalStateException("Capture persistence or processing failed", it) }
    }

    private fun pollNextChunk(): QueuedFragment? {
        synchronized(queueAdmissionLock) {
            synchronized(idleMonitor) {
                if (processingFailure != null) return null
                val chunk = queue.poll() ?: return null
                inFlightFragments++
                return chunk
            }
        }
    }

    private fun awaitQueueIdle(timeoutMillis: Long): Boolean {
        val timeoutNanos = TimeUnit.MILLISECONDS.toNanos(timeoutMillis.coerceAtLeast(0L))
        val deadline = System.nanoTime() + timeoutNanos
        synchronized(idleMonitor) {
            while (!queue.isEmpty() || inFlightFragments > 0) {
                checkProcessingFailure()
                val remainingNanos = deadline - System.nanoTime()
                if (remainingNanos <= 0L) {
                    return false
                }
                val waitMillis = TimeUnit.NANOSECONDS.toMillis(remainingNanos).coerceAtLeast(1L)
                try {
                    idleMonitor.wait(waitMillis)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    return false
                }
            }
        }
        return true
    }

    private fun markFragmentComplete() {
        synchronized(idleMonitor) {
            inFlightFragments--
            idleMonitor.notifyAll()
        }
    }

    private fun notifyQueueIdleWaiters() {
        synchronized(idleMonitor) {
            idleMonitor.notifyAll()
        }
    }

    private fun processChunk(fragment: QueuedFragment) {
        val acceptedPacketTimestamps = mutableListOf<Triple<Long, Long, Long>>()
        val updates = synchronized(processingLock) {
            checkProcessingFailure()
            if (fragment.sessionId != sessionId) {
                return@synchronized emptyList()
            }

            // Flush before adding an item that would exceed the byte limit. The
            // in-flight fragment remains separately retained if this flush fails.
            if (unflushedBytes + fragment.bytes.size > MAX_UNFLUSHED_BYTES) {
                flushRawBatchLocked()
            }
            // Retain before append: append itself can fail after a partial write.
            unflushedFragments.add(fragment)
            unflushedBytes += fragment.bytes.size
            rawFragmentFileStore.appendFragment(
                sequence = receivedFragmentCount,
                receivedAtMillis = fragment.receivedAtMillis,
                receivedAtMonotonicNs = fragment.receivedAtMonotonicNs,
                fragmentBytes = fragment.bytes,
            )
            receivedFragmentCount++
            receivedRawBytes += fragment.bytes.size.toLong()
            if (unflushedFragments.size >= MAX_UNFLUSHED_FRAGMENTS) flushRawBatchLocked()

            val updates = mutableListOf<PacketProcessingUpdate>()

            val packets = packetAssembler.append(fragment.bytes)
            if (pendingResyncDiagnosticEvents.isNotEmpty()) {
                updates += createStatsUpdateLocked(
                    diagnosticEvents = pendingResyncDiagnosticEvents.toList(),
                )
                pendingResyncDiagnosticEvents.clear()
            }
            for (packet in packets) {
                when (packet) {
                    is PacketAssemblyResult.Rejected -> {
                        val rejectionReason = buildString {
                            append(localizedReason(packet.reason))
                            packet.diagnostic?.summary()?.let {
                                append(" (")
                                append(it)
                                append(')')
                            }
                        }
                        registerRejection(rejectionReason)
                        updates += createStatsUpdateLocked(
                            lastPacketIssue = rejectionReason,
                            rejectionBreakdown = buildRejectionBreakdown(),
                            diagnosticEvents = listOf(
                                createDiagnosticEvent(
                                    type = PacketDiagnosticType.REJECTED,
                                    message = buildRejectedPacketMessage(
                                        reason = rejectionReason,
                                    ),
                                ),
                            ),
                        )
                    }

                    is PacketAssemblyResult.Completed -> {
                        when (val validation = packetValidator.validate(packet.packet.bytes)) {
                            is PacketValidationResult.Accepted -> {
                                val sequenceDecision = packetSequenceGuard.evaluate(
                                    validation.packet.counter, validation.packet.timerMillis,
                                )
                                if (!sequenceDecision.accepted) {
                                    val timerRegressionMessage = when (sequenceDecision.issue) {
                                        PacketSequenceIssue.TIMER_REGRESSION -> appTextResolver.getString(R.string.packet_timer_regressed)
                                        else -> "Packet counter/timer discontinuity; header quarantined, raw data preserved"
                                    }
                                    registerRejection(timerRegressionMessage)
                                    if (sequenceDecision.issue == PacketSequenceIssue.TIMER_REGRESSION) timerRegressionRejects++
                                    updates += createStatsUpdateLocked(
                                        lastPacketIssue = timerRegressionMessage,
                                        rejectionBreakdown = buildRejectionBreakdown(),
                                        diagnosticEvents = listOf(
                                            createDiagnosticEvent(
                                                type = PacketDiagnosticType.REJECTED,
                                                message = buildRejectedPacketMessage(
                                                    reason = timerRegressionMessage,
                                                    packetLength = validation.packet.bytes.size,
                                                    counter = validation.packet.counter,
                                                    timerMillis = validation.packet.timerMillis,
                                                ),
                                            ),
                                        ),
                                    )
                                    continue
                                }

                                val diagnosticEvents = mutableListOf<PacketDiagnosticEvent>()
                                packetFileStore.append(validation.packet.bytes)
                                packetTimelineFileStore?.append(
                                    sequence = acceptedPacketSequence++,
                                    counter = validation.packet.counter,
                                    deviceTimerMillis = validation.packet.timerMillis,
                                    hostWallClockMillis = fragment.receivedAtMillis,
                                    hostMonotonicNs = fragment.receivedAtMonotonicNs,
                                    packetBytes = validation.packet.bytes.size,
                                )

                                val previousTimerMillis = if (lastAcceptedTimerMillis == UNINITIALIZED_TIMER_MILLIS) {
                                    null
                                } else {
                                    lastAcceptedTimerMillis
                                }
                                acceptedPacketTimestamps += Triple(
                                    fragment.receivedAtMillis,
                                    fragment.receivedAtMonotonicNs,
                                    validation.packet.timerMillis,
                                )
                                lastAcceptedTimerMillis = validation.packet.timerMillis
                                packetSequenceGuard.accept(validation.packet.counter, validation.packet.timerMillis)
                                val recordResult = packetStats.record(
                                    validation.packet.counter,
                                    confirmedDiscontinuity = sequenceDecision.confirmedDiscontinuity,
                                )
                                val continuityMessage = when {
                                    recordResult.lossCountUnknown -> "Counter continuity unknown; packet loss cannot be measured across this reset/discontinuity"
                                    sequenceDecision.confirmedDiscontinuity -> "Counter/timer discontinuity confirmed by consecutive packets; new clock segment, raw data preserved"
                                    sequenceDecision.rolledOver -> "Unsigned 32-bit counter/timer rollover; new clock segment"
                                    else -> null
                                }
                                if (continuityMessage != null) {
                                    diagnosticEvents += createDiagnosticEvent(PacketDiagnosticType.INFO, continuityMessage)
                                }
                                if (recordResult.gapCount > 0) {
                                    diagnosticEvents += createDiagnosticEvent(
                                        type = PacketDiagnosticType.GAP,
                                        message = buildGapMessage(
                                            expectedCounter = recordResult.expectedCounter,
                                            actualCounter = recordResult.actualCounter,
                                            gapCount = recordResult.gapCount,
                                        ),
                                    )
                                }
                                diagnosticEvents += createDiagnosticEvent(
                                    type = PacketDiagnosticType.ACCEPTED,
                                    message = buildAcceptedPacketMessage(validation.packet),
                                )

                                updates += createStatsUpdateLocked(
                                    chartSamplesByStream = buildChartSamplesByStream(
                                        packet = validation.packet,
                                        previousTimerMillis = if (recordResult.gapCount > 0 || sequenceDecision.startsNewSegment) null else previousTimerMillis,
                                        startsNewSegment = recordResult.gapCount > 0 || sequenceDecision.startsNewSegment,
                                    ),
                                    lastPacketIssue = continuityMessage,
                                    rejectionBreakdown = buildRejectionBreakdown(),
                                    diagnosticEvents = diagnosticEvents,
                                )
                            }

                            is PacketValidationResult.Rejected -> {
                                val rejectionReason = localizedReason(validation.reason)
                                registerRejection(rejectionReason)
                                updates += createStatsUpdateLocked(
                                    lastPacketIssue = rejectionReason,
                                    rejectionBreakdown = buildRejectionBreakdown(),
                                    diagnosticEvents = listOf(
                                        createDiagnosticEvent(
                                            type = PacketDiagnosticType.REJECTED,
                                            message = buildRejectedPacketMessage(
                                                reason = rejectionReason,
                                                packetLength = packet.packet.bytes.size,
                                                counter = packet.packet.counter,
                                                timerMillis = decodePacketTimerMillis(packet.packet.bytes),
                                                parsedBlockCount = validation.parsedBlockCount,
                                                consumedBytes = validation.consumedBytes,
                                                trailingBytes = validation.trailingBytes,
                                                failedBlockIndex = validation.failedBlockIndex,
                                            ),
                                        ),
                                    ),
                                )
                            }
                        }
                    }
                }
            }

            maybeBuildQueuePressureUpdatesLocked(fragmentSize = fragment.bytes.size).let(updates::addAll)
            maybeCreateSummaryUpdateLocked()?.let(updates::add)
            updates
        }

        acceptedPacketTimestamps.forEach { (wallClockMillis, monotonicNs, deviceTimerMillis) ->
            onAcceptedPacketTimestamp(wallClockMillis, monotonicNs, deviceTimerMillis)
        }
        updates.forEach(onPacketProcessed)
    }

    private fun buildChartSamplesByStream(
        packet: com.example.myapplication.protocol.ValidatedPacket,
        previousTimerMillis: Long?,
        startsNewSegment: Boolean,
    ): Map<ChartStreamKey, List<ChartPoint>> {
        val samplesByStream = linkedMapOf<ChartStreamKey, MutableList<Float>>()

        packet.sensorBlocks.forEach { sensorBlock ->
            sensorBlock.channelSamples.forEachIndexed { channelIndex, channelSamples ->
                val sampledChannel = downsample(channelSamples)
                if (sampledChannel.isEmpty()) return@forEachIndexed

                val streamKey = ChartStreamKey(
                    sensorType = sensorBlock.sensorType,
                    channel = channelIndex + 1,
                )
                samplesByStream.getOrPut(streamKey) { mutableListOf() }.addAll(sampledChannel)
            }
        }

        return samplesByStream.mapValues { (_, values) ->
            buildTimedChartPoints(
                samples = values,
                currentTimerMillis = packet.timerMillis,
                previousTimerMillis = previousTimerMillis,
                startsNewSegment = startsNewSegment,
            )
        }
    }

    private fun buildTimedChartPoints(
        samples: List<Float>,
        currentTimerMillis: Long,
        previousTimerMillis: Long?,
        startsNewSegment: Boolean,
    ): List<ChartPoint> {
        if (samples.isEmpty()) return emptyList()

        val intervalMillis = when {
            previousTimerMillis == null -> null
            currentTimerMillis <= previousTimerMillis -> null
            else -> currentTimerMillis - previousTimerMillis
        }

        return samples.mapIndexed { index, value ->
            val pointTimeMillis = if (samples.size == 1) {
                currentTimerMillis
            } else if (intervalMillis == null) {
                currentTimerMillis
            } else {
                requireNotNull(previousTimerMillis) + (intervalMillis * (index + 1) / samples.size)
            }
            ChartPoint(
                timeMillis = pointTimeMillis,
                value = value,
                startsNewSegment = startsNewSegment && index == 0,
            )
        }
    }

    private fun downsample(samples: List<Float>): List<Float> {
        if (samples.size <= CHART_DOWNSAMPLE_THRESHOLD) return samples

        return samples.filterIndexed { index, _ -> index % CHART_DOWNSAMPLE_STEP == 0 }
    }

    private fun registerRejection(reason: String) {
        rejectedPackets++
        rejectionCounts[reason] = (rejectionCounts[reason] ?: 0L) + 1L
    }

    private fun maybeBuildQueuePressureUpdatesLocked(fragmentSize: Int): List<PacketProcessingUpdate> {
        val queueDepth = queue.size
        maxObservedQueueDepth = maxOf(maxObservedQueueDepth, queueDepth)
        val nextQueueWarningLevel = when {
            queueDepth >= (maxPendingFragments * 9 / 10) -> 2
            queueDepth >= (maxPendingFragments * 3 / 4) -> 1
            queueDepth >= (maxPendingFragments / 2) -> 0
            else -> -1
        }
        if (nextQueueWarningLevel <= queueWarningLevel) {
            return emptyList()
        }
        queueWarningLevel = nextQueueWarningLevel
        return listOf(
            createStatsUpdateLocked(
                diagnosticEvents = listOf(
                    createDiagnosticEvent(
                        type = PacketDiagnosticType.INFO,
                        message = appTextResolver.getString(
                            R.string.capture_queue_pressure,
                            queueDepth,
                            maxPendingFragments,
                            queueDepth * 100 / maxPendingFragments,
                            maxObservedQueueDepth,
                            fragmentSize,
                        ),
                    ),
                ),
            ),
        )
    }

    private fun buildRejectionBreakdown(): String? {
        if (rejectionCounts.isEmpty()) return null

        return rejectionCounts.entries.joinToString(separator = " | ") { (reason, count) ->
            appTextResolver.getString(R.string.rejection_breakdown_item, reason, count)
        }
    }

    private fun nextDiagnosticId(): Long {
        val id = nextDiagnosticEventId
        nextDiagnosticEventId++
        return id
    }

    private fun createDiagnosticEvent(
        type: PacketDiagnosticType,
        message: String,
    ): PacketDiagnosticEvent {
        val event = PacketDiagnosticEvent(
            id = nextDiagnosticId(),
            type = type,
            message = message,
        )
        try {
            diagnosticLogFileStore.appendEvent(
                eventId = event.id,
                type = event.type.name,
                message = event.message,
            )
        } catch (exception: Exception) {
            latchFailure(exception)
            onError(appTextResolver.getString(R.string.failed_persist_diagnostic_log_event), exception)
            throw exception
        }
        return event
    }

    private fun createStatsUpdateLocked(
        chartSamplesByStream: Map<ChartStreamKey, List<ChartPoint>> = emptyMap(),
        lastPacketIssue: String? = null,
        rejectionBreakdown: String? = buildRejectionBreakdown(),
        diagnosticEvents: List<PacketDiagnosticEvent> = emptyList(),
    ): PacketProcessingUpdate {
        val statsSnapshot = packetStats.snapshot()
        return PacketProcessingUpdate(
            packetsReceived = statsSnapshot.packetsReceived,
            packetsLost = statsSnapshot.packetsLost,
            packetsRejected = rejectedPackets,
            timerRegressionRejects = timerRegressionRejects,
            fragmentsReceived = queuedFragmentCount.get(),
            rawBytesReceived = receivedRawBytes,
            fragmentsPersisted = receivedFragmentCount,
            fragmentsDropped = droppedFragmentCount.get(),
            chartSamplesByStream = chartSamplesByStream,
            lastPacketIssue = lastPacketIssue,
            rejectionBreakdown = rejectionBreakdown,
            diagnosticEvents = diagnosticEvents,
        )
    }

    private fun maybeCreateSummaryUpdateLocked(): PacketProcessingUpdate? {
        val now = wallClockMillisProvider()
        if (now - lastSummaryWallClockMillis < summaryIntervalMillis) return null
        lastSummaryWallClockMillis = now
        val statsSnapshot = packetStats.snapshot()
        val event = createDiagnosticEvent(
            type = PacketDiagnosticType.INFO,
            message = appTextResolver.getString(
                R.string.capture_summary,
                statsSnapshot.packetsReceived,
                statsSnapshot.packetsLost,
                rejectedPackets,
                timerRegressionRejects,
                queuedFragmentCount.get(),
                receivedFragmentCount,
                receivedRawBytes,
                droppedFragmentCount.get(),
                queue.size,
                maxObservedQueueDepth,
            ),
        )
        return createStatsUpdateLocked(diagnosticEvents = listOf(event))
    }

    private fun emitPendingQueueOverflowDiagnostic() {
        val dropped = pendingQueueOverflowCount.getAndSet(0L)
        if (dropped <= 0L) return

        val fragmentBytes = pendingQueueOverflowFragmentBytes.get()
        val update = synchronized(processingLock) {
            createStatsUpdateLocked(
                diagnosticEvents = listOf(
                    createDiagnosticEvent(
                        type = PacketDiagnosticType.INFO,
                        message = appTextResolver.getString(
                            R.string.capture_queue_overflow,
                            dropped,
                            queue.size,
                            maxPendingFragments,
                            fragmentBytes,
                        ),
                    ),
                ),
            )
        }
        onPacketProcessed(update)
    }

    private fun buildAcceptedPacketMessage(packet: com.example.myapplication.protocol.ValidatedPacket): String {
        return appTextResolver.getString(
            R.string.accepted_packet_message,
            packet.counter,
            packet.timerMillis,
            packet.bytes.size,
            packet.measurementCount,
        )
    }

    private fun buildGapMessage(
        expectedCounter: Long?,
        actualCounter: Long?,
        gapCount: Long,
    ): String {
        return appTextResolver.getString(
            R.string.gap_detected_message,
            expectedCounter?.toString() ?: "?",
            actualCounter?.toString() ?: "?",
            gapCount,
        )
    }

    private fun decodePacketTimerMillis(packetBytes: ByteArray): Long? {
        val timerOffset = 11
        if (packetBytes.size < timerOffset + 4) return null
        return (packetBytes[timerOffset].toLong() and 0xFF) or
            ((packetBytes[timerOffset + 1].toLong() and 0xFF) shl 8) or
            ((packetBytes[timerOffset + 2].toLong() and 0xFF) shl 16) or
            ((packetBytes[timerOffset + 3].toLong() and 0xFF) shl 24)
    }

    private fun buildRejectedPacketMessage(
        reason: String,
        packetLength: Int? = null,
        counter: Long? = null,
        timerMillis: Long? = null,
        parsedBlockCount: Int? = null,
        consumedBytes: Int? = null,
        trailingBytes: Int? = null,
        failedBlockIndex: Int? = null,
    ): String {
        val details = buildList {
            add(appTextResolver.getString(R.string.rejected_packet_detail_reason, reason))
            if (packetLength != null) add(appTextResolver.getString(R.string.rejected_packet_detail_length, packetLength))
            if (counter != null) add(appTextResolver.getString(R.string.rejected_packet_detail_counter, counter))
            if (timerMillis != null) add(appTextResolver.getString(R.string.rejected_packet_detail_timer, timerMillis))
            if (parsedBlockCount != null) add("parsedBlockCount=$parsedBlockCount")
            if (consumedBytes != null) add("consumedBytes=$consumedBytes")
            if (trailingBytes != null) add("trailingBytes=$trailingBytes")
            if (failedBlockIndex != null) add("failedBlockIndex=$failedBlockIndex")
        }
        return appTextResolver.getString(
            R.string.rejected_packet_message,
            details.joinToString(separator = ", "),
        )
    }

    private fun localizedReason(reason: PacketAssemblyFailureReason): String {
        return when (reason) {
            PacketAssemblyFailureReason.OVERLAPPING_PACKET_START ->
                appTextResolver.getString(R.string.packet_assembly_overlapping_start)
        }
    }

    private fun localizedReason(reason: PacketValidationFailureReason): String {
        return when (reason) {
            PacketValidationFailureReason.INVALID_START ->
                appTextResolver.getString(R.string.packet_validation_invalid_start)
            PacketValidationFailureReason.INVALID_LENGTH ->
                appTextResolver.getString(R.string.packet_validation_invalid_length)
            PacketValidationFailureReason.INVALID_MEASUREMENT_COUNT ->
                appTextResolver.getString(R.string.packet_validation_invalid_measurement_count)
            PacketValidationFailureReason.INVALID_SENSOR_BLOCKS ->
                appTextResolver.getString(R.string.packet_validation_invalid_sensor_blocks)
        }
    }

    private companion object {
        const val MAX_PENDING_FRAGMENTS = 512
        const val MAX_UNFLUSHED_FRAGMENTS = 64
        const val MAX_UNFLUSHED_BYTES = 65_536
        const val CHART_DOWNSAMPLE_THRESHOLD = 500
        const val CHART_DOWNSAMPLE_STEP = 4
        const val QUEUE_POLL_TIMEOUT_MS = 100L
        const val DEFAULT_SUMMARY_INTERVAL_MS = 5_000L
        const val WORKER_THREAD_NAME = "packet-capture-processor"
        const val UNINITIALIZED_TIMER_MILLIS = -1L
    }

    private data class QueuedFragment(
        val sessionId: Long,
        val bytes: ByteArray,
        val receivedAtMillis: Long,
        val receivedAtMonotonicNs: Long,
    )
}
