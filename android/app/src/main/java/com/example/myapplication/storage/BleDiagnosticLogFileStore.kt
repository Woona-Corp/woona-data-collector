package com.example.myapplication.storage

import java.io.BufferedWriter
import java.io.File
import java.io.FileWriter

class BleDiagnosticLogFileStore(
    private var directory: File,
    private val filePrefix: String = DEFAULT_FILE_PREFIX,
    private val timestampProvider: () -> Long = { System.currentTimeMillis() },
) {
    private val lock = Any()
    private val operationalDirectory = directory
    private var sessionFinished = false
    private var currentFile: File? = null
    private var writer: BufferedWriter? = null
    private var isClosed = false
    private var sessionFileName: String? = null

    fun appendEvent(
        eventId: Long,
        type: String,
        message: String,
    ) {
        synchronized(lock) {
            check(!isClosed) { "Diagnostic log file store is closed" }
            val currentTimestamp = timestampProvider()
            ensureOpen().apply {
                append(currentTimestamp.toString())
                append('\t')
                append(eventId.toString())
                append('\t')
                append(type)
                append('\t')
                append(message)
                append('\n')
            }
        }
    }

    fun flush() {
        synchronized(lock) {
            check(!isClosed) { "Diagnostic log file store is closed" }
            writer?.flush()
        }
    }

    fun close() {
        synchronized(lock) {
            if (isClosed) return
            writer?.close()
            writer = null
            isClosed = true
        }
    }

    /** Freeze the capture artifact; later transport events belong to an operational log. */
    fun finishSession() {
        synchronized(lock) {
            check(!isClosed) { "Diagnostic log file store is closed" }
            if (sessionFinished) return
            writer?.close()
            writer = null
            sessionFinished = true
            directory = operationalDirectory
            sessionFileName = null
        }
    }

    fun resetSession() {
        synchronized(lock) {
            check(!isClosed) { "Diagnostic log file store is closed" }
            writer?.close()
            writer = null
            currentFile = null
            sessionFinished = false
        }
    }

    fun useSessionDirectory(directory: File) {
        synchronized(lock) {
            check(!isClosed) { "Diagnostic log file store is closed" }
            writer?.close()
            writer = null
            currentFile = null
            this.directory = directory
            sessionFinished = false
            sessionFileName = "diagnostics.log"
        }
    }

    fun currentFile(): File? = synchronized(lock) { currentFile }

    private fun ensureOpen(): BufferedWriter {
        check(!isClosed) { "Diagnostic log file store is closed" }
        if (writer == null) {
            directory.mkdirs()
            val file = if (sessionFinished) {
                File.createTempFile("$filePrefix${timestampProvider()}_", ".log", directory)
            } else {
                File(directory, sessionFileName ?: "$filePrefix${timestampProvider()}.log")
            }
            // Keep currentFile pointing at the frozen artifact for export/registration.
            if (!sessionFinished) currentFile = file
            writer = BufferedWriter(FileWriter(file, true), BUFFER_SIZE_BYTES)
        }
        return requireNotNull(writer)
    }

    private companion object {
        const val BUFFER_SIZE_BYTES = 65_536
        const val DEFAULT_FILE_PREFIX = "ble_log_"
    }
}
