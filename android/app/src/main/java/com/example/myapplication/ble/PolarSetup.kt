package com.example.myapplication.ble

import java.util.UUID

internal object PolarUuids {
    val CLIENT_CONFIG: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    val PMD_SERVICE: UUID = UUID.fromString("fb005c80-02e7-f387-1cad-8acd2d8df0c8")
    val PMD_CONTROL: UUID = UUID.fromString("fb005c81-02e7-f387-1cad-8acd2d8df0c8")
    val PMD_DATA: UUID = UUID.fromString("fb005c82-02e7-f387-1cad-8acd2d8df0c8")
    val HR_SERVICE: UUID = UUID.fromString("0000180d-0000-1000-8000-00805f9b34fb")
    val HR_CHARACTERISTIC: UUID = UUID.fromString("00002a37-0000-1000-8000-00805f9b34fb")
    val BATTERY_SERVICE: UUID = UUID.fromString("0000180f-0000-1000-8000-00805f9b34fb")
    val BATTERY_CHARACTERISTIC: UUID = UUID.fromString("00002a19-0000-1000-8000-00805f9b34fb")
    val START_ECG: ByteArray = byteArrayOf(2, 0, 0, 1, 0x82.toByte(), 0, 1, 1, 0x0e, 0)
    val START_ACC: ByteArray = byteArrayOf(2, 2, 0, 1, 0xc8.toByte(), 0, 1, 1, 0x10, 0, 2, 1, 8, 0)
}

internal enum class PolarSetupStep {
    NONE,
    HR_NOTIFY,
    PMD_DATA_NOTIFY,
    PMD_CONTROL_NOTIFY,
    BATTERY_READ,
    START_ECG,
    START_ACC,
}

internal sealed class PolarSetupOperation {
    data class EnableNotifications(val service: UUID, val characteristic: UUID) : PolarSetupOperation()

    data class ReadBattery(val service: UUID, val characteristic: UUID) : PolarSetupOperation()

    class WriteControl(val value: ByteArray, val delayMillis: Long = 0L) : PolarSetupOperation()
}

/**
 * Which callback may advance the setup, and what must be started next.
 *
 * A callback that does not match the current step, the expected characteristic
 * or the exact control value is ignored instead of advancing the sequence.
 * Delaying or duplicating a callback must therefore never skip a step or report
 * a connection that never completed its setup.
 */
internal object PolarSetup {
    class Transition(val step: PolarSetupStep, val operation: PolarSetupOperation?, val ready: Boolean = false)

    val start = Transition(
        step = PolarSetupStep.HR_NOTIFY,
        operation = PolarSetupOperation.EnableNotifications(PolarUuids.HR_SERVICE, PolarUuids.HR_CHARACTERISTIC),
    )

    fun onDescriptorWritten(step: PolarSetupStep, characteristic: UUID): Transition? = when (step) {
        PolarSetupStep.HR_NOTIFY -> if (characteristic != PolarUuids.HR_CHARACTERISTIC) null else Transition(
            PolarSetupStep.PMD_DATA_NOTIFY,
            PolarSetupOperation.EnableNotifications(PolarUuids.PMD_SERVICE, PolarUuids.PMD_DATA),
        )
        PolarSetupStep.PMD_DATA_NOTIFY -> if (characteristic != PolarUuids.PMD_DATA) null else Transition(
            PolarSetupStep.PMD_CONTROL_NOTIFY,
            PolarSetupOperation.EnableNotifications(PolarUuids.PMD_SERVICE, PolarUuids.PMD_CONTROL),
        )
        PolarSetupStep.PMD_CONTROL_NOTIFY -> if (characteristic != PolarUuids.PMD_CONTROL) null else Transition(
            PolarSetupStep.BATTERY_READ,
            PolarSetupOperation.ReadBattery(PolarUuids.BATTERY_SERVICE, PolarUuids.BATTERY_CHARACTERISTIC),
        )
        else -> null
    }

    /**
     * The platform is not required to keep the written value on the
     * characteristic, so an empty value falls back to matching the step only.
     * A retained, different command is never accepted.
     */
    fun onControlWritten(step: PolarSetupStep, characteristic: UUID, value: ByteArray?): Transition? = when (step) {
        PolarSetupStep.START_ECG -> if (characteristic != PolarUuids.PMD_CONTROL ||
            !matchesCommand(value, PolarUuids.START_ECG)
        ) null else Transition(
            PolarSetupStep.START_ACC,
            PolarSetupOperation.WriteControl(PolarUuids.START_ACC, delayMillis = ACC_START_DELAY_MILLIS),
        )
        PolarSetupStep.START_ACC -> if (characteristic != PolarUuids.PMD_CONTROL ||
            !matchesCommand(value, PolarUuids.START_ACC)
        ) null else Transition(PolarSetupStep.NONE, null, ready = true)
        else -> null
    }

    private fun matchesCommand(value: ByteArray?, expected: ByteArray): Boolean =
        value == null || value.isEmpty() || value.contentEquals(expected)

    fun onBatteryRead(step: PolarSetupStep, characteristic: UUID): Transition? =
        if (step != PolarSetupStep.BATTERY_READ || characteristic != PolarUuids.BATTERY_CHARACTERISTIC) null else Transition(
            PolarSetupStep.START_ECG,
            PolarSetupOperation.WriteControl(PolarUuids.START_ECG),
        )

    const val ACC_START_DELAY_MILLIS = 600L
}
