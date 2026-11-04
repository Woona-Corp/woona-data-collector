package com.example.myapplication.protocol

import java.io.ByteArrayInputStream
import java.io.DataInputStream
import java.io.BufferedInputStream
import java.io.EOFException
import java.io.File
import java.io.FileInputStream
import java.io.InputStream

class RecordedPacketFileParser {
    fun splitIntoPackets(fileBytes: ByteArray): List<ByteArray> {
        if (fileBytes.isEmpty()) return emptyList()

        val packets = mutableListOf<ByteArray>()
        forEachPacket(fileBytes) { packetBytes ->
            packets += packetBytes
        }

        return packets
    }

    fun forEachPacket(
        fileBytes: ByteArray,
        onPacket: (ByteArray) -> Unit,
    ) {
        ByteArrayInputStream(fileBytes).use { input -> forEachPacket(input, onPacket) }
    }

    fun forEachPacket(
        packetFile: File,
        onPacket: (ByteArray) -> Unit,
    ) {
        if (!packetFile.exists() || packetFile.length() == 0L) return

        BufferedInputStream(FileInputStream(packetFile), FILE_BUFFER_SIZE_BYTES).use { inputStream ->
            forEachPacket(inputStream, onPacket)
        }
    }

    fun forEachPacket(
        inputStream: InputStream,
        onPacket: (ByteArray) -> Unit,
    ) {
        val input = DataInputStream(inputStream)
        var offset = 0L

        while (true) {
            val first = input.read()
            if (first == -1) return
            val header = ByteArray(MIN_PACKET_SIZE)
            header[0] = first.toByte()
            try {
                input.readFully(header, 1, MIN_PACKET_SIZE - 1)
            } catch (_: EOFException) {
                throw IllegalArgumentException("Truncated packet header at offset $offset")
            }

            if (!hasStartMarker(header, 0)) {
                throw IllegalArgumentException("Invalid packet start marker at offset $offset")
            }

            val packetLength = decodeLength(header, 0)
            if (packetLength < MIN_PACKET_SIZE) {
                throw IllegalArgumentException("Invalid packet length $packetLength at offset $offset")
            }

            val packetBytes = ByteArray(packetLength)
            System.arraycopy(header, 0, packetBytes, 0, MIN_PACKET_SIZE)

            val remainingBytes = packetLength - MIN_PACKET_SIZE
            if (remainingBytes > 0) {
                try {
                    input.readFully(packetBytes, MIN_PACKET_SIZE, remainingBytes)
                } catch (_: EOFException) {
                    throw IllegalArgumentException(
                        "Truncated packet body at offset $offset: expected $packetLength bytes",
                    )
                }
            }

            onPacket(packetBytes)
            offset += packetLength.toLong()
        }
    }

    private fun hasStartMarker(packetBytes: ByteArray, offset: Int): Boolean {
        return packetBytes[offset] == 0x33.toByte() &&
            packetBytes[offset + 1] == 0x99.toByte() &&
            packetBytes[offset + 2] == 0xAA.toByte() &&
            packetBytes[offset + 3] == 0x55.toByte()
    }

    private fun decodeLength(packetBytes: ByteArray, offset: Int): Int {
        return (packetBytes[offset + LENGTH_OFFSET].toInt() and 0xFF) or
            ((packetBytes[offset + LENGTH_OFFSET + 1].toInt() and 0xFF) shl 8)
    }

    private companion object {
        const val LENGTH_OFFSET = 4
        const val MIN_PACKET_SIZE = 16
        const val FILE_BUFFER_SIZE_BYTES = 65_536
    }
}
