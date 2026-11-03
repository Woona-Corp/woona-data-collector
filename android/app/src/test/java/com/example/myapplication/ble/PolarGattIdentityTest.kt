package com.example.myapplication.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PolarGattIdentityTest {
    private data class Gatt(val address: String)

    @Test fun onlySameInstanceOwnsCallbacks() {
        val current = Gatt("same address")
        assertTrue(isCurrentPolarGatt(current, current))
        assertFalse(isCurrentPolarGatt(current, Gatt("same address")))
        assertFalse(isCurrentPolarGatt(null, current))
    }

    @Test fun delayedActionRechecksOwnershipAfterReplacement() {
        val old = Gatt("same address")
        var current: Gatt? = old
        var writes = 0
        val delayed = { if (isCurrentPolarGatt(current, old)) writes++ }
        current = Gatt("same address")
        delayed()
        assertTrue(writes == 0)
        assertTrue(isCurrentPolarGatt(current, current!!))
    }
}
