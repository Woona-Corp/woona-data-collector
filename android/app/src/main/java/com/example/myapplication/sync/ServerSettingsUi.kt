package com.example.myapplication.sync

import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.heightIn
import androidx.compose.ui.window.DialogProperties
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.window.DialogWindowProvider
import android.view.WindowManager
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import com.example.myapplication.localization.AppLanguage

@Composable
fun ServerSettingsDialog(
    current: ServerSettings,
    language: AppLanguage,
    onDismiss: () -> Unit,
    onSave: (baseUrl: String, token: String) -> Unit,
    onDisconnect: (() -> Unit)? = null,
    canSave: Boolean = true,
    canDisconnect: Boolean = true,
    draft: ServerConnectionDraft = remember(current.baseUrl) { ServerConnectionDraft(current.baseUrl) },
) {
    var error by remember { mutableStateOf<String?>(null) }
    var confirmingDisconnect by remember { mutableStateOf(false) }
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(decorFitsSystemWindows = true)) {
        val view = LocalView.current
        DisposableEffect(view) {
            (view.parent as? DialogWindowProvider)?.window?.apply {
                setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
                setLayout(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT)
            }
            onDispose {}
        }
        Surface(modifier = Modifier.fillMaxSize()) {
            Column(
                modifier = Modifier.padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Column(
                    modifier = Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                Text(if (language == AppLanguage.RUSSIAN) "Подключение сервера" else "Server connection")
                OutlinedTextField(
                    value = draft.baseUrl,
                    onValueChange = { draft.baseUrl = it },
                    label = { Text("Server URL") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = draft.token,
                    onValueChange = { draft.token = it },
                    label = {
                        Text(
                            if (language == AppLanguage.RUSSIAN) {
                                "Новый токен"
                            } else {
                                "New token"
                            },
                        )
                    },
                    visualTransformation = PasswordVisualTransformation(),
                    singleLine = true,
                    isError = error != null,
                    supportingText = error?.let { { Text(it) } },
                    modifier = Modifier.fillMaxWidth(),
                )
                if (!canSave) Text(if (language == AppLanguage.RUSSIAN) "Изменение подключения доступно после завершения текущей операции. Отключить сервер можно, не удаляя локальные данные." else "Connection changes are available after the current operation. You can disconnect without deleting local data.")
                if (current.isConfigured && onDisconnect != null) TextButton(onClick = { confirmingDisconnect = true }, enabled = canDisconnect) {
                    Text(if (language == AppLanguage.RUSSIAN) "Отключить сервер и удалить токен" else "Disconnect server and remove token")
                }
                }
                // Actions stay outside the focused field's scroll/bring-into-view
                // region, so IME focus cannot immediately scroll them away again.
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(onClick = onDismiss, modifier = Modifier.weight(1f).heightIn(min = 48.dp)) {
                        Text(if (language == AppLanguage.RUSSIAN) "Отмена" else "Cancel")
                    }
                    Button(
                        enabled = canSave,
                        onClick = {
                            error = runCatching {
                                require(draft.token.isNotBlank()) {
                                    if (language == AppLanguage.RUSSIAN) "Введите токен" else "Enter token"
                                }
                                onSave(draft.baseUrl, draft.token)
                            }.exceptionOrNull()?.let { it.message ?: it.toString() }
                        },
                        modifier = Modifier.weight(1f).heightIn(min = 48.dp),
                    ) {
                        Text(if (language == AppLanguage.RUSSIAN) "Сохранить" else "Save")
                    }
                }
            }
        }
    }
    if (confirmingDisconnect) AlertDialog(
        onDismissRequest = { confirmingDisconnect = false },
        title = { Text(if (language == AppLanguage.RUSSIAN) "Отключить сервер?" else "Disconnect server?") },
        text = { Text(if (language == AppLanguage.RUSSIAN) "Токен будет удалён с этого устройства, текущие передачи остановятся. Локальные файлы, анкеты, очередь и подтверждённый прогресс сохранятся. Для продолжения снова укажите токен. Это не отзывает токен на сервере." else "The token will be removed from this device and current transfers will stop. Local files, questionnaires, queue and confirmed progress are preserved. Enter a token again to resume. This does not revoke the token on the server.") },
        confirmButton = { TextButton(onClick = { confirmingDisconnect = false; onDisconnect?.invoke() }, enabled = canDisconnect) { Text(if (language == AppLanguage.RUSSIAN) "Отключить" else "Disconnect") } },
        dismissButton = { TextButton(onClick = { confirmingDisconnect = false }) { Text(if (language == AppLanguage.RUSSIAN) "Отмена" else "Cancel") } },
    )

}
