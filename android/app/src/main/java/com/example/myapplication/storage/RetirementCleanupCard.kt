package com.example.myapplication.storage

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.example.myapplication.data.*
import com.example.myapplication.localization.AppLanguage
import com.example.myapplication.sync.ServerSyncUiState
import com.example.myapplication.sync.serverOperationLock
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.concurrent.withLock

@Composable
fun RetirementCleanupCard(language: AppLanguage, state: ServerSyncUiState, captureActive: Boolean) {
    val ru=language==AppLanguage.RUSSIAN
    val context=LocalContext.current.applicationContext
    val scope=rememberCoroutineScope()
    var running by remember { mutableStateOf(false) }
    var status by remember { mutableStateOf<RetirementCleanupStatus?>(null) }
    var failure by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(state.retirementCleanupPending,state.retirementCleanupError,state.retirementDeferred,state.retirementChecking) {
        status=RetirementCleanupStatus(state.retirementCleanupPending,state.retirementCleanupError,state.retirementDeferred)
    }
    val current=status?:RetirementCleanupStatus(state.retirementCleanupPending,state.retirementCleanupError,state.retirementDeferred)
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp),verticalArrangement=Arrangement.spacedBy(10.dp)) {
            Text(if(ru) "Очистка по удалениям сервера" else "Server retirement cleanup",style=MaterialTheme.typography.titleMedium)
            Text(if(ru) "Это выполнение уже подтверждённого удаления везде. Ошибка очистки файлов не отменяет удаление серверной истории. Активная запись и используемые версии анкет защищены до завершения записи или освобождения связей." else "This applies an already confirmed deletion everywhere. A file cleanup error does not undo retirement of server history. Active capture and referenced profile versions remain protected until capture finishes or references are released.",style=MaterialTheme.typography.bodySmall)
            Text(if(ru) "Ожидает очистки файлов: ${current.pending}. Отложено из-за активной записи или связей: ${current.deferredCount}." else "Waiting for file cleanup: ${current.pending}. Deferred by active capture or references: ${current.deferredCount}.")
            if(state.retirementChecking) Text(if(ru) "Проверяем серверные удаления. Это служебная проверка, файлы не выгружаются." else "Checking server retirements. This is maintenance; recording files are not being uploaded.")
            state.retirementNetworkError?.let { detail -> SelectionContainer { Text((if(ru) "Не удалось проверить серверные удаления. Подключитесь к серверу и повторите действие; исходные локальные данные сохранены.\n" else "Could not check server retirements. Connect to the server and retry; original local data is preserved.\n")+detail,color=MaterialTheme.colorScheme.error) } }
            (failure?:current.lastError)?.let { detail -> SelectionContainer { Text((if(ru) "Очистка не завершена; задача сохранена для повторной попытки. Устраните причину и повторите очистку.\n" else "Cleanup did not complete; its durable task is preserved. Resolve the cause and retry.\n")+detail,color=MaterialTheme.colorScheme.error) } }
            if(running) LinearProgressIndicator(Modifier.fillMaxWidth())
            TextButton(onClick={
                running=true;failure=null
                scope.launch {
                    try {
                        status=withContext(Dispatchers.IO) { serverOperationLock.withLock {
                            check(!isCompleteArchiveExporting) { "Wait for archive export to finish / Дождитесь завершения экспорта" }
                            WoonaDatabase(context).use { db -> db.applyServerDeletions(emptyList());db.retirementCleanupStatus() }
                        } }
                    } catch(cancelled:kotlinx.coroutines.CancellationException) {throw cancelled}
                    catch(error:Exception) {failure=error.message?:error.javaClass.simpleName}
                    finally {running=false}
                }
            },enabled=!running&&!captureActive&&state.connectionEditorAllowed&&(current.pending+current.deferredCount>0)) {
                Text(if(ru) "Повторить локальную очистку" else "Retry local cleanup")
            }
        }
    }
}
