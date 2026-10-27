package com.example.myapplication.sync

import java.net.HttpURLConnection
import java.util.concurrent.CancellationException
import java.util.concurrent.Executors

/** An old settings snapshot cannot reconnect after the operator disconnects. */
internal object ServerTransferRegistry {
    private val lock = Any()
    private var epoch = 0L
    private val connections = mutableSetOf<HttpURLConnection>()
    private val closer = Executors.newCachedThreadPool { runnable -> Thread(runnable, "woona-transfer-stop").apply { isDaemon = true } }
    val generation: Long get() = synchronized(lock) { epoch }
    fun ensureActive(generation: Long) {
        synchronized(lock) { if (generation != epoch) throw CancellationException("transfer_paused: Server was disconnected; local files and confirmed progress are preserved") }
    }
    fun register(connection: HttpURLConnection, generation: Long) {
        synchronized(lock) {
            if (generation != epoch) {
                connection.disconnect()
                throw CancellationException("transfer_paused: Server was disconnected before this request started")
            }
            connections += connection
        }
    }
    fun release(connection: HttpURLConnection) { synchronized(lock) { connections -= connection }; connection.disconnect() }
    fun cancelAll() {
        val active = synchronized(lock) { epoch++; connections.toList().also { connections.clear() } }
        // A platform disconnect may wait on its socket lock; never hold UI or registry locks.
        active.forEach { connection -> closer.execute { runCatching { connection.disconnect() } } }
    }
}
