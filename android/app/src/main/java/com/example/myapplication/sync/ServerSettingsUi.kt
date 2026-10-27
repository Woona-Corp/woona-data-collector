package com.example.myapplication.sync

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
) {
    var baseUrl by remember(current.baseUrl) { mutableStateOf(current.baseUrl) }
    var token by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var confirmingDisconnect by remember { mutableStateOf(false) }
    Dialog(onDismissRequest = onDismiss) {
        Surface {
            Column(
                modifier = Modifier.padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(if (language == AppLanguage.RUSSIAN) "Подключение сервера" else "Server connection")
                OutlinedTextField(
                    value = baseUrl,
                    onValueChange = { baseUrl = it },
                    label = { Text("Server URL") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = token,
                    onValueChange = { token = it },
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
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(onClick = onDismiss, modifier = Modifier.weight(1f)) {
                        Text(if (language == AppLanguage.RUSSIAN) "Отмена" else "Cancel")
                    }
                    Button(
                        enabled = canSave,
                        onClick = {
                            error = runCatching {
                                require(token.isNotBlank()) {
                                    if (language == AppLanguage.RUSSIAN) "Введите токен" else "Enter token"
                                }
                                onSave(baseUrl, token)
                            }.exceptionOrNull()?.toString()
                        },
                        modifier = Modifier.weight(1f),
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
