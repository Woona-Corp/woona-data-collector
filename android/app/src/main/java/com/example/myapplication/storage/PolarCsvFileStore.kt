package com.example.myapplication.storage

import com.example.myapplication.protocol.PolarAccelerationFrame
import com.example.myapplication.protocol.PolarEcgFrame
import com.example.myapplication.protocol.PolarHeartRateFrame
import java.io.BufferedWriter
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStream
import java.time.Instant

class PolarPersistenceException(cause: Throwable) : IOException(
    "Polar CSV persistence failed; buffered samples may have been lost.", cause,
)

class PolarCsvFileStore(
    private val openStream: (File) -> OutputStream = { FileOutputStream(it, true) },
) : AutoCloseable {
    private class Stream(val raw: OutputStream, val writer: BufferedWriter)

    private var directory: File? = null
    private var streams: List<Stream> = emptyList()
    private var failure: PolarPersistenceException? = null

    private fun checkFailure() { failure?.let { throw it } }

    // Never close a failed buffered writer: close would retry its pending flush.
    private fun fail(error: Exception, failed: Stream): Nothing {
        val persistent = failure ?: PolarPersistenceException(error).also { failure = it }
        val remaining = streams
        streams = emptyList()
        remaining.forEach { stream ->
            try {
                if (stream === failed) stream.raw.close() else {
                    // Flush separately: a failure must not be retried by close().
                    stream.writer.flush()
                    stream.writer.close()
                }
            } catch (cleanup: Exception) {
                persistent.addSuppressed(cleanup)
                if (stream !== failed) {
                    try { stream.raw.close() } catch (rawError: Exception) { persistent.addSuppressed(rawError) }
                }
            }
        }
        throw persistent
    }

    @Synchronized
    fun isSessionDirectory(expected: File): Boolean = directory == expected

    @Synchronized
    fun useSessionDirectory(directory: File) {
        close()
        this.directory = directory
    }

    @Synchronized
    fun start(): Boolean {
        checkFailure()
        val target = directory ?: return false
        if (streams.isNotEmpty()) return true
        check(target.isDirectory || target.mkdirs()) { "Could not create Polar recording directory" }
        val opened = mutableListOf<Stream>()
        val files = FILE_NAMES.map { File(target, it) }
        val needsHeader = files.map { !it.exists() || it.length() == 0L }
        try {
            // Open everything before writing headers, so an open failure is retryable.
            files.forEach { file ->
                val raw = openStream(file)
                opened += Stream(raw, raw.bufferedWriter(Charsets.UTF_8))
            }
        } catch (error: Exception) {
            opened.forEach { try { it.raw.close() } catch (cleanup: Exception) { error.addSuppressed(cleanup) } }
            throw error
        }
        streams = opened
        val headers = listOf(
            "host_utc,heart_rate_bpm,rr_millis",
            "host_utc,polar_timestamp_ns,sample_index,ecg_mv",
            "host_utc,polar_timestamp_ns,sample_index,x_mg,y_mg,z_mg",
        )
        streams.toList().forEachIndexed { index, stream ->
            if (needsHeader[index]) write(stream) { appendLine(headers[index]) }
        }
        return true
    }

    private inline fun write(stream: Stream, block: BufferedWriter.() -> Unit) {
        try { stream.writer.block() } catch (error: Exception) { fail(error, stream) }
    }

    @Synchronized
    fun append(frame: PolarHeartRateFrame, nowMillis: Long) {
        checkFailure()
        val stream = streams.getOrNull(0) ?: return
        val timestamp = Instant.ofEpochMilli(nowMillis)
        write(stream) {
            if (frame.rrMillis.isEmpty()) appendLine("$timestamp,${frame.beatsPerMinute},")
            else frame.rrMillis.forEach { rr -> appendLine("$timestamp,${frame.beatsPerMinute},$rr") }
        }
    }

    @Synchronized
    fun append(frame: PolarEcgFrame, nowMillis: Long) {
        checkFailure()
        val stream = streams.getOrNull(1) ?: return
        val timestamp = Instant.ofEpochMilli(nowMillis)
        write(stream) {
            frame.samplesMicrovolts.forEachIndexed { index, sample ->
                appendLine("$timestamp,${frame.timestampNanos},$index,${sample / 1_000.0}")
            }
        }
    }

    @Synchronized
    fun append(frame: PolarAccelerationFrame, nowMillis: Long) {
        checkFailure()
        val stream = streams.getOrNull(2) ?: return
        val timestamp = Instant.ofEpochMilli(nowMillis)
        write(stream) {
            frame.samples.forEachIndexed { index, sample ->
                appendLine("$timestamp,${frame.timestampNanos},$index,${sample.xMilliG},${sample.yMilliG},${sample.zMilliG}")
            }
        }
    }

    @Synchronized
    fun flush() {
        checkFailure()
        streams.toList().forEach { stream -> write(stream) { flush() } }
    }

    @Synchronized
    override fun close() {
        checkFailure()
        // Remove successfully closed streams, so cleanup never closes them twice.
        while (streams.isNotEmpty()) {
            val stream = streams.first()
            try {
                // Do not enter BufferedWriter.close() with unwritten buffered
                // data: its own cleanup could retry a partially failed flush.
                stream.writer.flush()
                stream.writer.close()
            } catch (error: Exception) { fail(error, stream) }
            streams = streams.drop(1)
        }
    }

    companion object {
        const val POLAR_HR_FILE = "polar_hr.csv"
        const val POLAR_ECG_FILE = "polar_ecg.csv"
        const val POLAR_ACC_FILE = "polar_acc.csv"
        val FILE_NAMES = listOf(POLAR_HR_FILE, POLAR_ECG_FILE, POLAR_ACC_FILE)
    }
}
