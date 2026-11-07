package com.example.myapplication.sync

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.example.myapplication.localization.AppLanguage
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Actual bounded events only. Disk reads are off the UI thread and expansion is stable by entity. */
@Composable
fun SyncActivityHistory(kind: String, id: String, language: AppLanguage, refreshKey: Any? = null) {
    val context = LocalContext.current.applicationContext
    var expanded by remember(kind, id) { mutableStateOf(false) }
    var refresh by remember(kind, id) { mutableIntStateOf(0) }
    var events by remember(kind, id) { mutableStateOf<List<SyncActivityEvent>>(emptyList()) }
    var loading by remember(kind, id) { mutableStateOf(false) }
    fun text(en: String, ru: String) = if (language == AppLanguage.RUSSIAN) ru else en
    LaunchedEffect(kind, id, expanded, refresh, refreshKey) {
        if (expanded) {
            loading = true
            try { events = withContext(Dispatchers.IO) { SyncActivityLog.recent(context, kind, id) } }
            finally { loading = false }
        }
    }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.testTag("sync.activity.$kind.$id")) {
        TextButton(onClick = { expanded = !expanded }) {
            Text((if (expanded) "− " else "+ ") + text("Sync activity", "Журнал синхронизации"))
        }
        if (expanded) {
            Text(text("Recent recorded events, not a complete audit history. Events before this update or not written before process exit may be absent.",
                "Последние сохранённые события, не полный аудит. События до обновления или не записанные до закрытия процесса могут отсутствовать."), style = MaterialTheme.typography.bodySmall)
            if (loading) Text(text("Loading…", "Загружаем…"))
            else if (events.isEmpty()) Text(text("No recorded events for this item yet.", "Для этого объекта пока нет сохранённых событий."))
            else events.forEach { event ->
                val timestamp = runCatching { DateTimeFormatter.ofPattern("dd.MM.yyyy HH:mm:ss").withZone(ZoneId.systemDefault()).format(Instant.parse(event.timestampUtc)) }.getOrDefault(event.timestampUtc)
                SelectionContainer {
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text("$timestamp · ${syncActivityActionLabel(event.action, language)}", style = MaterialTheme.typography.labelMedium)
                        Text(syncActivityOutcomeLabel(event.outcome, language), style = MaterialTheme.typography.bodySmall)
                        event.code?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                    }
                }
            }
            TextButton(onClick = { refresh++ }, enabled = !loading) { Text(text("Refresh events", "Обновить события")) }
        }
    }
}

/** The caller resolves the exact recording artifact; no path or network is inferred by UI. */
@Composable
fun CaptureDiagnosticDetails(recordingId: String, language: AppLanguage, load: suspend () -> String?) {
    var expanded by remember(recordingId) { mutableStateOf(false) }
    var content by remember(recordingId) { mutableStateOf<String?>(null) }
    var loading by remember(recordingId) { mutableStateOf(false) }
    fun text(en: String, ru: String) = if (language == AppLanguage.RUSSIAN) ru else en
    LaunchedEffect(recordingId, expanded) {
        if (expanded) {
            loading = true
            try { content = withContext(Dispatchers.IO) { runCatching { load() }.getOrNull() } }
            finally { loading = false }
        }
    }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        TextButton(onClick = { expanded = !expanded }) { Text((if (expanded) "− " else "+ ") + text("Capture log", "Журнал записи")) }
        if (expanded) {
            Text(text("Bounded preview of the saved diagnostic file; original files are unchanged.", "Ограниченный просмотр сохранённого журнала. Исходные файлы не изменяются."), style = MaterialTheme.typography.bodySmall)
            if (loading) Text(text("Loading…", "Загружаем…"))
            else SelectionContainer { Text(content?.let(::redactSyncDetails) ?: text("No readable capture log on this device. A server-only file must be downloaded first.", "Читаемого журнала на устройстве нет. Файл, доступный только на сервере, сначала нужно скачать."), style = MaterialTheme.typography.bodySmall) }
        }
    }
}
