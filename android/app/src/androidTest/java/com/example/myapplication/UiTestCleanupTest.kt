package com.example.myapplication

import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Test

class UiTestCleanupTest {
    @Test fun restoresAllStateAndPreservesThePrimaryFailure() {
        val primary = AssertionError("primary fixture")
        val cleanup = IllegalStateException("cleanup fixture")
        val restored = mutableListOf<String>()
        restoreUiTestState(primary,
            { restored += "keyboard"; throw cleanup },
            { restored += "orientation" },
            { restored += "font" },
        )
        assertEquals(listOf("keyboard", "orientation", "font"), restored)
        assertSame(cleanup, primary.suppressed.single())
    }

    @Test fun successfulBodyStillFailsWhenCleanupFailsButAttemptsEveryRestoration() {
        val first = IllegalStateException("first fixture")
        val second = IllegalArgumentException("second fixture")
        var lastRestored = false
        val result = runCatching {
            restoreUiTestState(null,
                { throw first },
                { throw second },
                { lastRestored = true },
            )
        }
        assertEquals(true, lastRestored)
        assertSame(first, result.exceptionOrNull())
        assertSame(second, first.suppressed.single())
    }
}
