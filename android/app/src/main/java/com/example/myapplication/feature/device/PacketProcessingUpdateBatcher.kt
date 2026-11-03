package com.example.myapplication.feature.device

import java.io.File

class PacketProcessingUpdateBatcher(
    private val dispatchIntervalMillis: Long,
    private val schedule: (Runnable, Long) -> Unit,
    private val cancel: (Runnable) -> Unit,
    private val dispatch: (Long, PacketProcessingUpdate) -> Unit,
) {
    private val lock = Any()
    private val dispatchRunnable = Runnable { flushScheduled() }

    private var generation = 0L
    private var scheduledGeneration: Long? = null
    private var pendingUpdate: PendingPacketProcessingUpdate? = null

    fun submit(update: PacketProcessingUpdate) {
        if (dispatchIntervalMillis <= 0L) {
            val currentGeneration = synchronized(lock) { generation }
            dispatch(currentGeneration, update)
            return
        }

        synchronized(lock) {
            val pending = pendingUpdate ?: PendingPacketProcessingUpdate()
            pending.merge(update)
            pendingUpdate = pending
            if (scheduledGeneration == null) {
                scheduledGeneration = generation
                schedule(dispatchRunnable, dispatchIntervalMillis)
            }
        }
    }

    fun flushNow() {
        if (dispatchIntervalMillis <= 0L) return

        synchronized(lock) {
            cancel(dispatchRunnable)
            scheduledGeneration = null
            val updateToDispatch = pendingUpdate?.toImmutable()
            pendingUpdate = null
            if (updateToDispatch != null) {
                dispatch(generation, updateToDispatch)
            }
        }
    }

    fun clearPending() {
        synchronized(lock) {
            generation++
            scheduledGeneration = null
            pendingUpdate = null
            cancel(dispatchRunnable)
        }
    }

    private fun flushScheduled() {
        synchronized(lock) {
            val targetGeneration = scheduledGeneration
            scheduledGeneration = null
            if (targetGeneration == null || targetGeneration != generation) {
                return
            }

            val updateToDispatch = pendingUpdate?.toImmutable()
            pendingUpdate = null
            if (updateToDispatch != null) {
                dispatch(generation, updateToDispatch)
            }
        }
    }

    fun isGenerationCurrent(expectedGeneration: Long): Boolean {
        return synchronized(lock) { generation == expectedGeneration }
    }

    private class PendingPacketProcessingUpdate {
        private val chartSamplesByStream = linkedMapOf<ChartStreamKey, MutableList<ChartPoint>>()
        private val diagnosticEvents = mutableListOf<PacketDiagnosticEvent>()

        private var packetsReceived = 0L
        private var packetsLost = 0L
        private var packetsRejected = 0L
        private var timerRegressionRejects = 0L
        private var fragmentsReceived = 0L
        private var rawBytesReceived = 0L
        private var fragmentsPersisted = 0L
        private var fragmentsDropped = 0L
        private var lastPacketIssue: String? = null
        private var rejectionBreakdown: String? = null

        fun merge(update: PacketProcessingUpdate) {
            packetsReceived = update.packetsReceived
            packetsLost = update.packetsLost
            packetsRejected = update.packetsRejected
            timerRegressionRejects = update.timerRegressionRejects
            fragmentsReceived = update.fragmentsReceived
            rawBytesReceived = update.rawBytesReceived
            fragmentsPersisted = update.fragmentsPersisted
            fragmentsDropped = update.fragmentsDropped
            if (update.lastPacketIssue != null) {
                lastPacketIssue = update.lastPacketIssue
            }
            if (update.rejectionBreakdown != null) {
                rejectionBreakdown = update.rejectionBreakdown
            }

            update.chartSamplesByStream.forEach { (streamKey, points) ->
                if (points.isEmpty()) return@forEach
                chartSamplesByStream.getOrPut(streamKey) { mutableListOf() }.addAll(points)
            }
            diagnosticEvents += update.diagnosticEvents
        }

        fun toImmutable(): PacketProcessingUpdate {
            return PacketProcessingUpdate(
                packetsReceived = packetsReceived,
                packetsLost = packetsLost,
                packetsRejected = packetsRejected,
                timerRegressionRejects = timerRegressionRejects,
                fragmentsReceived = fragmentsReceived,
                rawBytesReceived = rawBytesReceived,
                fragmentsPersisted = fragmentsPersisted,
                fragmentsDropped = fragmentsDropped,
                chartSamplesByStream = chartSamplesByStream.mapValues { (_, points) -> points.toList() },
                lastPacketIssue = lastPacketIssue,
                rejectionBreakdown = rejectionBreakdown,
                diagnosticEvents = diagnosticEvents.toList(),
            )
        }
    }
}

class BatchingPacketCaptureController(
    private val delegate: PacketCaptureController,
    private val batcher: PacketProcessingUpdateBatcher,
) : PacketCaptureController {
    override fun recoverPendingFragments(directory: File): PacketRecoveryResult =
        delegate.recoverPendingFragments(directory)

    override fun submit(packetFragment: ByteArray): PacketSubmitResult = delegate.submit(packetFragment)

    override fun submit(
        packetFragment: ByteArray,
        receivedAtMillis: Long,
        receivedAtMonotonicNs: Long,
    ): PacketSubmitResult = delegate.submit(packetFragment, receivedAtMillis, receivedAtMonotonicNs)

    override fun recordDiagnosticEvent(type: PacketDiagnosticType, message: String) {
        delegate.recordDiagnosticEvent(type, message)
    }

    override fun stopCapture() {
        delegate.stopCapture()
        batcher.clearPending()
    }

    override fun droppedFragments(): Long = delegate.droppedFragments()

    override fun finishCapture(timeoutMillis: Long): Boolean {
        val finished = delegate.finishCapture(timeoutMillis)
        batcher.flushNow()
        return finished
    }

    override fun updateSelection(sensorType: Int, channel: Int) {
        delegate.updateSelection(sensorType, channel)
    }

    override fun useSessionDirectory(directory: File) {
        delegate.useSessionDirectory(directory)
    }

    override fun resetSession() {
        delegate.resetSession()
        batcher.clearPending()
    }

    override fun flush() {
        batcher.flushNow()
        delegate.flush()
    }

    override fun currentFile() = delegate.currentFile()

    override fun currentPacketFile() = delegate.currentPacketFile()

    override fun currentPacketTimelineFile() = delegate.currentPacketTimelineFile()

    override fun currentRawFile() = delegate.currentRawFile()

    override fun currentLogFile() = delegate.currentLogFile()

    override fun close() {
        delegate.stopCapture()
        batcher.clearPending()
        delegate.close()
    }
}
