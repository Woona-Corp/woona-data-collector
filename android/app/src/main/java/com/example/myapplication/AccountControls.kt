package com.example.myapplication

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.example.myapplication.data.DogProfile
import com.example.myapplication.localization.AppLanguage

@Composable
fun AccountControls(accountId: String?, language: AppLanguage, enabled: Boolean, unassigned: List<DogProfile>, onApply: (String) -> Unit, onLink: (String) -> Unit, localHistorySummary: String? = null) {
    fun label(en: String, ru: String) = if (language == AppLanguage.RUSSIAN) ru else en
    var identifier by rememberSaveable(accountId) { mutableStateOf(accountId.orEmpty()) }
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedTextField(value = identifier, onValueChange = { identifier = it }, label = { Text(label("Data account", "Аккаунт данных")) },
            supportingText = { Text(label("Data scope, not sign-in. Empty means unassigned.", "Выбор данных, не вход в систему. Пусто — без аккаунта.")) },
            singleLine = true, enabled = enabled, modifier = Modifier.fillMaxWidth())
        Button(onClick = { onApply(identifier) }, enabled = enabled) { Text(label("Apply account", "Применить аккаунт")) }
        Text(label("Active scope: ${accountId ?: "unassigned"}", "Активные данные: ${accountId ?: "без аккаунта"}"), style = MaterialTheme.typography.bodySmall)
        localHistorySummary?.let { summary ->
            com.example.myapplication.sync.SyncDetails(label("Data scope details", "Подробности выбора данных"), summary)
        }
        if (accountId != null && unassigned.isNotEmpty()) {
            Text(label("Unassigned dogs. Linking moves all this dog’s sessions into this account.", "Собаки без аккаунта. Связывание перенесёт все сессии собаки в этот аккаунт."))
            unassigned.forEach { dog ->
                OutlinedButton(onClick = { onLink(dog.id) }, enabled = enabled) { Text(label("Link ${dog.numberOrName}", "Связать ${dog.numberOrName}")) }
            }
        }
    }
}
