package com.example.myapplication.ble

import java.util.concurrent.atomic.AtomicReference

// Ownership, connection generation and capture ID are published atomically.
// A GATT identity (never equals()) decides which connection may mutate state;
// the generation decides whether an event created before a reconnect may be
// applied after it.
internal data class PolarCaptureSnapshot<T : Any>(
    val gatt: T?,
    val generation: Long,
    val recordingId: String?,
    // A live GATT is never rebound to a different recording. A reconnect
    // establishes the transport boundary before another capture can start.
    val boundRecordingId: String?,
)

internal class PolarCaptureGate<T : Any> {
    private val state = AtomicReference(PolarCaptureSnapshot<T>(null, 0L, null, null))

    fun owner(): T? = state.get().gatt

    fun snapshot(): PolarCaptureSnapshot<T> = state.get()

    fun replaceOwner(gatt: T?, generation: Long) {
        state.set(PolarCaptureSnapshot(gatt, generation, null, null))
    }

    fun clearOwner(gatt: T): Boolean {
        while (true) {
            val old = state.get()
            if (old.gatt !== gatt) return false
            // Keep the generation monotonic: a stale callback captured before
            // this clear must never look current again.
            if (state.compareAndSet(old, PolarCaptureSnapshot(null, old.generation, null, null))) return true
        }
    }

    fun beginRecording(recordingId: String): Boolean {
        val owner = state.get().gatt ?: return false
        while (true) {
            val old = state.get()
            if (old.gatt !== owner) return false
            if (old.boundRecordingId != null) {
                if (old.recordingId != recordingId) return false
                if (state.compareAndSet(old, old)) return true
                continue
            }
            if (state.compareAndSet(old, old.copy(recordingId = recordingId, boundRecordingId = recordingId))) return true
        }
    }

    fun endRecording(recordingId: String): Boolean {
        val owner = state.get().gatt ?: return false
        while (true) {
            val old = state.get()
            if (old.gatt !== owner || old.recordingId != recordingId) return false
            if (state.compareAndSet(old, old.copy(recordingId = null))) return true
        }
    }

    fun snapshot(gatt: T): PolarCaptureSnapshot<T>? = state.get().takeIf { it.gatt === gatt }
}

internal fun <T : Any> isCurrentPolarGatt(current: T?, callback: T): Boolean = current === callback
