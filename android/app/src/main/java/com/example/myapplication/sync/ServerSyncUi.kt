package com.example.myapplication.sync

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import com.example.myapplication.localization.AppLanguage

/** Evidence is opt-in, selectable and redacted; expansion is local to this item. */
@Composable
fun SyncDetails(title: String, details: String, modifier: Modifier = Modifier) {
    var expanded by remember(details) { mutableStateOf(false) }
    Column(modifier) {
        TextButton(onClick = { expanded = !expanded }) { Text((if (expanded) "− " else "+ ") + title) }
        if (expanded) SelectionContainer { Text(redactSyncDetails(details), style = MaterialTheme.typography.bodySmall) }
    }
}

@Composable
fun ServerSyncSettingsCard(
    state: ServerSyncUiState,
    language: AppLanguage,
    onConfigure: () -> Unit,
    onWifiOnlyChange: (Boolean) -> Unit,
    onRetryPending: () -> Unit,
    onRestore: () -> Unit,
    onCheck: () -> Unit,
    onStorageCheck: () -> Unit,
) {
    fun text(en: String, ru: String) = if (language == AppLanguage.RUSSIAN) ru else en
    Card(Modifier.fillMaxWidth().testTag("server.sync.settings"), colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(text("Server storage", "Серверное хранилище"), style = MaterialTheme.typography.titleMedium)
            // Configuration and last check are separate facts, not a live availability claim.
            Text(text("Connection", "Подключение"), style = MaterialTheme.typography.titleSmall)
            Text(if (state.isConfigured) redactSyncDetails(state.baseUrl) else text("Not configured", "Не настроено"))
            Text(state.connectionCheck.label(language))
            state.checkedAtUtc?.let { Text(text("Checked: $it", "Проверено: $it"), style = MaterialTheme.typography.bodySmall) }
            Text(text("Account: ${state.accountId ?: "unassigned"}", "Аккаунт: ${state.accountId ?: "без аккаунта"}"))
            OutlinedButton(onClick = onConfigure, enabled = state.connectionEditorAllowed, modifier = Modifier.fillMaxWidth()) {
                Text(if (state.isConfigured) text("Reconnect", "Переподключить") else text("Connect", "Подключить"))
            }
            OutlinedButton(onClick = onCheck, enabled = state.isConfigured && state.connectionCheck != ConnectionCheck.CHECKING, modifier = Modifier.fillMaxWidth()) {
                Text(text("Check connection", "Проверить соединение"))
            }
            HorizontalDivider()
            if (!state.isConfigured || state.networkAvailable == false || state.wifiOnly && state.unmeteredNetwork == false) {
                Text(if (!state.isConfigured) text("Server not connected", "Сервер не подключён") else text("Waiting for network", "Ожидает сети"), style = MaterialTheme.typography.titleSmall)
                Text(text("Offline work is preserved on this phone. Files, questionnaires and the upload queue are not deleted when the server is unavailable.", "Работа без сети сохраняется на телефоне. Файлы, анкеты и очередь отправки не удаляются, когда сервер недоступен."))
            }
            Text(state.queueExplanation(language))
            Text(text("Queue · all local accounts", "Очередь · все локальные аккаунты"), style = MaterialTheme.typography.titleSmall)
            Text(text("Pending: ${state.pending}\nUploading: ${state.uploading}\nUpload confirmed: ${state.synced}\nNeeds attention: ${state.failed}", "Ожидают: ${state.pending}\nОтправляются: ${state.uploading}\nЗагрузка подтверждена: ${state.synced}\nНужно исправить: ${state.failed}"))
            Text(text("Each profile and recording uploads to its own account. Confirmed uploads do not verify capture quality.", "Каждая карточка и запись отправляется в свой аккаунт. Подтверждение загрузки не проверяет качество записи."), style = MaterialTheme.typography.bodySmall)
            Row(Modifier.fillMaxWidth()) {
                Text(text("Wi-Fi only", "Только по Wi-Fi"), modifier = Modifier.weight(1f))
                Switch(checked = state.wifiOnly, onCheckedChange = onWifiOnlyChange, enabled = state.isConfigured && state.networkPolicyAllowed)
            }
            if (!state.mutationsAllowed) Text(state.mutationBlockExplanation(language))
            state.lastErrorMessage?.takeIf { state.failed > 0 }?.let {
                Text(text("Upload not completed: ", "Отправка не завершена: ") + syncFailureSummary(it, language))
            }
            state.connectionError?.let { Text(text("Connection check failed: ", "Проверка соединения не прошла: ") + syncFailureSummary(it, language)) }
            OutlinedButton(onClick = onRetryPending, enabled = state.isConfigured && state.mutationsAllowed && state.pending + state.failed > 0, modifier = Modifier.fillMaxWidth()) {
                Text(text("Retry uploads", "Повторить выгрузку"))
            }
            OutlinedButton(onClick = onRestore, enabled = state.isConfigured && state.mutationsAllowed && !state.restoring, modifier = Modifier.fillMaxWidth()) {
                Text(if (state.restoring) text("Restoring…", "Восстановление…") else text("Restore from server", "Восстановить с сервера"))
            }
            ServerStorageSection(state.storage, state.isConfigured, language, onStorageCheck)
            val details = listOfNotNull(state.connectionError, state.lastErrorMessage, state.operationMessage,
                text("Background jobs: ${state.workersRunning} running, ${state.workersQueued} queued", "Фоновые задачи: ${state.workersRunning} выполняются, ${state.workersQueued} ожидают")).joinToString("\n\n")
            SyncDetails(text("Details", "Подробности"), details)
        }
    }
}
