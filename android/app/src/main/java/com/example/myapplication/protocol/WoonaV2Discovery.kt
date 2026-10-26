package com.example.myapplication.protocol

/**
 * Discovery is deliberately opt-in: the firmware stops its Legacy stream after a valid HELLO.
 * Wire writes and BLE callbacks belong to ble/, this state machine has no Android dependencies.
 *
 * Use one instance per connection. Do NOT fall back to Legacy after a successful HELLO unless
 * the device is disconnected first, because the firmware has already switched protocols.
 */
class WoonaV2Discovery {
    enum class Phase { IDLE, WAIT_HELLO, WAIT_STREAMS, WAIT_STATUS, READY, FAILED }

    sealed interface Event {
        /** Write exactly these bytes on FFF2, in order, before sending another command. */
        class Transmit(val bytes: ByteArray) : Event
        class Complete(val device: Device) : Event
        class Failure(val reason: String) : Event
    }

    data class Status(
        val sessionMode: Int,
        val sessionId: Long,
        val activeStreamMask: Long,
        val supportedStreamMask: Long,
        val batteryPercent: Int?,
    )

    data class Device(val hello: V2Hello, val streams: V2Streams, val status: Status)

    var phase = Phase.IDLE
        private set

    private val receiver = WoonaV2StreamDecoder()
    private var nextSequence = 1L
    private var nextRequestId = 1L
    private var pendingRequestId = 0L
    private var pendingWire = ByteArray(0)
    private var retries = 0
    private var hello: V2Hello? = null
    private var streams: V2Streams? = null

    /** Begin explicit negotiation only after CCCD notification registration succeeds. */
    fun begin(): Event.Transmit {
        require(phase == Phase.IDLE) { "A V2 connection may only negotiate once" }
        receiver.reset()
        nextSequence = 1L
        nextRequestId = 1L
        hello = null
        streams = null
        phase = Phase.WAIT_HELLO
        return command(WoonaV2Codec.HELLO)
    }

    /** Concatenate BLE notifications as a byte stream, never as individual V2 packets. */
    fun receive(bytes: ByteArray): List<Event> {
        if (phase == Phase.IDLE || phase == Phase.READY || phase == Phase.FAILED) return emptyList()
        val events = mutableListOf<Event>()
        for (frame in receiver.append(bytes)) {
            // Reject stale, unsolicited and other-command frames during handshake.
            if (frame.requestId != pendingRequestId) continue
            when (phase) {
                Phase.WAIT_HELLO -> {
                    val info = WoonaV2Codec.hello(frame) ?: continue
                    if (info.versionMin > 2 || info.versionMax < 2 || info.maxPayload < 24) {
                        phase = Phase.FAILED
                        events += Event.Failure("Unsupported V2 version or payload limit")
                    } else {
                        hello = info
                        phase = Phase.WAIT_STREAMS
                        events += command(WoonaV2Codec.GET_STREAMS)
                    }
                }
                Phase.WAIT_STREAMS -> {
                    val info = WoonaV2Codec.streams(frame) ?: continue
                    if (info.status != 0) {
                        phase = Phase.FAILED
                        events += Event.Failure("GET_STREAMS rejected with status ${info.status}")
                    } else {
                        streams = info
                        phase = Phase.WAIT_STATUS
                        events += command(WoonaV2Codec.GET_STATUS)
                    }
                }
                Phase.WAIT_STATUS -> {
                    val status = status(frame) ?: continue
                    val h = hello ?: continue
                    val s = streams ?: continue
                    phase = Phase.READY
                    pendingWire = ByteArray(0)
                    events += Event.Complete(Device(h, s, status))
                }
                else -> Unit
            }
        }
        return events
    }

    /** Call when a command response times out. Retry the byte-identical command at most twice. */
    fun onResponseTimeout(): Event {
        require(phase == Phase.WAIT_HELLO || phase == Phase.WAIT_STREAMS || phase == Phase.WAIT_STATUS)
        return if (++retries <= 2) {
            Event.Transmit(pendingWire.clone())
        } else {
            phase = Phase.FAILED
            Event.Failure("V2 discovery response timed out")
        }
    }

    fun resetForNewConnection() {
        receiver.reset()
        phase = Phase.IDLE
        hello = null
        streams = null
        pendingWire = ByteArray(0)
        pendingRequestId = 0L
        retries = 0
    }

    private fun command(type: Int): Event.Transmit {
        check(nextSequence <= 0xffff_ffffL && nextRequestId <= 0xffff_ffffL)
        pendingRequestId = nextRequestId++
        pendingWire = WoonaV2Codec.encodeWire(type, nextSequence++, pendingRequestId)
        retries = 0
        return Event.Transmit(pendingWire.clone())
    }

    private fun status(frame: V2Frame): Status? {
        if (frame.type != 0x83 || frame.payload.size !in listOf(36, 48)) return null
        val p = frame.payload
        if (p[0] != 0.toByte() || p[1] != 1.toByte()) return null
        fun u32(offset: Int): Long = (0..3).fold(0L) { acc, i ->
            acc or ((p[offset + i].toLong() and 0xffL) shl (i * 8))
        }
        return Status(
            sessionMode = p[2].toInt() and 0xff,
            sessionId = u32(4),
            activeStreamMask = u32(8),
            supportedStreamMask = u32(12),
            batteryPercent = (p[32].toInt() and 0xff).let { if (it <= 100) it else null },
        )
    }
}
