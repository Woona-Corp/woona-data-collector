package com.example.myapplication.sync

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.example.myapplication.localization.AppLanguage
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter

@Composable
fun ServerStorageSection(state: ServerStorageUiState, configured: Boolean, language: AppLanguage, onCheck: () -> Unit) {
    fun text(ru: String, en: String) = if (language == AppLanguage.RUSSIAN) ru else en
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(text("Место и лимиты сервера", "Server storage and limits"), style = MaterialTheme.typography.titleSmall)
        Text(when {
            !configured -> text("Подключите сервер, чтобы проверить место и лимиты.", "Connect the server to check storage and limits.")
            state.check == StorageCheck.NOT_CHECKED -> text("Место и лимиты ещё не проверены.", "Storage and limits have not been checked yet.")
            state.check == StorageCheck.CHECKING -> text("Проверяем место и лимиты…", "Checking storage and limits…")
            state.check == StorageCheck.UNAVAILABLE -> text("Эта версия сервера не поддерживает проверку места и лимитов. Проверка соединения доступна отдельно.", "This server version does not support storage and limits checks. Connection checks remain available separately.")
            state.check == StorageCheck.FAILED -> text("Не удалось проверить место и лимиты. Повторите проверку; локальные данные сохранены.", "Storage and limits could not be checked. Retry; local data is preserved.")
            else -> text("Место и лимиты проверены на момент запроса.", "Storage and limits were checked at the time of this request.")
        }, style = MaterialTheme.typography.bodySmall)
        if (state.check == StorageCheck.CHECKING) LinearProgressIndicator(Modifier.fillMaxWidth())
        state.checkedAtUtc?.let { raw ->
            val local = runCatching { DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss z").withZone(ZoneId.systemDefault()).format(Instant.parse(raw)) }.getOrDefault(raw)
            Text(text("Проверено: ", "Checked: ") + local, style = MaterialTheme.typography.bodySmall)
        }
        state.error?.let { raw -> SelectionContainer {
            val explanation = if (state.check == StorageCheck.UNAVAILABLE) raw else com.example.myapplication.localization.recordingUploadErrorText(raw, language)
            Text(if (explanation == raw) raw else "$explanation\n$raw", color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
        } }
        state.result?.let { value ->
            fun size(bytes: Long?, limit: Boolean = false) = storageGiB(bytes, language, limit)
            Text(text("Аккаунт: ", "Account: ") + (value.accountId ?: text("без аккаунта", "unassigned")))
            Text(storageAdmissionText(value.status, language))
            Text(text("Лимит аккаунта: ", "Account limit: ") + size(value.accountLimitBytes, true))
            Text(text("Заявлено и зарезервировано аккаунтом: ", "Declared and reserved by account: ") + size(value.declaredReservedBytes))
            Text(text("Принято данных аккаунта (объём): ", "Account data received (volume): ") + size(value.acknowledgedBytes))
            Text(text("Осталось по лимиту аккаунта: ", "Remaining account quota: ") + size(value.remainingQuotaBytes))
            Text(text("Лимит одной записи: ", "Per-recording limit: ") + size(value.recordingLimitBytes, true))
            Text(text("Записей: ${value.recordings} · файлов: ${value.artifacts}", "Recordings: ${value.recordings} · artifacts: ${value.artifacts}"))
            Text(text("Сервер целиком — всего: ", "Entire server — total: ") + size(value.serverTotalBytes))
            Text(text("Сервер целиком — свободно на диске: ", "Entire server — free on disk: ") + size(value.serverFreeBytes))
            Text(text("Сервер целиком — резерв свободного места: ", "Entire server — free-space reserve: ") + size(value.freeSpaceReserveBytes))
            Text(text("Сервер целиком — зарезервировано загрузками: ", "Entire server — reserved by uploads: ") + size(value.pendingReservedBytes))
            Text(text("Сервер целиком — незавершённых файлов: ", "Entire server — unfinished artifacts: ") + value.pendingArtifacts)
            Text(text("Сервер целиком — доступно новым загрузкам: ", "Entire server — available for new uploads: ") + size(value.newReservationAvailableBytes))
            if (value.blockingReasons.isNotEmpty()) Text(text("Причины ограничений: ", "Admission restrictions: ") + value.blockingReasons.joinToString("; ") { storageAdmissionText(it, language) })
            Text(text("Следующее действие: ", "Next action: ") + nextTransferActionText(value.nextAction, language == AppLanguage.RUSSIAN))
            Text(text("Лимиты учитывают заявленные байты незавершённых загрузок. Эти объёмы не подтверждают целостность файлов.", "Quotas include declared bytes of unfinished uploads. These volumes do not verify file integrity."), style = MaterialTheme.typography.bodySmall)
            if (value.existingUploadsMayResume) Text(text("Ранее принятые загрузки могут продолжаться.", "Previously accepted uploads may resume."), style = MaterialTheme.typography.bodySmall)
        }
        OutlinedButton(onClick = onCheck, enabled = configured && state.check != StorageCheck.CHECKING) {
            Text(if (state.check in setOf(StorageCheck.FAILED, StorageCheck.UNAVAILABLE)) text("Повторить проверку места", "Retry storage check") else text("Проверить место на сервере", "Check server storage"))
        }
    }
}
