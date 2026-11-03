package com.example.myapplication.sync

import android.content.Context
import android.database.sqlite.SQLiteException
import android.util.Log
import androidx.work.BackoffPolicy
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.example.myapplication.data.ActivityDatabase
import com.example.myapplication.data.applyServerDeletions
import com.example.myapplication.data.retirementCleanupStatus
import java.io.IOException
import java.util.concurrent.CancellationException
import java.util.concurrent.ExecutionException
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit
import kotlin.concurrent.withLock

/** Local retry for previously accepted retirement markers; no network or new approval. */
class LocalRetirementCleanupWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        return try {
            val status = serverOperationLock.withLock {
                val database = ActivityDatabase.get(applicationContext)
                database.applyServerDeletions(emptyList())
                database.retirementCleanupStatus()
            }
            // Scheduling uploads is independent of local retirement. A synchronous
            // scheduler failure must not turn committed cleanup into a terminal job.
            try {
                ServerSyncScheduler.enqueuePending(applicationContext)
            } catch (error: RuntimeException) {
                Log.w("WOONA_RETIREMENT", "Could not schedule sync; retrying", error)
                return Result.retry()
            }
            if (status.pending == 0) {
                // Deferred markers may belong to a live capture. Its eventual
                // finalization enqueues another local pass; retrying this chain
                // indefinitely would block that newer pass behind backoff.
                Result.success()
            } else {
                Log.w("WOONA_RETIREMENT", "Local retirement cleanup remains pending; retrying")
                Result.retry()
            }
        } catch (error: SQLiteException) {
            Log.w("WOONA_RETIREMENT", "Local retirement database unavailable; retrying", error)
            Result.retry()
        } catch (error: IOException) {
            Log.w("WOONA_RETIREMENT", "Local retirement storage unavailable; retrying", error)
            Result.retry()
        }
    }

    companion object {
        internal const val WORK_NAME = "local-retirement-cleanup"

        fun enqueue(context: Context) {
            val request = OneTimeWorkRequestBuilder<LocalRetirementCleanupWorker>()
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
                .build()
            // A retry with an unrelated undeletable outbox entry must not hold a
            // newly finalized capture behind its backoff. Replace even running
            // work: the durable markers remain the source of truth, and the new
            // pass re-reads them under serverOperationLock.
            val operation = WorkManager.getInstance(context.applicationContext)
                .enqueueUniqueWork(WORK_NAME, ExistingWorkPolicy.REPLACE, request)
            // Enqueue can also fail asynchronously, after this method returns.
            // Keep synchronous failures visible to the caller and report later
            // failures rather than silently treating them as accepted work.
            val result = operation.result
            result.addListener({
                try {
                    result.get()
                } catch (error: ExecutionException) {
                    Log.e("WOONA_RETIREMENT", "Could not enqueue local cleanup", error.cause ?: error)
                } catch (error: CancellationException) {
                    Log.e("WOONA_RETIREMENT", "Local cleanup enqueue was cancelled", error)
                } catch (error: InterruptedException) {
                    Thread.currentThread().interrupt()
                    Log.e("WOONA_RETIREMENT", "Interrupted checking local cleanup enqueue", error)
                }
            }, Executor { it.run() })
        }
    }
}
