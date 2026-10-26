package com.example.myapplication.sync

import com.example.myapplication.localization.AppLanguage

/** Interpret the stored HTTP error without changing retry, ownership or local data. */
fun serverSyncErrorText(message: String, language: AppLanguage): String {
    val conflict = message.startsWith("Server returned HTTP 409:") &&
        Regex("\"code\"\\s*:\\s*\"animal_id_already_exists\"")
            .containsMatchIn(message)
    if (!conflict) return message
    return if (language == AppLanguage.RUSSIAN) {
        "Этот ID животного уже закреплён за другой карточкой. Проверьте аккаунт, нажмите «Восстановить с сервера» и выберите существующую собаку. Локальные записи сохранены. Смена клички не освобождает ID. Если карточка не найдена, сохраните экспорт для сверки."
    } else {
        "This animal ID already belongs to another profile. Check the account, restore from server and select the existing dog. Local recordings are preserved; changing the name does not release the ID. If the profile is unavailable, save an export for reconciliation."
    }
}
