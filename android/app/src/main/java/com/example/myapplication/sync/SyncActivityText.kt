package com.example.myapplication.sync

import com.example.myapplication.localization.AppLanguage

/** Labels only. Unknown strings never echo potentially unsafe persisted input. */
fun syncActivityActionLabel(value: String, language: AppLanguage): String {
    val ru = language == AppLanguage.RUSSIAN
    return when (value) {
        "local_saved" -> if (ru) "Сохранение на телефоне" else "Local save"
        "profile_validation" -> if (ru) "Проверка анкеты" else "Profile validation"
        "upload" -> if (ru) "Отправка на сервер" else "Upload"
        "check_delivery" -> if (ru) "Проверка доставки" else "Delivery check"
        "restore" -> if (ru) "Восстановление" else "Restore"
        "error" -> if (ru) "Ошибка" else "Error"
        else -> if (ru) "Неизвестное действие" else "Unknown action"
    }
}

fun syncActivityOutcomeLabel(value: String, language: AppLanguage): String {
    val ru = language == AppLanguage.RUSSIAN
    return when (value) {
        "started" -> if (ru) "Начато" else "Started"
        "succeeded" -> if (ru) "Успешно" else "Succeeded"
        "failed" -> if (ru) "Не удалось" else "Failed"
        "waiting_network" -> if (ru) "Ожидает сети" else "Waiting for network"
        "waiting_server" -> if (ru) "Ожидает подключения сервера" else "Waiting for server configuration"
        "queued" -> if (ru) "В очереди" else "Queued"
        else -> if (ru) "Неизвестный результат" else "Unknown outcome"
    }
}
