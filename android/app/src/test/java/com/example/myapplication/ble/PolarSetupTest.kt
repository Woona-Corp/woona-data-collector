package com.example.myapplication.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The setup sequence must only advance for a callback that belongs to the step
 * it is answering. A callback from an unrelated characteristic, a duplicated
 * callback or a stale command must be ignored instead of skipping a step or
 * reporting READY for a connection whose streams never started.
 */
class PolarSetupTest {
    @Test fun servicesDiscoveredStartsHeartRateNotifications() {
        val transition = PolarSetup.start
        assertEquals(PolarSetupStep.HR_NOTIFY, transition.step)
        val operation = transition.operation as PolarSetupOperation.EnableNotifications
        assertEquals(PolarUuids.HR_CHARACTERISTIC, operation.characteristic)
        assertFalse(transition.ready)
    }

    @Test fun everyDescriptorStepRequiresItsOwnCharacteristic() {
        assertEquals(
            PolarSetupStep.PMD_DATA_NOTIFY,
            PolarSetup.onDescriptorWritten(PolarSetupStep.HR_NOTIFY, PolarUuids.HR_CHARACTERISTIC)!!.step,
        )
        assertNull(
            "A descriptor callback for another characteristic must not skip HR",
            PolarSetup.onDescriptorWritten(PolarSetupStep.HR_NOTIFY, PolarUuids.PMD_DATA),
        )
        assertEquals(
            PolarSetupStep.PMD_CONTROL_NOTIFY,
            PolarSetup.onDescriptorWritten(PolarSetupStep.PMD_DATA_NOTIFY, PolarUuids.PMD_DATA)!!.step,
        )
        assertNull(PolarSetup.onDescriptorWritten(PolarSetupStep.PMD_DATA_NOTIFY, PolarUuids.HR_CHARACTERISTIC))
        val battery = PolarSetup.onDescriptorWritten(PolarSetupStep.PMD_CONTROL_NOTIFY, PolarUuids.PMD_CONTROL)!!
        assertEquals(PolarSetupStep.BATTERY_READ, battery.step)
        assertTrue(battery.operation is PolarSetupOperation.ReadBattery)
    }

    @Test fun duplicatedDescriptorCallbackCannotAdvanceTwice() {
        val first = PolarSetup.onDescriptorWritten(PolarSetupStep.HR_NOTIFY, PolarUuids.HR_CHARACTERISTIC)!!
        assertEquals(PolarSetupStep.PMD_DATA_NOTIFY, first.step)
        // The same physical HR descriptor callback delivered twice must be
        // rejected against the advanced step.
        assertNull(PolarSetup.onDescriptorWritten(first.step, PolarUuids.HR_CHARACTERISTIC))
    }

    @Test fun batteryReadStartsEcgWithTheExactCommand() {
        val transition = PolarSetup.onBatteryRead(PolarSetupStep.BATTERY_READ, PolarUuids.BATTERY_CHARACTERISTIC)!!
        assertEquals(PolarSetupStep.START_ECG, transition.step)
        val write = transition.operation as PolarSetupOperation.WriteControl
        assertTrue(write.value.contentEquals(PolarUuids.START_ECG))
        assertNull(PolarSetup.onBatteryRead(PolarSetupStep.START_ECG, PolarUuids.BATTERY_CHARACTERISTIC))
        assertNull(PolarSetup.onBatteryRead(PolarSetupStep.BATTERY_READ, PolarUuids.HR_CHARACTERISTIC))
    }

    @Test fun ecgWriteSchedulesDelayedAccAndOnlyAccCompletesSetup() {
        val toAcc = PolarSetup.onControlWritten(PolarSetupStep.START_ECG, PolarUuids.PMD_CONTROL, PolarUuids.START_ECG)!!
        assertEquals(PolarSetupStep.START_ACC, toAcc.step)
        val delayed = toAcc.operation as PolarSetupOperation.WriteControl
        assertTrue(delayed.value.contentEquals(PolarUuids.START_ACC))
        assertTrue("ACC must not start in the same breath as ECG", delayed.delayMillis > 0)
        assertFalse(toAcc.ready)

        val ready = PolarSetup.onControlWritten(PolarSetupStep.START_ACC, PolarUuids.PMD_CONTROL, PolarUuids.START_ACC)!!
        assertEquals(PolarSetupStep.NONE, ready.step)
        assertTrue(ready.ready)
    }

    @Test fun duplicateCtrlWriteCallbackCannotReportReadyEarly() {
        // START_ECG is written, then its callback is delivered twice.
        val first = PolarSetup.onControlWritten(PolarSetupStep.START_ECG, PolarUuids.PMD_CONTROL, PolarUuids.START_ECG)!!
        assertEquals(PolarSetupStep.START_ACC, first.step)
        // The duplicate still carries the ECG command, so it must not be taken
        // as the ACC acknowledgement.
        assertNull(PolarSetup.onControlWritten(first.step, PolarUuids.PMD_CONTROL, PolarUuids.START_ECG))
        // A truncated or foreign write is equally unacceptable.
        assertNull(PolarSetup.onControlWritten(PolarSetupStep.START_ECG, PolarUuids.PMD_CONTROL, byteArrayOf(2, 0)))
        assertNull(PolarSetup.onControlWritten(PolarSetupStep.START_ECG, PolarUuids.PMD_DATA, PolarUuids.START_ECG))
    }

    @Test fun missingWrittenValueFallsBackToStepMatchingWithoutCrossingSteps() {
        val toAcc = PolarSetup.onControlWritten(PolarSetupStep.START_ECG, PolarUuids.PMD_CONTROL, null)
        assertNotNull("A cleared value must not stall setup forever", toAcc)
        assertEquals(PolarSetupStep.START_ACC, toAcc!!.step)
        val ready = PolarSetup.onControlWritten(PolarSetupStep.START_ACC, PolarUuids.PMD_CONTROL, ByteArray(0))!!
        assertTrue(ready.ready)
        // An unrelated callback for a step that is not waiting is still ignored.
        assertNull(PolarSetup.onControlWritten(PolarSetupStep.PMD_DATA_NOTIFY, PolarUuids.PMD_CONTROL, null))
        assertNull(PolarSetup.onControlWritten(PolarSetupStep.NONE, PolarUuids.PMD_CONTROL, null))
    }

    @Test fun fullSequenceReachesReadyExactlyOnce() {
        var step = PolarSetup.start.step
        step = PolarSetup.onDescriptorWritten(step, PolarUuids.HR_CHARACTERISTIC)!!.step
        step = PolarSetup.onDescriptorWritten(step, PolarUuids.PMD_DATA)!!.step
        step = PolarSetup.onDescriptorWritten(step, PolarUuids.PMD_CONTROL)!!.step
        step = PolarSetup.onBatteryRead(step, PolarUuids.BATTERY_CHARACTERISTIC)!!.step
        step = PolarSetup.onControlWritten(step, PolarUuids.PMD_CONTROL, PolarUuids.START_ECG)!!.step
        val ready = PolarSetup.onControlWritten(step, PolarUuids.PMD_CONTROL, PolarUuids.START_ACC)!!
        assertTrue(ready.ready)
        assertEquals(PolarSetupStep.NONE, ready.step)
    }
}
