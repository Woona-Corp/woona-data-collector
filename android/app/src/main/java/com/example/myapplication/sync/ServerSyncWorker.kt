package com.example.myapplication.sync

import android.content.Context
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.pm.ServiceInfo
import androidx.core.app.NotificationCompat
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import androidx.work.OneTimeWorkRequest
import androidx.work.WorkInfo
import java.util.concurrent.Executors
import com.example.myapplication.data.WoonaDatabase
import com.example.myapplication.data.recoverOrphanedUploads
import com.example.myapplication.data.networkPolicyProfileVersionIds
import com.example.myapplication.data.networkPolicyRecordingIds
import kotlin.concurrent.withLock
import com.example.myapplication.data.artifactFile
import com.example.myapplication.data.hashPendingArtifacts
import com.example.myapplication.data.markArtifactProgress
import com.example.myapplication.data.markProfileSyncError
import com.example.myapplication.data.markProfileSynced
import com.example.myapplication.data.markProfileUploading
import com.example.myapplication.data.markRecordingSyncError
import com.example.myapplication.data.markRecordingSynced
import com.example.myapplication.data.markRecordingUploading
import com.example.myapplication.data.pendingProfileVersionIds
import com.example.myapplication.data.pendingRecordingIds
import com.example.myapplication.data.profileSyncRecord
import com.example.myapplication.data.recordingSyncRecord
import com.example.myapplication.data.readyForSync
import com.example.myapplication.data.applyServerDeletions
import com.example.myapplication.data.acceptServerProfile
import com.example.myapplication.data.acceptServerRecording
import com.example.myapplication.data.restoreServerMetadata
import com.example.myapplication.data.dogQuestionnaireFromJson
import com.example.myapplication.data.sessionQuestionnaireFromJson
import com.example.myapplication.data.validate
import com.example.myapplication.R
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import java.util.concurrent.TimeUnit

class ProfileSyncWorker(
    context: Context,
    parameters: WorkerParameters,
) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        val profileVersionId = inputData.getString(KEY_ID) ?: return Result.failure()
        val database = WoonaDatabase(applicationContext)
        serverOperationLock.lock()
        return try {
            val settings = ServerSettingsStore(applicationContext).get()
            if (!settings.isConfigured) {
                database.markProfileSyncError(
                    profileVersionId,
                    retryable = false,
                    code = "server_not_configured",
                    message = "Server URL or token is missing",
                )
                return Result.failure()
            }
            val profile = database.profileSyncRecord(profileVersionId) ?: return Result.success()
            val transferContext = currentCoroutineContext()
            val client = ServerApiClient(settings.copy(accountId = database.profile(profile.dogId)?.accountId), checkCancelled = { transferContext.ensureActive() })
            val markers = client.fetchDeletions()
            if (!settings.sameRetirementServer(ServerSettingsStore(applicationContext).get())) return Result.retry()
            database.applyServerDeletions(markers)
            if (database.profileSyncRecord(profileVersionId) == null) return Result.success()
            database.markProfileUploading(profileVersionId)
            val receipt = client.uploadProfile(profile)
            receipt.profileVersion?.let { database.acceptServerProfile(profile.dogId, it) }
            database.markProfileSynced(
                profileVersionId,
                profile.dogId,
                receipt.dogRevision,
            )
            Result.success()
        } catch (cancelled: CancellationException) {
            database.markProfileSyncError(profileVersionId, true, "transfer_paused", "transfer_paused: Transfer paused; local data and confirmed progress are preserved for retry")
            throw cancelled
        } catch (exception: Exception) {
            if (!currentCoroutineContext().isActive) {
                database.markProfileSyncError(profileVersionId,true,"transfer_paused","transfer_paused: Transfer paused; local data and confirmed progress are preserved")
                throw CancellationException("Transfer cancelled").apply { initCause(exception) }
            }
            val retryable = exception.isRetryable()
            database.markProfileSyncError(
                profileVersionId,
                retryable,
                exception.errorCode(),
                exception.message ?: exception.toString(),
            )
            if (retryable) Result.retry() else Result.failure()
        } finally {
            serverOperationLock.unlock()
            database.close()
        }
    }
}

class ArtifactHashWorker(
    context: Context,
    parameters: WorkerParameters,
) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        val database = WoonaDatabase(applicationContext)
        return try {
            database.hashPendingArtifacts()
            ServerSyncScheduler.enqueueReady(applicationContext)
            Result.success()
        } catch (_: Exception) {
            Result.retry()
        } finally {
            database.close()
        }
    }
}

class RecordingSyncWorker(
    context: Context,
    parameters: WorkerParameters,
) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        val recordingId = inputData.getString(KEY_ID) ?: return Result.failure()
        setForeground(foregroundInfo(recordingId))
        val database = WoonaDatabase(applicationContext)
        if (database.recording(recordingId)?.questionnaire?.readyForSync() == false) {
            database.close()
            return Result.success()
        }
        serverOperationLock.lock()
        return try {
            val settings = ServerSettingsStore(applicationContext).get()
            if (!settings.isConfigured) {
                database.markRecordingSyncError(
                    recordingId,
                    retryable = false,
                    code = "server_not_configured",
                    message = "Server URL or token is missing",
                )
                return Result.failure()
            }
            var record = database.recordingSyncRecord(recordingId) ?: return Result.success()
            val transferContext = currentCoroutineContext()
            val client = ServerApiClient(settings.copy(accountId = database.profile(record.dogId)?.accountId), checkCancelled = { transferContext.ensureActive() })
            val markers = client.fetchDeletions()
            if (!settings.sameRetirementServer(ServerSettingsStore(applicationContext).get())) return Result.retry()
            database.applyServerDeletions(markers)
            record = database.recordingSyncRecord(recordingId) ?: return Result.success()
            val accepted = try { client.fetchRecording(recordingId) }
                catch (error: ServerHttpException) { if (error.status == 404) null else throw error }
            if (accepted?.receiptSha256 != null) {
                val restored = database.restoreServerMetadata(listOf(client.fetchDog(accepted.dogId)),listOf(accepted))
                if (restored.recordingConflicts > 0) {
                    database.markRecordingSyncError(recordingId, false, "metadata_conflict",
                        "Файлы или метаданные записи отличаются от серверной версии. Локальные файлы сохранены.")
                    return Result.failure()
                }
                database.markRecordingSynced(recordingId,accepted.receiptSha256,requireNotNull(accepted.verifiedAtUtc))
                if (record.artifacts.none { it.type in setOf("ecg","heart_rate","rr") && it.uploadState != "available" }) return Result.success()
                record = database.recordingSyncRecord(recordingId) ?: return Result.success()
            }
            require(dogQuestionnaireFromJson(record.profile.questionnaireJson).validate().isValid &&
                sessionQuestionnaireFromJson(record.sessionQuestionnaireJson).validate().isValid) {
                "Анкета не прошла локальную проверку"
            }
            val profileReceipt = client.uploadProfile(record.profile)
            profileReceipt.profileVersion?.let { database.acceptServerProfile(record.dogId, it) }
            database.markProfileSynced(
                record.profileVersionId,
                record.dogId,
                profileReceipt.dogRevision,
            )
            record = database.recordingSyncRecord(recordingId) ?: return Result.failure()
            database.markRecordingUploading(recordingId)
            val artifactsById = record.artifacts.associateBy { it.id }
            val receipt = client.uploadRecording(
                record = record,
                fileForArtifact = { artifactId ->
                    database.artifactFile(requireNotNull(artifactsById[artifactId]))
                },
                onProgress = { artifactId, uploadedBytes, available ->
                    database.markArtifactProgress(artifactId, uploadedBytes, available)
                    setProgressAsync(workDataOf("artifact_id" to artifactId, "uploaded_bytes" to uploadedBytes, "verified" to available))
                },
            )
            database.acceptServerRecording(client.fetchRecording(recordingId))
            database.markRecordingSynced(
                recordingId,
                receipt.receiptSha256,
                receipt.verifiedAtUtc,
            )
            if (database.recording(recordingId)?.serverSyncState == "pending") Result.retry() else Result.success()
        } catch (cancelled: CancellationException) {
            database.markRecordingSyncError(recordingId, true, "transfer_paused", "transfer_paused: Transfer paused; local data and confirmed progress are preserved for retry")
            throw cancelled
        } catch (exception: Exception) {
            if (!currentCoroutineContext().isActive) {
                database.markRecordingSyncError(recordingId,true,"transfer_paused","transfer_paused: Transfer paused; local data and confirmed progress are preserved")
                throw CancellationException("Transfer cancelled").apply { initCause(exception) }
            }
            val retryable = exception.isRetryable()
            database.markRecordingSyncError(
                recordingId,
                retryable,
                exception.errorCode(),
                exception.message ?: exception.toString(),
            )
            if (retryable) Result.retry() else Result.failure()
        } finally {
            serverOperationLock.unlock()
            database.close()
        }
    }

    override suspend fun getForegroundInfo(): ForegroundInfo =
        foregroundInfo(inputData.getString(KEY_ID).orEmpty())

    private fun foregroundInfo(recordingId: String): ForegroundInfo {
        val manager = applicationContext.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                NOTIFICATION_CHANNEL,
                "Server synchronization",
                NotificationManager.IMPORTANCE_LOW,
            ),
        )
        val notification = NotificationCompat.Builder(applicationContext, NOTIFICATION_CHANNEL)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Woona")
            .setContentText("Uploading recording ${recordingId.take(8)}")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setProgress(0, 0, true)
            .build()
        return ForegroundInfo(
            NOTIFICATION_ID,
            notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
        )
    }

    private companion object {
        const val NOTIFICATION_CHANNEL = "woona_server_sync"
        const val NOTIFICATION_ID = 3401
    }
}

object ServerSyncScheduler {
    const val WORK_TAG = "woona-server-sync"
    const val MAINTENANCE_TAG = "woona-retirement-maintenance"
    private const val RETIREMENT_WORK_NAME = "server-retirement-reconcile"

    private val policyLock = Any()
    private val policyExecutor = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "woona-network-policy") }

    /** Update queued constraints in-place; WorkManager never interrupts a running generation. */
    /** Credentials are durably disabled before cancellation; neither queue nor files are cleared. */
    fun disconnect(context: Context) {
        synchronized(com.example.myapplication.data.completeArchiveLifecycleLock) {
            check(!com.example.myapplication.data.isCompleteArchiveExporting) { "Дождитесь завершения экспорта / Wait for archive export to finish" }
            ServerSettingsStore(context).clearToken()
            ServerTransferRegistry.cancelAll()
        }
        val manager = WorkManager.getInstance(context.applicationContext)
        manager.cancelAllWorkByTag(WORK_TAG).result.get(30, TimeUnit.SECONDS)
        serverOperationLock.withLock {
            WoonaDatabase(context.applicationContext).use { database ->
                database.recoverOrphanedUploads { name -> manager.getWorkInfosForUniqueWork(name).get(30, TimeUnit.SECONDS).any { !it.state.isFinished } }
            }
        }
    }

    fun refreshPendingNetworkPolicy(context: Context, onComplete: (Throwable?) -> Unit = {}) = policyExecutor.submit {
        val failure = runCatching {
            serverOperationLock.withLock {
            synchronized(policyLock) {
                val manager = WorkManager.getInstance(context.applicationContext)
                val constraints = networkConstraints(context)
                WoonaDatabase(context.applicationContext).use { database ->
                    database.recoverOrphanedUploads { name ->
                        manager.getWorkInfosForUniqueWork(name).get(30, TimeUnit.SECONDS).any { !it.state.isFinished }
                    }
                    updateWaitingNetworkPolicy(manager, RETIREMENT_WORK_NAME, constraints) { old -> retirementRequest(context, old, constraints) }
                    database.networkPolicyProfileVersionIds().forEach { id ->
                        updateWaitingNetworkPolicy(manager, "server-profile-$id", constraints) { old -> profileRequest(context, id, old, constraints) }
                    }
                    database.networkPolicyRecordingIds().forEach { id ->
                        updateWaitingNetworkPolicy(manager, "server-sync-$id", constraints) { old -> recordingRequest(context, id, old, constraints) }
                    }
                }
                enqueuePending(context.applicationContext)
            }
            }
        }.exceptionOrNull()
        onComplete(failure)
    }

    internal fun updateWaitingNetworkPolicy(manager: WorkManager, name: String, constraints: Constraints, request: (WorkInfo) -> OneTimeWorkRequest): Int {
        var updated = 0
        for (old in manager.getWorkInfosForUniqueWork(name).get(30, TimeUnit.SECONDS)) {
            if (old.state != WorkInfo.State.ENQUEUED && old.state != WorkInfo.State.BLOCKED) continue
            if (old.constraints == constraints) continue
            val next = request(old)
            check(next.id == old.id) { "Network policy must preserve worker identity" }
            manager.updateWork(next).get(30, TimeUnit.SECONDS)
            updated++
        }
        return updated
    }

    fun enqueuePending(context: Context) {
        if (ServerSettingsStore(context).get().isConfigured) synchronized(policyLock) {
            WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(RETIREMENT_WORK_NAME, ExistingWorkPolicy.KEEP, retirementRequest(context))
        }
        val database = WoonaDatabase(context.applicationContext)
        try {
            database.pendingProfileVersionIds().forEach { enqueueProfile(context, it) }
            database.pendingRecordingIds().forEach { enqueueRecording(context, it) }
        } finally {
            database.close()
        }
        WorkManager.getInstance(context.applicationContext).enqueueUniqueWork(
            "server-artifact-hash",
            ExistingWorkPolicy.KEEP,
            OneTimeWorkRequestBuilder<ArtifactHashWorker>()
                .addTag(WORK_TAG)
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
                .build(),
        )
    }

    internal fun enqueueReady(context: Context) {
        val database = WoonaDatabase(context.applicationContext)
        try {
            database.pendingProfileVersionIds().forEach { enqueueProfile(context, it) }
            database.pendingRecordingIds().forEach { enqueueRecording(context, it) }
        } finally {
            database.close()
        }
    }

    fun enqueueProfile(context: Context, profileVersionId: String) {
        synchronized(policyLock) {
            WorkManager.getInstance(context.applicationContext).enqueueUniqueWork("server-profile-$profileVersionId", ExistingWorkPolicy.KEEP, profileRequest(context, profileVersionId))
        }
    }

    private fun profileRequest(context: Context, profileVersionId: String, old: WorkInfo? = null, constraints: Constraints = networkConstraints(context)): OneTimeWorkRequest =
        OneTimeWorkRequestBuilder<ProfileSyncWorker>()
            .addTag(WORK_TAG)
            .setInputData(workDataOf(KEY_ID to profileVersionId))
            .setConstraints(constraints)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .apply { old?.let { setId(it.id); it.tags.forEach { tag -> addTag(tag) } } }
            .build()

    fun enqueueRecording(context: Context, recordingId: String) {
        synchronized(policyLock) {
            WorkManager.getInstance(context.applicationContext).enqueueUniqueWork("server-sync-$recordingId", ExistingWorkPolicy.KEEP, recordingRequest(context, recordingId))
        }
    }

    private fun recordingRequest(context: Context, recordingId: String, old: WorkInfo? = null, constraints: Constraints = networkConstraints(context)): OneTimeWorkRequest =
        OneTimeWorkRequestBuilder<RecordingSyncWorker>()
            .addTag(WORK_TAG)
            .setInputData(workDataOf(KEY_ID to recordingId))
            .setConstraints(constraints)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .apply { old?.let { setId(it.id); it.tags.forEach { tag -> addTag(tag) } } }
            .build()

    private fun retirementRequest(context: Context, old: WorkInfo? = null, constraints: Constraints = networkConstraints(context)): OneTimeWorkRequest =
        OneTimeWorkRequestBuilder<RetirementSyncWorker>()
            .setId(old?.id ?: java.util.UUID.randomUUID())
            .addTag(WORK_TAG).addTag(MAINTENANCE_TAG)
            .apply { old?.tags?.forEach(::addTag) }
            .setConstraints(constraints)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .build()

    private fun networkConstraints(context: Context): Constraints =
        Constraints.Builder()
            .setRequiredNetworkType(
                if (ServerSettingsStore(context).get().wifiOnly) {
                    NetworkType.UNMETERED
                } else {
                    NetworkType.CONNECTED
                },
            )
            .build()
}

private fun Exception.isRetryable(): Boolean = when (this) {
    is ServerHttpException -> status in setOf(408, 425, 429) || status >= 500
    is ServerTransferException -> retryable
    is IOException -> true
    else -> false
}

private fun Exception.errorCode(): String = when (this) {
    is ServerHttpException -> "http_$status"
    is ServerTransferException -> code
    is IOException -> "network_error"
    else -> "local_data_error"
}

private const val KEY_ID = "id"
