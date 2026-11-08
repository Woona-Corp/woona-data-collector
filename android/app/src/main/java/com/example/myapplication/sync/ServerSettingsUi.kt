package com.example.myapplication.sync

import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.Alignment
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
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import com.example.myapplication.localization.AppLanguage

@OptIn(ExperimentalFoundationApi::class)
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
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(decorFitsSystemWindows = false)) {
        val view = LocalView.current
        DisposableEffect(view) {
            (view.parent as? DialogWindowProvider)?.window?.apply {
                setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
                setLayout(WindowManager.LayoutParams.MATCH_PARENT, WindowManager.LayoutParams.MATCH_PARENT)
            }
            onDispose {}
        }
        // Own insets in Compose, not in DecorView: ADJUST_RESIZE alone leaves
        // this dialog full-height on Android 16 / target 36. safeDrawing is the
        // UNION of system bars, cutout and IME, so navigation/IME overlap is
        // removed once, not added twice. Apply it outside the entire form and
        // footer; only the weighted scroll body then shrinks for the keyboard.
        // Keep native window measurement (default usePlatformDefaultWidth),
        // not Compose 1.7's display-configuration-based fullscreen measurement.
        Surface(modifier = Modifier.fillMaxSize().safeDrawingPadding()) {
            BoxWithConstraints(Modifier.fillMaxSize()) {
            val compact = maxHeight < 360.dp * LocalDensity.current.fontScale
            val wide = compact && maxWidth > maxHeight * 2
            val urlRequester = remember { BringIntoViewRequester() }
            val tokenRequester = remember { BringIntoViewRequester() }
            var focusedField by remember { mutableStateOf<String?>(null) }
            // A viewport change can occur after the focus/text event, when the
            // IME animates in. Re-request for that geometry, not on a timer.
            LaunchedEffect(maxHeight, focusedField) {
                when (focusedField) {
                    "url" -> urlRequester.bringIntoView()
                    "token" -> tokenRequester.bringIntoView()
                }
            }
            val actions: @Composable androidx.compose.foundation.layout.RowScope.() -> Unit = {
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
                ) { Text(if (language == AppLanguage.RUSSIAN) "Сохранить" else "Save") }
            }
            // In wide compact windows, reserve scarce height for the complete
            // editor instead of decorative outer padding; safe insets stay intact.
            Column(
                modifier = Modifier.fillMaxSize().padding(horizontal = if (compact) 12.dp else 20.dp, vertical = if (wide) 0.dp else if (compact) 4.dp else 20.dp),
                verticalArrangement = Arrangement.spacedBy(if (compact) 4.dp else 12.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(if (language == AppLanguage.RUSSIAN) "Подключение сервера" else "Server connection",
                        style = if (compact) androidx.compose.material3.MaterialTheme.typography.titleSmall else androidx.compose.material3.MaterialTheme.typography.titleLarge,
                        modifier = Modifier.weight(1f))
                    if (wide) actions()
                }
                Column(
                    modifier = Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                Text(if (language == AppLanguage.RUSSIAN) "Без сети файлы, анкеты и очередь сохраняются на телефоне. Подключение сервера возобновит доставку; оно не удаляет локальные данные." else "Offline, files, questionnaires and the queue remain on this phone. Connecting resumes delivery; it does not delete local data.")
                OutlinedTextField(
                    value = draft.baseUrl,
                    onValueChange = { draft.baseUrl = it },
                    label = { Text(if (language == AppLanguage.RUSSIAN) "Адрес сервера" else "Server URL") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth().bringIntoViewRequester(urlRequester).onFocusChanged {
                        if (it.isFocused) focusedField = "url" else if (focusedField == "url") focusedField = null
                    },
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
                    // Masking alone does not make the IME a password editor:
                    // a text keyboard can suggest/learn the raw credential.
                    keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, keyboardType = KeyboardType.Password),
                    singleLine = true,
                    isError = error != null,
                    supportingText = error?.let { { Text(syncFailureSummary(it, language)) } },
                    modifier = Modifier.fillMaxWidth().bringIntoViewRequester(tokenRequester).onFocusChanged {
                        if (it.isFocused) focusedField = "token" else if (focusedField == "token") focusedField = null
                    },
                )
                error?.let { SyncDetails(if (language == AppLanguage.RUSSIAN) "Подробности" else "Details", it) }
                if (!canSave) Text(if (language == AppLanguage.RUSSIAN) "Изменение подключения доступно после завершения текущей операции. Отключить сервер можно, не удаляя локальные данные." else "Connection changes are available after the current operation. You can disconnect without deleting local data.")
                if (current.isConfigured && onDisconnect != null) TextButton(onClick = { confirmingDisconnect = true }, enabled = canDisconnect) {
                    Text(if (language == AppLanguage.RUSSIAN) "Отключить сервер и удалить токен" else "Disconnect server and remove token")
                }
                }
                // Actions stay outside the focused field's scroll/bring-into-view
                // region, so IME focus cannot immediately scroll them away again.
                if (!wide) Row(horizontalArrangement = Arrangement.spacedBy(8.dp), content = actions)
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
