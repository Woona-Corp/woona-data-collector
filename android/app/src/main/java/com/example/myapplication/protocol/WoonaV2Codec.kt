package com.example.myapplication.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.zip.CRC32

/** Pure, Android-independent Woona V2 framing. Legacy uses its own PacketAssembler. */
data class V2Frame(val type: Int, val flags: Int, val sequence: Long, val requestId: Long, val payload: ByteArray)
data class V2Hello(val versionMin: Int, val versionMax: Int, val capabilities: Long, val streamMask: Long, val maxPayload: Int) {
    fun hasCapability(bit: Int): Boolean = bit in 0..31 && (capabilities and (1L shl bit)) != 0L
}
data class V2Stream(val id: Int, val format: Int, val channels: Int, val nativeRateHz: Long)
data class V2Streams(val status: Int, val streamMask: Long, val descriptors: List<V2Stream>)
data class V2Error(val status: Int, val offendingType: Int)
data class V2LiveData(val sessionId: Long, val streamId: Int, val flags: Int, val count: Int,
                      val rateHz: Int, val streamSequence: Long, val timestampUs: Long, val samples: ByteArray)

object WoonaV2Codec {
    const val MAX_PAYLOAD = 2048
    const val HEADER_SIZE = 20
    const val MAX_RAW = HEADER_SIZE + MAX_PAYLOAD + 4
    const val MAX_ENCODED = MAX_RAW + MAX_RAW / 254 + 1
    const val HELLO = 0x01
    const val GET_STREAMS = 0x02
    const val GET_STATUS = 0x03
    const val START_SESSION = 0x04
    const val STOP_SESSION = 0x05
    const val GET_STORED_SESSIONS = 0x07
    const val GET_STORED_SESSION_INFO = 0x08
    const val START_STORED_TRANSFER = 0x09
    const val STOP_STORED_TRANSFER = 0x0A
    const val CONFIRM_STORED_SESSION = 0x0B
    const val DATA = 0x40
    const val STORED_DATA = 0x41
    const val STORED_TRANSFER_END = 0x42
    const val HELLO_RESPONSE = 0x81
    const val STREAMS_RESPONSE = 0x82
    const val ERROR_RESPONSE = 0xff
    private const val U32_MAX = 0xffff_ffffL
    private val MAGIC = byteArrayOf(0x57, 0x4e, 0x41, 0x32)
    private fun u8(v: Byte): Int = v.toInt() and 255
    private fun le(b: ByteArray) = ByteBuffer.wrap(b).order(ByteOrder.LITTLE_ENDIAN)
    private fun crc(b: ByteArray, length: Int): Long = CRC32().apply { update(b, 0, length) }.value

    fun encodeRaw(type: Int, sequence: Long, requestId: Long, payload: ByteArray = byteArrayOf(), flags: Int = 0): ByteArray {
        require(type in 0..255 && flags in 0..255 && sequence in 0..U32_MAX && requestId in 0..U32_MAX)
        require(payload.size <= MAX_PAYLOAD)
        val buf = ByteBuffer.allocate(HEADER_SIZE + payload.size + 4).order(ByteOrder.LITTLE_ENDIAN)
        buf.put(MAGIC).put(2).put(type.toByte()).put(flags.toByte()).put(HEADER_SIZE.toByte())
            .putShort(payload.size.toShort()).putShort(0).putInt(sequence.toInt()).putInt(requestId.toInt()).put(payload)
        buf.putInt(crc(buf.array(), HEADER_SIZE + payload.size).toInt())
        return buf.array()
    }

    fun decodeRaw(b: ByteArray): V2Frame? {
        if (b.size !in 24..MAX_RAW || !b.copyOfRange(0, 4).contentEquals(MAGIC) || u8(b[4]) != 2 || u8(b[7]) != 20) return null
        val v = le(b)
        val size = v.getShort(8).toInt() and 0xffff
        if (size > MAX_PAYLOAD || size + 24 != b.size || v.getShort(10).toInt() != 0) return null
        if ((v.getInt(20 + size).toLong() and U32_MAX) != crc(b, 20 + size)) return null
        return V2Frame(u8(b[5]), u8(b[6]), v.getInt(12).toLong() and U32_MAX,
            v.getInt(16).toLong() and U32_MAX, b.copyOfRange(20, 20 + size))
    }

    fun encodeWire(type: Int, sequence: Long, requestId: Long, payload: ByteArray = byteArrayOf()): ByteArray =
        cobsEncode(encodeRaw(type, sequence, requestId, payload)) + byteArrayOf(0)

    fun cobsEncode(raw: ByteArray): ByteArray {
        require(raw.size <= MAX_RAW) { "V2 COBS input exceeds the maximum frame size" }
        val dst = ByteArray(raw.size + raw.size / 254 + 2)
        var codePosition = 0; var next = 1; var code = 1
        for (value in raw) {
            if (value == 0.toByte()) { dst[codePosition] = code.toByte(); codePosition = next++; code = 1 }
            else {
                dst[next++] = value
                code++
                if (code == 255) { dst[codePosition] = 255.toByte(); codePosition = next++; code = 1 }
            }
        }
        dst[codePosition] = code.toByte()
        return dst.copyOf(next)
    }

    fun cobsDecode(encoded: ByteArray): ByteArray? {
        if (encoded.isEmpty() || encoded.size > MAX_ENCODED) return null
        val dst = ByteArray(encoded.size)
        var i = 0; var output = 0
        while (i < encoded.size) {
            val code = u8(encoded[i++])
            if (code == 0 || code - 1 > encoded.size - i) return null
            repeat(code - 1) {
                val value = encoded[i++]
                if (value == 0.toByte()) return null
                dst[output++] = value
            }
            if (code != 255 && i < encoded.size) dst[output++] = 0
        }
        return if (output <= MAX_RAW) dst.copyOf(output) else null
    }

    fun hello(frame: V2Frame): V2Hello? {
        if (frame.type != HELLO_RESPONSE || frame.payload.size != 16) return null
        val b = frame.payload; val v = le(b)
        if (v.getShort(2).toInt() != 0 || v.getShort(14).toInt() != 0) return null
        return V2Hello(u8(b[0]), u8(b[1]), v.getInt(4).toLong() and U32_MAX,
            v.getInt(8).toLong() and U32_MAX, v.getShort(12).toInt() and 0xffff)
    }

    fun streams(frame: V2Frame): V2Streams? {
        val b = frame.payload
        if (frame.type != STREAMS_RESPONSE || b.size < 8 || u8(b[2]) != 8 || b[3] != 0.toByte()) return null
        val count = u8(b[1]); if (count > 32 || b.size != 8 + count * 8) return null
        val v = le(b); val list = mutableListOf<V2Stream>()
        for (i in 0 until count) {
            val off = 8 + i * 8
            if (b[off + 3] != 0.toByte()) return null
            list += V2Stream(u8(b[off]), u8(b[off + 1]), u8(b[off + 2]), v.getInt(off + 4).toLong() and U32_MAX)
        }
        val parsed = V2Streams(u8(b[0]), v.getInt(4).toLong() and U32_MAX, list)
        return parsed.takeIf { it.status != 0 || validStreams(it) }
    }

    /** A descriptor is not usable merely because its bytes fit in the frame. */
    fun validStreams(streams: V2Streams): Boolean {
        if (streams.status != 0 || streams.streamMask !in 1..U32_MAX ||
            streams.descriptors.size !in 1..32) return false
        var mask = 0L
        for (stream in streams.descriptors) {
            if (stream.id !in 1..32 || stream.format !in 1..2 ||
                stream.channels !in 1..16 || stream.nativeRateHz !in 1..U32_MAX) return false
            // These identities have a defined sample layout in firmware data_block.c.
            if (stream.id in 1..7 && (stream.format != (if (stream.id == 5) 2 else 1) ||
                stream.channels != (if (stream.id <= 2) 3 else 1))) return false
            val bit = 1L shl (stream.id - 1)
            if (mask and bit != 0L) return false
            mask = mask or bit
        }
        return mask == streams.streamMask
    }

    fun error(frame: V2Frame): V2Error? {
        val p = frame.payload
        if (frame.type != ERROR_RESPONSE || p.size != 4 || p[2] != 0.toByte() || p[3] != 0.toByte()) return null
        return V2Error(u8(p[0]), u8(p[1]))
    }

    fun statusDescription(status: Int): String = when (status) {
        0 -> "ok"
        1 -> "invalid message"
        2 -> "invalid argument"
        3 -> "unsupported stream"
        4 -> "device busy; preserve its active session"
        5 -> "no recording sink available"
        6 -> "invalid device state"
        7 -> "invalid session"
        8 -> "device internal error"
        9 -> "request ID conflicts with a cached command"
        10 -> "request ID expired; reconcile device state before another action"
        11 -> "not found"
        12 -> "device storage error"
        else -> "unknown device status"
    }

    /** Keep sample bytes intact until format and channel count are known from GET_STREAMS. */
    fun liveData(frame: V2Frame): V2LiveData? {
        val b = frame.payload
        if (frame.type != DATA || b.size !in 24..MAX_PAYLOAD || b[5] != 0.toByte()) return null
        val v = le(b)
        return V2LiveData(v.getInt(0).toLong() and U32_MAX, u8(b[4]),
            v.getShort(6).toInt() and 0xffff, v.getShort(8).toInt() and 0xffff,
            v.getShort(10).toInt() and 0xffff, v.getInt(12).toLong() and U32_MAX,
            v.getLong(16), b.copyOfRange(24, b.size))
    }
}

/** A dedicated V2 stream assembler; never feed Legacy notifications into this object. */
class WoonaV2StreamDecoder {
    private val pending = ArrayList<Byte>()
    private var discardUntilDelimiter = false
    /** A corrupt oversized COBS segment is discarded until the next 0x00 boundary. */
    fun reset() { pending.clear(); discardUntilDelimiter = false }
    fun append(bytes: ByteArray): List<V2Frame> {
        val frames = mutableListOf<V2Frame>()
        for (value in bytes) {
            if (value == 0.toByte()) {
                if (!discardUntilDelimiter && pending.isNotEmpty()) {
                    val raw = WoonaV2Codec.cobsDecode(pending.toByteArray())
                    if (raw != null) WoonaV2Codec.decodeRaw(raw)?.let(frames::add)
                }
                pending.clear(); discardUntilDelimiter = false
            } else if (!discardUntilDelimiter) {
                if (pending.size >= WoonaV2Codec.MAX_ENCODED) {
                    pending.clear(); discardUntilDelimiter = true
                } else pending.add(value)
            }
        }
        return frames
    }
}
