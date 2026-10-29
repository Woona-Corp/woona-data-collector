package com.example.myapplication.sync

import java.util.concurrent.ExecutionException
import java.util.concurrent.ExecutorCompletionService
import java.util.concurrent.Executors

/** Four requests at most, ordered results; caller applies all metadata serially. */
internal fun <T, R> boundedRestoreMap(items: List<T>, onAbort: () -> Unit, transform: (T) -> R): List<R> {
    if (items.isEmpty()) return emptyList()
    val executor = Executors.newFixedThreadPool(minOf(4, items.size)) { task -> Thread(task, "woona-restore-detail").apply { isDaemon = true } }
    try {
        val output = mutableListOf<R>()
        for (chunk in items.chunked(4)) {
            val completion = ExecutorCompletionService<Pair<Int, R>>(executor)
            val futures = chunk.mapIndexed { index, value -> completion.submit(java.util.concurrent.Callable { index to transform(value) }) }
            try {
                val completed = (chunk.indices).map { completion.take().get() }.sortedBy { it.first }
                output += completed.map { it.second }
            } catch (error: Throwable) {
                onAbort()
                futures.forEach { it.cancel(true) }
                if (error is InterruptedException) Thread.currentThread().interrupt()
                if (error is ExecutionException) throw (error.cause ?: error)
                throw error
            }
        }
        return output
    } finally { executor.shutdownNow() }
}
