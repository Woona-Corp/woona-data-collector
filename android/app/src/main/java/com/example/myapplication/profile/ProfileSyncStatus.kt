package com.example.myapplication.profile

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.unit.dp
import com.example.myapplication.localization.AppLanguage
import com.example.myapplication.sync.SyncDetails
import com.example.myapplication.sync.syncFailureSummary

/** A snapshot for this exact immutable profile version, not the animal's recordings. */
data class ProfileSyncUiStatus(
    val syncState: String,
    val errorCode: String? = null,
    val errorMessage: String? = null,
    val confirmedAtUtc: String? = null,
    val attemptCount: Int = 0,
)

@Composable
fun ProfileSyncStatus(status: ProfileSyncUiStatus?, language: AppLanguage) {
    fun text(en: String, ru: String) = if (language == AppLanguage.RUSSIAN) ru else en
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        val summary = when (status?.syncState) {
            "pending" -> text("Profile saved locally · waiting to send", "Карточка сохранена локально · ожидает отправки")
            "uploading" -> text("Profile is being sent", "Карточка отправляется")
            "synced", "complete" -> text("This profile version was accepted by the server", "Эта версия карточки принята сервером")
            "retryable_error" -> text("Profile saved locally · waiting to retry", "Карточка сохранена локально · ожидает повтора")
            "permanent_error" -> text("Needs attention · profile not accepted", "Нужно исправить · карточка не принята")
            "remote" -> text("Profile restored from server", "Карточка восстановлена с сервера")
            else -> text("Profile delivery has not been confirmed", "Доставка карточки не подтверждена")
        }
        Text(summary, style = MaterialTheme.typography.bodySmall)
        if (status?.syncState == "synced") status.confirmedAtUtc?.let { stamp ->
            val localTime = runCatching {
                java.time.format.DateTimeFormatter.ofPattern("dd.MM.yyyy HH:mm").withZone(java.time.ZoneId.systemDefault()).format(java.time.Instant.parse(stamp))
            }.getOrDefault(stamp)
            Text(text("Confirmed: $localTime", "Подтверждено: $localTime"), style = MaterialTheme.typography.bodySmall)
        }
        if (status?.syncState in setOf("retryable_error", "permanent_error")) {
            val raw = listOfNotNull(status?.errorCode, status?.errorMessage).joinToString("\n")
            val conflict = status?.errorCode == "animal_id_already_exists" ||
                Regex("\"code\"\\s*:\\s*\"animal_id_already_exists\"").containsMatchIn(raw)
            Text(if (conflict) text(
                "Another profile already uses this ID. This new profile was not accepted. Restore profiles from server and select the existing animal. Local data is preserved; renaming does not resolve the conflict.",
                "Другая карточка уже использует этот ID. Сервер не принял новую карточку. Восстановите карточки с сервера и выберите существующее животное. Локальные данные сохранены; смена клички не устраняет конфликт.",
            ) else syncFailureSummary(raw, language), style = MaterialTheme.typography.bodySmall)
            if (raw.isNotBlank()) SyncDetails(text("Details", "Подробности"), raw)
        }
    }
}
