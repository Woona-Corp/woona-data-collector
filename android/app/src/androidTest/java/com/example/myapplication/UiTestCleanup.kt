package com.example.myapplication

/** Always attempt every restoration, without replacing a failed test's primary evidence.
 * In particular, Espresso keyboard cleanup can fail when a system window loses focus.
 */
internal fun restoreUiTestState(primary: Throwable?, vararg restorations: () -> Unit) {
    var failure = primary
    restorations.forEach { restore ->
        try {
            restore()
        } catch (cleanup: Throwable) {
            val previous = failure
            if (previous == null) failure = cleanup
            else if (previous !== cleanup) previous.addSuppressed(cleanup)
        }
    }
    if (primary == null) failure?.let { throw it }
}
