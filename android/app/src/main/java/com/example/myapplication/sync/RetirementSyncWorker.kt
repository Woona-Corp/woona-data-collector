package com.example.myapplication.sync

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.example.myapplication.data.WoonaDatabase
import com.example.myapplication.data.applyServerDeletions
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import java.io.IOException
import java.time.Instant
import kotlin.concurrent.withLock

internal fun ServerSettings.sameRetirementServer(other: ServerSettings): Boolean =
    baseUrl == other.baseUrl && token == other.token && deviceId == other.deviceId && transferGeneration == other.transferGeneration

/** An accepted global retirement response belongs to the connection that fetched it. */
internal fun reconcileCurrentRetirements(
    snapshot: ServerSettings,
    current: () -> ServerSettings,
    fetch: () -> List<Pair<String,String>>,
    apply: (List<Pair<String,String>>) -> Unit,
): Boolean {
    val markers = fetch()
    if (!snapshot.sameRetirementServer(current())) return false
    apply(markers)
    return true
}

/** Event-triggered maintenance, with at most three network attempts; never periodic. */
class RetirementSyncWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        val coroutine = currentCoroutineContext()
        serverOperationLock.lock()
        return try {
            val store = ServerSettingsStore(applicationContext)
            val snapshot = store.get()
            if (!snapshot.isConfigured) return completed(null)
            val client = ServerApiClient(snapshot, checkCancelled = { coroutine.ensureActive() })
            WoonaDatabase(applicationContext).use { database ->
                val applied = reconcileCurrentRetirements(snapshot, store::get, client::fetchDeletions) { markers ->
                    coroutine.ensureActive()
                    database.applyServerDeletions(markers)
                }
                if (applied) completed(null) else if (runAttemptCount < 2) Result.retry() else completed("Server connection changed during retirement reconciliation; retry with the current server")
            }
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (error: Exception) {
            val retryable = when (error) {
                is ServerHttpException -> error.status in setOf(408,425,429) || error.status >= 500
                is IOException -> true
                else -> false
            }
            if (retryable && runAttemptCount < 2) Result.retry() else completed(error.message ?: error.javaClass.simpleName)
        } finally { serverOperationLock.unlock() }
    }
    private fun completed(error: String?): Result {
        val data=workDataOf("retirement_completed_at" to Instant.now().toString(), "retirement_error" to error?.take(2000))
        return if(error==null) Result.success(data) else Result.failure(data)
    }
}
