package com.example.myapplication.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ServerDeletionPaginationTest {
    private val first = "a".repeat(64)
    private val second = "b".repeat(64)

    @Test
    fun everyPageIsFollowedUntilTheServerStops() {
        val asked = mutableListOf<String?>()
        val markers = followDeletionPages(10) { cursor ->
            asked += cursor
            if (cursor == null) DeletionPage(listOf("dog" to first), "dog:$first")
            else DeletionPage(listOf("dog" to second), null)
        }
        assertEquals(listOf("dog" to first, "dog" to second), markers)
        assertEquals(listOf(null, "dog:$first"), asked)
    }

    @Test
    fun aRepeatedCursorStopsInsteadOfLoopingForever() {
        var calls = 0
        val failure = assertThrows(ServerTransferException::class.java) {
            followDeletionPages(10) {
                calls += 1
                DeletionPage(listOf("dog" to first), "dog:$first")
            }
        }
        assertEquals("pagination_stalled", failure.code)
        assertTrue("A repeated cursor must not be trusted", calls <= 3)
    }

    @Test
    fun anEndlessServerStillReturnsBoundedWork() {
        var calls = 0
        val failure = assertThrows(ServerTransferException::class.java) {
            followDeletionPages(200) {
                calls += 1
                DeletionPage(listOf("dog" to first), "dog:" + calls.toString(16).padStart(64, '0'))
            }
        }
        assertEquals("pagination_stalled", failure.code)
        assertEquals(200, calls)
    }

    @Test
    fun onePageWithNoCursorIsEnough() {
        assertEquals(
            listOf("dog" to second),
            followDeletionPages(10) { DeletionPage(listOf("dog" to second), null) },
        )
    }
}
