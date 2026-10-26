package com.example.myapplication.storage

import android.content.ClipData
import android.content.Intent
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import com.example.myapplication.data.createCompleteDataArchive
import com.example.myapplication.localization.AppLanguage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

@Composable
fun CompleteArchiveCard(language: AppLanguage, captureActive: Boolean) {
    val russian = language == AppLanguage.RUSSIAN
    val context = LocalContext.current
    val application = context.applicationContext
    val scope = rememberCoroutineScope()
    var job by remember { mutableStateOf<Job?>(null) }
    var progress by remember { mutableStateOf<CompleteArchiveExporter.Progress?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var archive by remember { mutableStateOf<File?>(null) }
    val title = if (russian) "Полный архив данных" else "Complete data archive"
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            Text(if (russian) "Все доступные локальные данные всех животных и аккаунтов: база, версии анкет, записи, видео, исходники, логи и состояния загрузки. Исходные данные сохраняются. Удалённые файлы и данные только на сервере восстановить из этого архива нельзя. Токены доступа не включаются. Архив содержит анкеты и видео — выбирайте получателя внимательно."
                else "All available local data across every animal and account: database, questionnaire versions, recordings, video, source files, logs and upload states. Original data is preserved. Deleted and server-only files cannot be recovered from this archive. Access tokens are excluded. The archive contains questionnaires and videos; choose its recipient carefully.", style = MaterialTheme.typography.bodySmall)
            if (captureActive) Text(if (russian) "Сначала остановите запись и дождитесь сохранения файлов." else "Stop the recording and wait until its files are finalized.")
            Button(onClick = {
                error = null
                progress = null
                job = scope.launch {
                    var prepared: File? = null
                    try {
                        prepared = withContext(Dispatchers.IO) {
                            val running = coroutineContext
                            var lastUpdate = 0L
                            createCompleteDataArchive(application, checkCancelled = { running.ensureActive() }, onProgress = {
                                val now = System.nanoTime()
                                if (now - lastUpdate > 100_000_000 || it.completedFiles == it.totalFiles) {
                                    progress = it
                                    lastUpdate = now
                                }
                            }).also { prepared = it }
                        }
                        archive = prepared
                    } catch (_: CancellationException) {
                        prepared?.parentFile?.deleteRecursively()
                    } catch (failure: Exception) {
                        error = (if (russian) "Архив не создан. Исходные данные сохранены. Причина: " else "Archive was not created. Original data is safe. Reason: ") + (failure.message ?: failure.javaClass.simpleName)
                    } finally { job = null }
                }
            }, enabled = !captureActive && job == null, modifier = Modifier.testTag("archive.all.create")) {
                Text(if (russian) "Создать полный ZIP" else "Create complete ZIP")
            }
            error?.let { SelectionContainer { Text(it, color = MaterialTheme.colorScheme.error) } }
        }
    }
    if (job != null) AlertDialog(
        onDismissRequest = {},
        title = { Text(title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                val state = progress
                Text(if (state == null) (if (russian) "Проверка данных и создание снимка базы…" else "Checking data and creating database snapshot…")
                    else "${state.completedFiles}/${state.totalFiles} · ${state.completedBytes / 1024 / 1024}/${state.totalBytes / 1024 / 1024} MB")
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                Text(if (russian) "Оставьте приложение открытым. Отмена удалит только недостроенный архив." else "Keep the app open. Cancel removes only the unfinished archive.")
            }
        },
        confirmButton = { TextButton(onClick = { job?.cancel() }) { Text(if (russian) "Отменить" else "Cancel") } },
    )
    archive?.let { ready ->
        AlertDialog(
            onDismissRequest = { archive = null },
            title = { Text(if (russian) "Архив готов" else "Archive ready") },
            text = { Text(if (russian) "${ready.length() / 1024 / 1024} MB. В manifest.json — список файлов, SHA-256, количество объектов и перечень недоступных локально файлов. Сохраните ZIP через системное меню."
                else "${ready.length() / 1024 / 1024} MB. manifest.json lists files, SHA-256 checksums, database counts and files unavailable locally. Save the ZIP using the system share menu.") },
            confirmButton = {
                TextButton(onClick = {
                    try {
                        val uri = FileProvider.getUriForFile(context, "${context.packageName}.provider", ready)
                        val intent = Intent(Intent.ACTION_SEND).setType("application/zip")
                            .putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            .apply { clipData = ClipData.newRawUri(ready.name, uri) }
                        context.startActivity(Intent.createChooser(intent, title))
                        archive = null
                    } catch (failure: Exception) { error = failure.message ?: "Cannot open system share menu"; archive = null }
                }) { Text(if (russian) "Сохранить / поделиться" else "Save / share") }
            },
            dismissButton = { TextButton(onClick = { archive = null }) { Text(if (russian) "Закрыть" else "Close") } },
        )
    }
}
