package com.example.myapplication.storage

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.example.myapplication.localization.AppLanguage

@Composable
fun StartupRecoveryScreen(language: AppLanguage, running: Boolean, error: String?, onRetry: () -> Unit) {
    val ru = language == AppLanguage.RUSSIAN
    Surface(modifier = Modifier.fillMaxSize()) {
        Column(modifier = Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text(if (ru) "Восстановление локальных данных" else "Recovering local data", style = MaterialTheme.typography.headlineSmall)
            Text(if (ru) "Проверяем файлы прерванной записи и считаем контрольные суммы. Большое видео может занять время. Новая запись станет доступна после завершения проверки. Исходные файлы сохраняются." else "Checking interrupted recording files and calculating checksums. Large videos can take time. Capture becomes available after this check. Original files are preserved.")
            if (running) LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
            error?.let {
                Text(if (ru) "Восстановление не завершено. Новая запись заблокирована. Устраните указанную причину и повторите проверку.\n$it" else "Recovery did not complete. New capture is blocked. Resolve the cause below and retry.\n$it", color = MaterialTheme.colorScheme.error)
                Button(onClick = onRetry, enabled = !running) { Text(if (ru) "Повторить проверку" else "Retry recovery") }
            }
        }
    }
}
