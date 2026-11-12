package com.example.myapplication.storage

import android.content.ClipData
import android.content.Intent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
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
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import com.example.myapplication.data.createCompleteDataArchive
import com.example.myapplication.localization.AppLanguage
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineStart
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
    var saving by remember { mutableStateOf(false) }
    var saveProgress by remember { mutableStateOf<Pair<Long, Long>?>(null) }
    var error by rememberSaveable { mutableStateOf<String?>(null) }
    var saveError by rememberSaveable { mutableStateOf<String?>(null) }
    var status by rememberSaveable { mutableStateOf<String?>(null) }
    var archivePath by rememberSaveable { mutableStateOf<String?>(null) }
    val title = if (russian) "Полный архив данных" else "Complete data archive"
    val saveLauncher = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/zip")) { uri ->
        if (uri != null) {
            val ready = archivePath?.let(::File)
            if (ready == null) {
                error = if (russian) "Архив больше недоступен. Создайте его заново." else "The prepared archive is no longer available. Create it again."
            } else {
                saveError = null
                saveProgress = null
                saving = true
                val operation = scope.launch(start = CoroutineStart.LAZY) {
                    try {
                        withContext(Dispatchers.IO) {
                            val running = coroutineContext
                            var lastUpdate = 0L
                            copyCompleteArchive(ready, { application.contentResolver.openOutputStream(uri, "wt") },
                                checkCancelled = { running.ensureActive() }, onProgress = { copied, total ->
                                    val now = System.nanoTime()
                                    if (now - lastUpdate > 100_000_000 || copied == total) {
                                        saveProgress = copied to total
                                        lastUpdate = now
                                    }
                                })
                        }
                        archivePath = null
                        status = if (russian) "Архив сохранён в выбранное место." else "Archive saved to the selected location."
                        ready.delete()
                        ready.parentFile?.delete()
                    } catch (_: CancellationException) {
                        saveError = if (russian) "Сохранение отменено. В выбранном месте может остаться неполный файл. Исходные данные и подготовленный архив сохранены."
                            else "Saving was cancelled. The selected location may contain an incomplete file. Original data and the prepared archive are preserved."
                    } catch (failure: Exception) {
                        if (!ready.isFile) {
                            archivePath = null
                            error = if (russian) "Подготовленный архив больше недоступен. Исходные данные сохранены; создайте ZIP заново."
                                else "The prepared archive is no longer available. Original data is preserved; create the ZIP again."
                        } else {
                            saveError = (if (russian) "Не удалось сохранить ZIP. В выбранном месте может остаться неполный файл; исходные данные и подготовленный архив сохранены. Причина: "
                                else "Could not save the ZIP. The selected location may contain an incomplete file; original data and the prepared archive are preserved. Reason: ") + (failure.message ?: failure.javaClass.simpleName)
                        }
                    } finally { saving = false; job = null }
                }
                job = operation
                operation.start()
            }
        }
    }
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium)
            Text(if (russian) "Все доступные локальные данные всех животных и аккаунтов: база, версии анкет, записи, видео, исходники, логи и состояния загрузки. Исходные данные сохраняются. Удалённые файлы и данные только на сервере восстановить из этого архива нельзя. Токены доступа не включаются. Архив содержит анкеты и видео — выбирайте получателя внимательно."
                else "All available local data across every animal and account: database, questionnaire versions, recordings, video, source files, logs and upload states. Original data is preserved. Deleted and server-only files cannot be recovered from this archive. Access tokens are excluded. The archive contains questionnaires and videos; choose its recipient carefully.", style = MaterialTheme.typography.bodySmall)
            if (captureActive) Text(if (russian) "Сначала остановите запись и дождитесь сохранения файлов." else "Stop the recording and wait until its files are finalized.")
            Button(onClick = {
                error = null
                saveError = null
                status = null
                progress = null
                val operation = scope.launch(start = CoroutineStart.LAZY) {
                    var prepared: File? = null
                    try {
                        prepared = withContext(Dispatchers.IO) {
                            val running = coroutineContext
                            var lastUpdate = 0L
                            createCompleteDataArchive(application, captureActive = captureActive, checkCancelled = { running.ensureActive() }, onProgress = {
                                val now = System.nanoTime()
                                if (now - lastUpdate > 100_000_000 || it.completedFiles == it.totalFiles) {
                                    progress = it
                                    lastUpdate = now
                                }
                            }).also { prepared = it }
                        }
                        archivePath = prepared?.absolutePath
                    } catch (_: CancellationException) {
                        prepared?.parentFile?.deleteRecursively()
                    } catch (failure: Exception) {
                        error = (if (russian) "Архив не создан. Исходные данные сохранены. Причина: " else "Archive was not created. Original data is safe. Reason: ") + (failure.message ?: failure.javaClass.simpleName)
                    } finally { job = null }
                }
                job = operation
                operation.start()
            }, enabled = !captureActive && job == null, modifier = Modifier.testTag("archive.all.create")) {
                Text(if (russian) "Создать полный ZIP" else "Create complete ZIP")
            }
            error?.let { SelectionContainer { Text(it, color = MaterialTheme.colorScheme.error) } }
            status?.let { Text(it) }
        }
    }
    if (job != null) AlertDialog(
        onDismissRequest = {},
        title = { Text(title) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                val state = progress
                val copy = saveProgress
                Text(if (saving) {
                    if (copy == null) (if (russian) "Сохранение в выбранное место…" else "Saving to the selected location…")
                    else "${copy.first / 1024 / 1024}/${copy.second / 1024 / 1024} MB"
                } else if (state == null) (if (russian) "Проверка данных и создание снимка базы. Для временного ZIP нужно свободное место на телефоне…"
                    else "Checking data and creating database snapshot. The temporary ZIP requires free space on the phone…")
                    else "${state.completedFiles}/${state.totalFiles} · ${state.completedBytes / 1024 / 1024}/${state.totalBytes / 1024 / 1024} MB")
                LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                Text(if (saving) {
                    if (russian) "Оставьте приложение открытым. При отмене в выбранном месте может остаться неполный файл."
                    else "Keep the app open. Cancellation may leave an incomplete file at the selected location."
                } else if (russian) "Оставьте приложение открытым. Отмена удалит только недостроенный архив."
                    else "Keep the app open. Cancel removes only the unfinished archive.")
            }
        },
        confirmButton = { TextButton(onClick = { job?.cancel() }) { Text(if (russian) "Отменить" else "Cancel") } },
    )
    if (job == null) archivePath?.let { path ->
        val ready = File(path)
        AlertDialog(
            onDismissRequest = {
                discardCompleteArchive(ready)
                archivePath = null
            },
            title = { Text(if (russian) "Архив готов" else "Archive ready") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(if (russian) "${ready.length() / 1024 / 1024} MB. В manifest.json — список файлов, SHA-256 и перечень недоступных локально файлов. Выберите место сохранения или поделитесь ZIP."
                        else "${ready.length() / 1024 / 1024} MB. manifest.json lists files, SHA-256 checksums and files unavailable locally. Choose where to save the ZIP or share it.")
                    saveError?.let { SelectionContainer { Text(it, color = MaterialTheme.colorScheme.error) } }
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    try { saveLauncher.launch(ready.name) }
                    catch (failure: Exception) { saveError = failure.message ?: "Cannot open the system file picker" }
                }, modifier = Modifier.testTag("archive.all.save")) { Text(if (russian) "Выбрать место" else "Choose location") }
            },
            dismissButton = {
                Row {
                    TextButton(onClick = {
                        try {
                            val uri = FileProvider.getUriForFile(context, "${context.packageName}.provider", ready)
                            val intent = Intent(Intent.ACTION_SEND).setType("application/zip")
                                .putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                .apply { clipData = ClipData.newRawUri(ready.name, uri) }
                            context.startActivity(Intent.createChooser(intent, title))
                        } catch (failure: Exception) { saveError = failure.message ?: "Cannot open system share menu" }
                    }) { Text(if (russian) "Поделиться" else "Share") }
                    TextButton(onClick = {
                        discardCompleteArchive(ready)
                        archivePath = null
                    }) { Text(if (russian) "Закрыть" else "Close") }
                }
            },
        )
    }
}

internal fun discardCompleteArchive(archive: File) {
    archive.delete()
    archive.parentFile?.delete()
}
