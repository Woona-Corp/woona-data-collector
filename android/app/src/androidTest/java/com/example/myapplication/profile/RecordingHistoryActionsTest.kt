package com.example.myapplication.profile

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.MaterialTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createComposeRule
import com.example.myapplication.data.*
import com.example.myapplication.feature.device.VideoCaptureState
import com.example.myapplication.localization.AppLanguage
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

class RecordingHistoryActionsTest {
    @get:Rule val compose = createComposeRule()

    private fun show(state: String, unknownEnd: Boolean = false, status: RecordingStatus = RecordingStatus.FAILED, onRemove: (String) -> Unit = {}) {
        val record = Recording("session", "dog", "dog-v1", RecordingSource.LIVE, status,
            "5", true, "2026-10-25T12:06:00Z", if (unknownEnd) null else "2026-10-25T12:16:00Z", "UTC", null, "session",
            artifacts = listOf(Artifact("file", "session", ArtifactType.PACKET, "packets.bin", "application/octet-stream", "session/packets.bin", 1, "hash", "both", "available", 1, "2026-10-25T12:06:00Z")),
            serverSyncState = state, captureErrorCode = "gatt_error", captureErrorMessage = "Ошибка GATT-подключения: 8")
        compose.setContent {
            MaterialTheme {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    ProfilesOverview(emptyList(), null, listOf(record), AppLanguage.RUSSIAN, {}, {}, {}, {},
                        videoState = VideoCaptureState.IDLE, videoOffsetMillis = null, onVideoAction = {},
                        onRemoveLocalRecording = onRemove, showVideoPreview = false)
                }
            }
        }
    }

    @Test fun captureCauseAndSuccessfulUploadAreIndependentAndDetailsExpand() {
        show("synced")
        compose.onNodeWithText("GATT 8", substring = true).performScrollTo().assertIsDisplayed()
        compose.onNodeWithText("Загрузка: файлы подтверждены сервером").assertExists()
        compose.onNodeWithText("Подробности ошибки").performScrollTo().performClick()
        compose.onNodeWithText("Ошибка GATT-подключения: 8", substring = true).assertExists()
    }

    @Test fun removalRequiresConfirmationAndCancelDoesNothing() {
        val calls = mutableListOf<String>()
        show("synced") { calls += it }
        compose.onNodeWithText("Удалить с устройства").performScrollTo().performClick()
        compose.onNodeWithText("Отмена").performClick()
        compose.runOnIdle { assertEquals(emptyList<String>(), calls) }
        compose.onNodeWithText("Удалить с устройства").performClick()
        compose.onAllNodesWithText("Удалить с устройства").onLast().performClick()
        compose.runOnIdle { assertEquals(listOf("session"), calls) }
    }

    @Test fun terminalImportedSessionWithoutMachineEndHasRemovalAction() {
        show("synced", unknownEnd = true, status = RecordingStatus.COMPLETED)
        compose.onNodeWithText("Удалить с устройства").performScrollTo().assertIsEnabled()
    }

    @Test fun activeSessionWithoutMachineEndCannotRemoveLocalFiles() {
        show("synced", unknownEnd = true, status = RecordingStatus.RECORDING)
        compose.onNodeWithText("Удалить с устройства").performScrollTo().assertIsNotEnabled()
    }

    @Test fun pendingUploadsCannotBeRemoved() {
        show("pending")
        compose.onNodeWithText("Удалить с устройства").performScrollTo().assertIsNotEnabled()
        compose.onNodeWithText("Удаление локальных файлов доступно после подтверждения полной загрузки.").assertExists()
    }
}
