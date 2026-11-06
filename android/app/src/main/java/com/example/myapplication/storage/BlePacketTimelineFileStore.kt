package com.example.myapplication.storage

import java.io.BufferedOutputStream
import java.io.DataOutputStream
import java.io.DataInputStream
import java.io.File
import java.io.FileOutputStream

class BlePacketTimelineFileStore(
    private var directory: File,
) {
    private val lock = Any()
    private var currentFile: File? = null
    private var output: DataOutputStream? = null
    private var isClosed = false

    fun append(
        sequence: Long,
        counter: Long,
        deviceTimerMillis: Long,
        hostWallClockMillis: Long,
        hostMonotonicNs: Long,
        packetBytes: Int,
    ) = synchronized(lock) {
        check(!isClosed)
        val stream = ensureOpen()
        stream.writeLong(sequence)
        stream.writeLong(counter)
        stream.writeLong(deviceTimerMillis)
        stream.writeLong(hostWallClockMillis)
        stream.writeLong(hostMonotonicNs)
        stream.writeInt(packetBytes)
    }

    fun useSessionDirectory(value: File) = synchronized(lock) {
        resetLocked()
        directory = value
    }

    fun resetSession() = synchronized(lock) { resetLocked() }

    fun flush() = synchronized(lock) {
        check(!isClosed)
        output?.flush()
    }

    fun currentFile(): File? = synchronized(lock) { currentFile }

    fun close() = synchronized(lock) {
        if (isClosed) return@synchronized
        output?.close()
        output = null
        isClosed = true
    }

    private fun resetLocked() {
        check(!isClosed)
        output?.close()
        output = null
        currentFile = null
    }

    private fun ensureOpen(): DataOutputStream {
        output?.let { return it }
        directory.mkdirs()
        val file = File(directory, "packet_timeline.bin")
        val stream = DataOutputStream(
            BufferedOutputStream(FileOutputStream(file, false), BUFFER_SIZE_BYTES),
        )
        stream.write(MAGIC)
        currentFile = file
        output = stream
        return stream
    }

    private companion object {
        val MAGIC = "BLETIME1".toByteArray(Charsets.US_ASCII)
        const val BUFFER_SIZE_BYTES = 65_536
    }
}

data class PacketTimelineEntry(
    val sequence: Long,
    val counter: Long,
    val deviceTimerMillis: Long,
    val hostWallClockMillis: Long,
    val hostMonotonicNs: Long,
    val packetBytes: Int,
)

class BlePacketTimelineReader(file: File) : AutoCloseable {
    private val input = DataInputStream(file.inputStream().buffered()).apply {
        val magic = ByteArray(8).also(::readFully)
        require(magic.contentEquals("BLETIME1".toByteArray(Charsets.US_ASCII))) {
            "Invalid packet timeline"
        }
    }

    fun next(): PacketTimelineEntry? {
        // Only EOF before the first byte is a clean end. Every remaining field
        // must be present; DataInputStream propagates EOFException for torn rows.
        val firstByte = input.read()
        if (firstByte < 0) return null
        var sequence = firstByte.toLong()
        repeat(7) { sequence = (sequence shl 8) or input.readUnsignedByte().toLong() }
        return PacketTimelineEntry(
            sequence = sequence,
            counter = input.readLong(),
            deviceTimerMillis = input.readLong(),
            hostWallClockMillis = input.readLong(),
            hostMonotonicNs = input.readLong(),
            packetBytes = input.readInt(),
        )
    }

    override fun close() = input.close()
}
