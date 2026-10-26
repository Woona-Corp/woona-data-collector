package com.example.myapplication.ble

internal enum class BleDisconnectAction { DISCONNECTED, RETRY, RECOVER, FAIL }

/** Keep an active capture open for bounded transport recovery; never undo a manual stop. */
internal fun bleDisconnectAction(manual: Boolean, recovering: Boolean, activeCapture: Boolean): BleDisconnectAction = when {
    manual -> BleDisconnectAction.DISCONNECTED
    recovering -> BleDisconnectAction.RETRY
    activeCapture -> BleDisconnectAction.RECOVER
    else -> BleDisconnectAction.FAIL
}
