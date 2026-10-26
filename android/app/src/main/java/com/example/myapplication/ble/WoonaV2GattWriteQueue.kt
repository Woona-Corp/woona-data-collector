package com.example.myapplication.ble

/**
 * Divides a COBS-framed command into ATT Write Request payloads. Never advance to the
 * next fragment before Android reports onCharacteristicWrite(GATT_SUCCESS).
 *
 * This queue does not write to a BluetoothGatt itself and is JVM-testable. It
 * deliberately requires acknowledged writes, not WRITE_TYPE_NO_RESPONSE.
 */
class WoonaV2GattWriteQueue {
    private var bytes: ByteArray? = null
    private var offset = 0
    private var pendingEnd = 0
    private var payloadLimit = 0

    val isBusy: Boolean get() = bytes != null

    /** Start one frame; [mtu] is the negotiated ATT MTU (default 23). */
    fun begin(frame: ByteArray, mtu: Int): ByteArray {
        require(!isBusy) { "A V2 GATT write is already in progress" }
        require(frame.isNotEmpty())
        require(mtu >= 23) { "Invalid ATT MTU" }
        bytes = frame.clone()
        offset = 0
        payloadLimit = mtu - 3
        return currentChunk()
    }

    /** Called exactly once for every successful onCharacteristicWrite callback. */
    fun acknowledgeChunk(): ByteArray? {
        check(isBusy) { "Unexpected GATT write callback" }
        offset = pendingEnd
        if (offset == requireNotNull(bytes).size) {
            reset()
            return null
        }
        return currentChunk()
    }

    fun reset() {
        bytes = null
        offset = 0
        pendingEnd = 0
        payloadLimit = 0
    }

    private fun currentChunk(): ByteArray {
        val wire = requireNotNull(bytes)
        pendingEnd = minOf(wire.size, offset + payloadLimit)
        return wire.copyOfRange(offset, pendingEnd)
    }
}
