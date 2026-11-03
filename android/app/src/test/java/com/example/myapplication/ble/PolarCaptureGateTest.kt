package com.example.myapplication.ble

import org.junit.Assert.*
import org.junit.Test

class PolarCaptureGateTest {
    private data class Gatt(val address: String)

    @Test fun snapshotRemainsBoundToOldRecordingAndGattAcrossReplacement() {
        val gate = PolarCaptureGate<Gatt>()
        val old = Gatt("same")
        val fresh = Gatt("same")
        gate.replaceOwner(old, 1L)
        assertTrue(gate.beginRecording("recording-1"))
        val inFlight = gate.snapshot(old)!!
        gate.replaceOwner(fresh, 2L)
        assertTrue(gate.beginRecording("recording-2"))
        assertEquals("recording-1", inFlight.recordingId)
        assertSame(old, inFlight.gatt)
        assertNull(gate.snapshot(old))
        assertEquals("recording-2", gate.snapshot(fresh)!!.recordingId)
        assertFalse(gate.clearOwner(old))
        assertEquals("recording-2", gate.snapshot(fresh)!!.recordingId)
    }

    @Test fun recordingStopRequiresFreshGattForAnotherCapture() {
        val gate = PolarCaptureGate<Gatt>()
        val old = Gatt("device")
        val fresh = Gatt("device")
        gate.replaceOwner(old, 1L)
        assertTrue(gate.beginRecording("first"))
        val inFlight = gate.snapshot(old)!!
        assertFalse("An unrelated stop must not clear the current owner", gate.endRecording("second"))
        assertTrue(gate.endRecording("first"))
        assertFalse("A stopped GATT cannot start a second recording", gate.beginRecording("second"))
        assertFalse("A late start cannot reopen the old recording", gate.beginRecording("first"))
        assertEquals("first", inFlight.recordingId)
        assertNull(gate.snapshot(old)!!.recordingId)
        assertTrue(gate.clearOwner(old))
        assertFalse(gate.beginRecording("no-owner"))
        gate.replaceOwner(fresh, 2L)
        assertTrue(gate.beginRecording("second"))
        assertFalse("A late stop from the old recording must not stop the new one", gate.endRecording("first"))
        assertEquals("second", gate.snapshot(fresh)!!.recordingId)
        assertNull(gate.snapshot(old))
    }

    @Test fun replacementAndClearingAlwaysAdvanceTheGeneration() {
        val gate = PolarCaptureGate<Gatt>()
        val old = Gatt("same address")
        gate.replaceOwner(old, 1L)
        val oldSnapshot = gate.snapshot(old)!!
        gate.replaceOwner(Gatt("same address"), 2L)
        assertNotEquals("A stale frame keeps its own generation", 2L, oldSnapshot.generation)
        assertTrue(gate.clearOwner(gate.owner()!!))
        assertEquals("Clearing keeps the generation monotonic", 2L, gate.snapshot().generation)
        assertNull(gate.snapshot().gatt)
        assertNull(gate.snapshot(old))
    }

    @Test fun clearedGenerationNeverLooksCurrentAgain() {
        val gate = PolarCaptureGate<Gatt>()
        val gatt = Gatt("device")
        gate.replaceOwner(gatt, 7L)
        val beforeDisconnect = gate.snapshot(gatt)!!
        gate.clearOwner(gatt)
        // Nothing may revive the cleared generation, even for the same instance.
        assertNull(gate.snapshot(gatt))
        assertEquals(7L, beforeDisconnect.generation)
        assertEquals(7L, gate.snapshot().generation)
        gate.replaceOwner(gatt, 8L)
        assertEquals(8L, gate.snapshot(gatt)!!.generation)
        assertNotEquals(beforeDisconnect.generation, gate.snapshot(gatt)!!.generation)
    }
}
