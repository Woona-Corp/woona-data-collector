package com.example.myapplication.ble

import org.junit.Assert.assertEquals
import org.junit.Test

class BleDisconnectActionTest {
    @Test fun disconnectDuringCaptureRecoversInsteadOfFinalizingRecording() {
        assertEquals(BleDisconnectAction.RECOVER, bleDisconnectAction(false, false, true))
    }
    @Test fun manualStopWinsOverCaptureAndPendingRecovery() {
        assertEquals(BleDisconnectAction.DISCONNECTED, bleDisconnectAction(true, true, true))
        assertEquals(BleDisconnectAction.DISCONNECTED, bleDisconnectAction(true, false, true))
    }
    @Test fun failedRecoveryContinuesExistingBudgetRatherThanRestartingIt() {
        assertEquals(BleDisconnectAction.RETRY, bleDisconnectAction(false, true, true))
    }
    @Test fun setupErrorWithoutCaptureIsReportedImmediately() {
        assertEquals(BleDisconnectAction.FAIL, bleDisconnectAction(false, false, false))
    }
}
