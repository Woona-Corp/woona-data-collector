package com.example.myapplication.sync

import com.example.myapplication.localization.AppLanguage

enum class ConnectionCheck { NOT_CHECKED, CHECKING, VERIFIED, FAILED }

/** Configuration, last successful request and the local queue are separate facts. */
fun ServerSyncUiState.queueExplanation(language: AppLanguage): String {
    fun text(ru: String, en: String) = if (language == AppLanguage.RUSSIAN) ru else en
    return when {
        !isConfigured -> text("Сервер не подключён. Данные сохраняются на телефоне; настройте адрес и токен.", "Server is not configured. Data stays on this phone; configure the address and token.")
        restoring -> text("Восстанавливаем историю с сервера. Существующие локальные файлы сохраняются.", "Restoring server history. Existing local files are preserved.")
        networkAvailable == false -> text("Нет подключения к интернету. Очередь сохранена; отправка продолжится после подключения.", "No internet connection. The queue is saved and will resume when connected.")
        wifiOnly && unmeteredNetwork == false -> text("Отправка ждёт Wi-Fi или сети без тарификации. Подключите её либо отключите ограничение ниже.", "Uploads are waiting for Wi-Fi or an unmetered network. Connect or disable the restriction below.")
        failed > 0 -> text("Есть ошибки доставки. Откройте причину в записи; повторите отправку после устранения причины.", "Some transfers failed. Open the recording for its cause; retry after correcting it.")
        uploading > 0 || workersRunning > 0 -> text("Обрабатываем очередь: подготовка, передача файлов и проверка целостности. Полученные байты ещё не означают подтверждённую копию.", "Processing the queue: preparation, transfer and integrity verification. Received bytes alone do not confirm a verified copy.")
        pending > 0 -> text("Задачи ожидают запуска или повтора системой. Приложение не считает их загруженными; нажмите «Повторить выгрузку» для постановки в очередь.", "Tasks are waiting for the system to start or retry them. They are not marked uploaded; use Retry uploads to enqueue them.")
        else -> text("Локальная очередь пуста. Это не проверка доступности сервера и не статус разметки Label Studio.", "The local queue is empty. This does not verify server availability or Label Studio annotation status.")
    }
}

fun ConnectionCheck.label(language: AppLanguage): String {
    val ru = language == AppLanguage.RUSSIAN
    return when (this) {
        ConnectionCheck.NOT_CHECKED -> if (ru) "Соединение не проверено" else "Connection not checked"
        ConnectionCheck.CHECKING -> if (ru) "Проверяем сервер и доступ…" else "Checking server and access…"
        ConnectionCheck.VERIFIED -> if (ru) "Последняя проверка успешна" else "Last connection check succeeded"
        ConnectionCheck.FAILED -> if (ru) "Последняя проверка не прошла" else "Last connection check failed"
    }
}

fun recordingServerReport(status: org.json.JSONObject, language: AppLanguage): String {
    val ru = language == AppLanguage.RUSSIAN
    val transfer = status.optJSONObject("transfer") ?: return (if (ru) "Сервер вернул прежний формат статуса: " else "Server returned the earlier status format: ") + status.optString("ingestStatus")
    return buildString {
        appendLine((if (ru) "Доставка: " else "Transfer: ") + transfer.optString("status"))
        val total = transfer.optLong("totalBytes"); val uploaded = transfer.optLong("uploadedBytes")
        appendLine(if (ru) "Передано $uploaded из $total байт. Проверено ${transfer.optInt("verifiedFiles")} из ${transfer.optInt("totalFiles")} файлов." else "Transferred $uploaded of $total bytes. Verified ${transfer.optInt("verifiedFiles")} of ${transfer.optInt("totalFiles")} files.")
        appendLine(if (transfer.optBoolean("receiptVerified")) { if (ru) "Серверная копия подтверждена по receipt и наличию файлов." else "Server copy confirmed by receipt and file availability." } else { if (ru) "Полная копия не подтверждена. Сохраняйте локальные данные." else "The full copy is not confirmed. Preserve local data." })
        if (transfer.optBoolean("stalled")) appendLine(if (ru) "Давно нет продвижения: ${transfer.optLong("secondsSinceLastProgress")} секунд." else "No recent progress: ${transfer.optLong("secondsSinceLastProgress")} seconds.")
        if (!transfer.isNull("lastProgressAtUtc")) appendLine((if (ru) "Последнее продвижение: " else "Last progress: ") + transfer.optString("lastProgressAtUtc"))
        appendLine((if (ru) "Следующее действие: " else "Next action: ") + transfer.optString("nextAction"))
        status.optJSONObject("labeling")?.let { labeling ->
            appendLine(if (labeling.optBoolean("eligible")) { if (ru) "Подходит для разметки. Наличие и выполнение задачи Label Studio этой проверкой не подтверждаются." else "Eligible for labeling. This does not confirm a Label Studio task or its completion." } else { if (ru) "Пока не подходит для разметки:" else "Not yet eligible for labeling:" })
            labeling.optJSONArray("exclusionReasons")?.let { reasons -> for (i in 0 until reasons.length()) appendLine(reasons.optString(i)) }
        }
        status.optJSONArray("artifacts")?.let { files ->
            for (i in 0 until files.length()) {
                val file = files.getJSONObject(i)
                appendLine("${file.optString("fileName")}: ${file.optLong("uploadedBytes")}/${file.optLong("sizeBytes")} · ${file.optString("storageStatus")}")
                if (!file.isNull("errorCode")) appendLine(file.optString("errorCode"))
                if (!file.isNull("errorMessage")) appendLine(file.optString("errorMessage"))
            }
        }
    }.trim()
}
