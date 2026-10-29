package com.example.myapplication.sync

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test

class BoundedRestoreTest {
    @Test fun parallelDetailReadsAreBoundedAndResultsStayOrdered() {
        val active = AtomicInteger(); val maximum = AtomicInteger(); val firstFour = CountDownLatch(4)
        val result = boundedRestoreMap((0 until 23).toList(), { fail("Unexpected abort") }) { value ->
            val count = active.incrementAndGet(); maximum.accumulateAndGet(count, ::maxOf)
            try {
                if (value < 4) { firstFour.countDown(); check(firstFour.await(3, TimeUnit.SECONDS)) }
                value * 2
            } finally { active.decrementAndGet() }
        }
        assertEquals((0 until 23).map { it * 2 }, result); assertEquals(4, maximum.get()); assertEquals(0, active.get())
    }
    @Test fun fatalFailureCancelsSiblingsAndNeverStartsTheNextChunk() {
        val started = java.util.Collections.synchronizedSet(mutableSetOf<Int>())
        val release = CountDownLatch(1); val aborted = AtomicInteger()
        val failure = assertThrows(IllegalStateException::class.java) {
            boundedRestoreMap((0 until 20).toList(), { aborted.incrementAndGet(); release.countDown() }) { value ->
                started += value
                if (value == 1) error("fatal fixture")
                release.await(3, TimeUnit.SECONDS); value
            }
        }
        assertEquals("fatal fixture", failure.message); assertEquals(1, aborted.get()); assertTrue(started.all { it < 4 })
    }
}
