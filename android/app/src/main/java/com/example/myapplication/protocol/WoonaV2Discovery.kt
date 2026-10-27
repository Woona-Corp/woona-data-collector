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
        class Failure(val reason: String, val busySessionMode: Int? = null) : Event
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
    val rejectedFrames: Long get() = receiver.rejectedFrames
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
            val error = WoonaV2Codec.error(frame)
            val expectedType = when (phase) {
                Phase.WAIT_HELLO -> WoonaV2Codec.HELLO
                Phase.WAIT_STREAMS -> WoonaV2Codec.GET_STREAMS
                Phase.WAIT_STATUS -> WoonaV2Codec.GET_STATUS
                else -> 0
            }
            if (error != null && error.offendingType == expectedType) {
                events += fail("V2 command 0x${expectedType.toString(16)} rejected: status=${error.status} (${WoonaV2Codec.statusDescription(error.status)})")
                break
            }
            when (phase) {
                Phase.WAIT_HELLO -> {
                    if (frame.type != WoonaV2Codec.HELLO_RESPONSE) continue
                    val info = WoonaV2Codec.hello(frame)
                    if (info == null || info.versionMin > 2 || info.versionMax < 2 ||
                        info.versionMin > info.versionMax || info.maxPayload !in 36..WoonaV2Codec.MAX_PAYLOAD || info.streamMask == 0L) {
                        events += fail("Unsupported V2 version, stream mask or payload limit")
                    } else if (!listOf(0, 2, 3, 4, 5).all(info::hasCapability)) {
                        events += fail("V2 LIVE preview requires LIVE, stream info, status, session control and command replay capabilities")
                    } else {
                        hello = info
                        phase = Phase.WAIT_STREAMS
                        events += command(WoonaV2Codec.GET_STREAMS)
                    }
                }
                Phase.WAIT_STREAMS -> {
                    if (frame.type != WoonaV2Codec.STREAMS_RESPONSE) continue
                    val info = WoonaV2Codec.streams(frame)
                    if (info == null || info.status != 0 || info.streamMask != hello?.streamMask) {
                        events += fail("GET_STREAMS rejected or inconsistent descriptors/mask: status=${info?.status}")
                    } else {
                        streams = info
                        phase = Phase.WAIT_STATUS
                        events += command(WoonaV2Codec.GET_STATUS)
                    }
                }
                Phase.WAIT_STATUS -> {
                    if (frame.type != 0x83) continue
                    if (frame.payload.isNotEmpty() && frame.payload[0] != 0.toByte()) {
                        val code = frame.payload[0].toInt() and 255
                        events += fail("GET_STATUS rejected: status=$code (${WoonaV2Codec.statusDescription(code)})")
                        continue
                    }
                    val status = status(frame)
                    if (status == null) {
                        events += fail("Malformed V2 STATUS_RESPONSE")
                        continue
                    }
                    val h = hello ?: continue
                    val s = streams ?: continue
                    if (status.supportedStreamMask != s.streamMask ||
                        (status.activeStreamMask and s.streamMask) != status.activeStreamMask) {
                        events += fail("V2 status stream masks disagree with discovery")
                        continue
                    }
                    if (status.sessionMode != 0 || status.sessionId != 0L) {
                        events += fail("V2 device is busy with ${if (status.sessionMode == 2) "STORAGE" else "LIVE"} session ${status.sessionId}; preserve the active session", status.sessionMode)
                        continue
                    }
                    if (frame.payload.size == 48 && frame.payload[36] != 0.toByte()) {
                        events += fail("V2 measurement is not idle: phase=${frame.payload[36].toInt() and 255}; preserve the current connection and device state")
                        continue
                    }
                    phase = Phase.READY
                    pendingRequestId = 0
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
        if (p[0] != 0.toByte() || p[1] != 1.toByte() || p[2].toInt() !in 0..2 ||
            p[3] != 1.toByte() || (33..35).any { p[it] != 0.toByte() } ||
            (p.size == 48 && p[36].toInt() !in 0..4)) return null
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

    private fun fail(reason: String, busySessionMode: Int? = null): Event.Failure {
        phase = Phase.FAILED
        pendingRequestId = 0
        pendingWire = ByteArray(0)
        return Event.Failure(reason, busySessionMode)
    }
}
