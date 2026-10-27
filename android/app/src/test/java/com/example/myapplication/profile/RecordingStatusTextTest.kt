package com.example.myapplication.profile

import com.example.myapplication.localization.recordingCaptureText
import com.example.myapplication.localization.recordingUploadText
import com.example.myapplication.localization.recordingSourceText
import com.example.myapplication.localization.recordingUploadErrorText

import com.example.myapplication.localization.AppLanguage
import org.junit.Assert.*
import org.junit.Test

class RecordingStatusTextTest {
    private val ru = AppLanguage.RUSSIAN
    private val en = AppLanguage.ENGLISH

    @Test fun failedCaptureStaysExplicitWhenUploadSucceeded() {
        assertEquals("Запись: прервана — сбой связи с ошейником (GATT 8)",
            recordingCaptureText("failed", "gatt_error", "Ошибка GATT-подключения: 8", ru))
        assertEquals("Загрузка: загрузка была подтверждена; актуальную копию проверьте ниже", recordingUploadText("synced", null, ru))
        assertEquals("Capture: interrupted — collar connection failed (GATT 133)",
            recordingCaptureText("failed", "gatt_error", "GATT status 133", en))
    }

    @Test fun completedCaptureDoesNotHideVideoFailure() {
        val text = recordingCaptureText("completed", "camera_failed", "Broken pipe (-32)", ru)
        assertTrue(text.contains("завершена с проблемой"))
        assertTrue(text.contains("сбой камеры"))
    }

    @Test fun missingAndUnknownCausesAreNeverInventedOrDiscarded() {
        assertTrue(recordingCaptureText("failed", null, null, ru).contains("причина не сохранена"))
        assertFalse(recordingCaptureText("interrupted", null, null, en).contains("collar"))
        val text = recordingCaptureText("failed", "new_firmware_error", "Specific future error", en)
        assertTrue(text.contains("new_firmware_error"))
        assertTrue(text.contains("Specific future error"))
    }

    @Test fun captureCategoriesIdentifyTheFailingSubsystem() {
        assertTrue(recordingCaptureText("failed", "notification_timeout", null, ru).contains("перестал передавать данные"))
        assertTrue(recordingCaptureText("failed", "storage_failed", null, ru).contains("сохранить файлы"))
        assertTrue(recordingCaptureText("failed", "queue_overflow", null, ru).contains("очередь"))
        assertTrue(recordingCaptureText("failed", "no_sensor_data", null, ru).contains("ни одного корректного"))
    }

    @Test fun uploadFailureExplainsCauseAndRetryPolicySeparatelyFromCapture() {
        val retry = recordingUploadText("retryable_error", "Server returned HTTP 503: unavailable", ru)
        assertTrue(retry.contains("запланирован повтор"))
        assertTrue(retry.contains("HTTP 503"))
        val stopped = recordingUploadText("permanent_error", "Server returned 403: forbidden", en)
        assertTrue(stopped.contains("action is required"))
        assertTrue(stopped.contains("Permission was denied"))
        assertTrue(stopped.contains("HTTP 403"))
        assertTrue(recordingUploadText("permanent_error", "invalid_bearer_token", ru).contains("Токен"))
        assertTrue(recordingUploadText("retryable_error", null, ru).contains("Причина не сохранена"))
    }

    @Test fun serverIntegrityAndOwnershipFailuresHaveDifferentMeanings() {
        assertTrue(recordingUploadErrorText("artifact_hash_mismatch", ru).contains("Контрольная сумма"))
        assertTrue(recordingUploadErrorText("wrong_capture_device", en).contains("another device"))
        assertTrue(recordingUploadErrorText("local_copy_changed", ru).contains("Удаление отменено"))
        assertTrue(recordingUploadErrorText("HTTP 409: profile_content_already_exists", ru).contains("Восстановите профили"))
        assertTrue(recordingUploadErrorText("profile_content_already_exists", en).contains("do not create it again"))
        val unknown = recordingUploadErrorText("Unexpected future failure", en)
        assertTrue(unknown.contains("outcome is not confirmed"))
        assertTrue(unknown.contains("complete archive"))
        assertTrue(unknown.contains("Unexpected future failure"))
    }
    @Test fun httpErrorsExplainTheNextActionWithoutPromisingSuccessfulRetry() {
        assertTrue(recordingUploadErrorText("HTTP 403", en).contains("permission change"))
        assertTrue(recordingUploadErrorText("HTTP 409", ru).contains("сравните их с черновиком"))
        assertTrue(recordingUploadErrorText("HTTP 422", en).contains("indicated fields"))
        assertTrue(recordingUploadErrorText("HTTP 503", ru).contains("повторите позже"))
        assertTrue(recordingUploadErrorText("HTTP 404", en).contains("Preserve local originals"))
    }
    @Test fun replaySourceCannotBePresentedAsLiveSensorCapture() {
        assertEquals("Источник: запись с датчика", recordingSourceText("live", AppLanguage.RUSSIAN))
        assertEquals("Source: local file replay", recordingSourceText("replay", AppLanguage.ENGLISH))
        assertTrue(recordingSourceText("future_source", AppLanguage.RUSSIAN).contains("неизвестен (future_source)"))
    }

    @Test fun recoveryAndStorageErrorsExplainPreservedDataAndNextStep() {
        assertEquals(recordingUploadErrorText("artifact_hash_mismatch", ru), recordingUploadErrorText("hash_mismatch", ru))
        assertTrue(recordingUploadErrorText("storage_full", en).contains("preserved"))
        assertTrue(recordingUploadErrorText("storage_space_low", ru).contains("после освобождения"))
        assertTrue(recordingUploadErrorText("capture_recovery_requires_review", en).contains("automatic upload is paused"))
        assertTrue(recordingCaptureText("interrupted", "process_interrupted", null, en).contains("end time is not verified"))
    }

}
