package com.example.myapplication.sync

import com.example.myapplication.localization.AppLanguage
import org.junit.Assert.*
import org.junit.Test

class SyncPresentationTest {
    @Test fun receivedBytesAndVerifiedFilesHaveDifferentHumanStates() {
        assertTrue(transferStateText("awaiting_verification", true).contains("проверка"))
        assertTrue(transferStateText("verified", false).contains("at the time"))
        assertTrue(nextTransferActionText("contact_support_preserve_local_data", true).contains("сохраните"))
        assertEquals("future_server_code", transferStateText("future_server_code", true))
    }

    @Test fun emptyQueueDoesNotClaimServerOrLabelingIsHealthy() {
        val text = ServerSyncUiState(status = ServerSyncStatus.READY).queueExplanation(AppLanguage.ENGLISH)
        assertTrue(text.contains("does not verify server"))
        assertTrue(text.contains("Label Studio"))
    }
    @Test fun pendingQueueExplainsOfflineAndUnmeteredConstraintBeforeGenericWaiting() {
        val state = ServerSyncUiState(status = ServerSyncStatus.READY, pending = 7, networkAvailable = false, wifiOnly = true, unmeteredNetwork = false)
        assertTrue(state.queueExplanation(AppLanguage.ENGLISH).startsWith("No internet"))
        assertTrue(state.copy(networkAvailable = true).queueExplanation(AppLanguage.ENGLISH).contains("unmetered"))
        assertTrue(state.copy(networkAvailable = true, unmeteredNetwork = true).queueExplanation(AppLanguage.ENGLISH).contains("waiting for the system"))
    }
    @Test fun uploadedBytesDoNotClaimIntegrityOrCaptureSuccess() {
        val text = ServerSyncUiState(status = ServerSyncStatus.UPLOADING, uploading = 1, workersRunning = 1).queueExplanation(AppLanguage.RUSSIAN)
        assertTrue(text.contains("ещё не означают"))
        assertFalse(text.contains("успешная запись"))
    }
    @Test fun failureHasNextStepAndConfigurationHasLocalDataGuarantee() {
        assertTrue(ServerSyncUiState().queueExplanation(AppLanguage.RUSSIAN).contains("на телефоне"))
        assertTrue(ServerSyncUiState(status = ServerSyncStatus.NEEDS_ATTENTION, failed = 1).queueExplanation(AppLanguage.RUSSIAN).contains("причину в записи"))
        assertEquals("Connection not checked", ConnectionCheck.NOT_CHECKED.label(AppLanguage.ENGLISH))
    }
    @Test fun mutationBlockExplainsWhyReadOnlyChecksStillRemainAvailable() {
        val state = ServerSyncUiState(status = ServerSyncStatus.READY, mutationsAllowed = false, mutationBlockReason = "capture")
        assertTrue(state.isConfigured)
        assertEquals(ConnectionCheck.NOT_CHECKED, state.connectionCheck)
        assertTrue(state.mutationBlockExplanation(AppLanguage.RUSSIAN).contains("Завершите текущую сессию"))
        assertTrue(state.copy(mutationBlockReason = "upload").mutationBlockExplanation(AppLanguage.ENGLISH).contains("current upload"))
    }

    @Test fun savedUploadingWithoutRunningWorkerIsWaitingAndPolicyCanBeChanged() {
        val state = ServerSyncUiState(status = ServerSyncStatus.WAITING, uploading = 1,
            workersRunning = 0, mutationsAllowed = false, networkPolicyAllowed = true)
        assertTrue(state.queueExplanation(AppLanguage.ENGLISH).contains("No background job is currently running"))
        assertFalse(state.queueExplanation(AppLanguage.ENGLISH).contains("Processing the queue"))
        assertTrue(state.networkPolicyAllowed)
    }

}
