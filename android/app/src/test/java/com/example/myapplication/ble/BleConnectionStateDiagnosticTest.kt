package com.example.myapplication.ble

import org.junit.Assert.assertEquals
import org.junit.Test

class BleConnectionStateDiagnosticTest {
    @Test
    fun gatt8ActiveCaptureLogsConnectionAndCaptureContext() {
        assertEquals(
            "GATT connection state: status=8, newState=0, captureActive=true, " +
                "recoveryInProgress=false, manualDisconnectRequested=false, currentGatt=true, " +
                "lateEvent=false, generation=7, activeGeneration=7",
            gattConnectionStateDiagnostic(
                status = 8,
                newState = 0,
                captureActive = true,
                recoveryInProgress = false,
                manualDisconnectRequested = false,
                currentGatt = true,
                generation = 7,
                activeGeneration = 7,
            ),
        )
    }

    @Test
    fun gatt8RecoveryLogsRecoveryContextBeforeGattStateIsCleared() {
        assertEquals(
            "GATT connection state: status=8, newState=0, captureActive=true, " +
                "recoveryInProgress=true, manualDisconnectRequested=false, currentGatt=true, " +
                "lateEvent=false, generation=8, activeGeneration=8",
            gattConnectionStateDiagnostic(
                status = 8,
                newState = 0,
                captureActive = true,
                recoveryInProgress = true,
                manualDisconnectRequested = false,
                currentGatt = true,
                generation = 8,
                activeGeneration = 8,
            ),
        )
    }

    @Test
    fun gatt8ManualDisconnectLogsManualContextBeforeGattStateIsCleared() {
        assertEquals(
            "GATT connection state: status=8, newState=0, captureActive=false, " +
                "recoveryInProgress=false, manualDisconnectRequested=true, currentGatt=true, " +
                "lateEvent=false, generation=9, activeGeneration=9",
            gattConnectionStateDiagnostic(
                status = 8,
                newState = 0,
                captureActive = false,
                recoveryInProgress = false,
                manualDisconnectRequested = true,
                currentGatt = true,
                generation = 9,
                activeGeneration = 9,
            ),
        )
    }

    @Test
    fun lateCallbackIsIdentifiedForOperationalLogAfterCaptureLogIsFrozen() {
        assertEquals(
            "GATT connection state: status=0, newState=2, captureActive=false, " +
                "recoveryInProgress=false, manualDisconnectRequested=true, currentGatt=false, " +
                "lateEvent=true, generation=?, activeGeneration=?",
            gattConnectionStateDiagnostic(
                status = 0,
                newState = 2,
                captureActive = false,
                recoveryInProgress = false,
                manualDisconnectRequested = true,
                currentGatt = false,
                generation = null,
                activeGeneration = null,
            ),
        )
    }
}
