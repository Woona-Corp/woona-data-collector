package com.example.myapplication.localization

import com.example.myapplication.localization.AppLanguage

private fun errorText(language: AppLanguage, ru: String, en: String) = if (language == AppLanguage.RUSSIAN) ru else en

private val serverReasons = mapOf(
    "account_header_mismatch" to ("Аккаунт запроса не совпадает с аккаунтом животного" to "The request account does not match the animal account"),
    "dog_account_conflict" to ("Аккаунт запроса не совпадает с аккаунтом животного" to "The request account does not match the animal account"),
    "account_required" to ("Не выбран аккаунт" to "No account is selected"),
    "animal_id_already_exists" to ("Этот ID животного уже занят другой карточкой. Восстановите анкеты и выберите существующее животное" to "This animal ID belongs to another profile. Restore profiles and select the existing animal"),
    "invalid_account_identifier" to ("Недопустимый идентификатор аккаунта" to "The account identifier is invalid"),
    "invalid_bearer_token" to ("Токен устройства отсутствует или отклонён сервером. Переподключите сервер в настройках" to "The device token is missing or rejected. Reconnect the server in Settings"),
    "missing_bearer_token" to ("Токен устройства отсутствует или отклонён сервером. Переподключите сервер в настройках" to "The device token is missing or rejected. Reconnect the server in Settings"),
    "artifact_hash_mismatch" to ("Контрольная сумма файла не совпала: целостность загрузки не подтверждена" to "The file checksum does not match: upload integrity is not verified"),
    "artifact_not_available" to ("Не все обязательные файлы полностью загружены на сервер" to "Required files are not all fully uploaded to the server"),
    "artifacts_incomplete" to ("Не все обязательные файлы полностью загружены на сервер" to "Required files are not all fully uploaded to the server"),
    "missing_required_artifacts" to ("Не все обязательные файлы полностью загружены на сервер" to "Required files are not all fully uploaded to the server"),
    "upload_incomplete" to ("Не все обязательные файлы полностью загружены на сервер" to "Required files are not all fully uploaded to the server"),
    "artifact_not_found" to ("Запрошенная сессия, карточка или файл не найдены на сервере" to "The requested session, profile or file was not found on the server"),
    "recording_not_found" to ("Запрошенная сессия, карточка или файл не найдены на сервере" to "The requested session, profile or file was not found on the server"),
    "dog_not_found" to ("Запрошенная сессия, карточка или файл не найдены на сервере" to "The requested session, profile or file was not found on the server"),
    "resource_not_found" to ("Запрошенная сессия, карточка или файл не найдены на сервере" to "The requested session, profile or file was not found on the server"),
    "artifact_not_owned" to ("Этот файл или сессия принадлежат другому устройству" to "This file or session belongs to another device"),
    "recording_not_owned" to ("Этот файл или сессия принадлежат другому устройству" to "This file or session belongs to another device"),
    "wrong_capture_device" to ("Этот файл или сессия принадлежат другому устройству" to "This file or session belongs to another device"),
    "artifact_size_exceeded" to ("Превышен допустимый размер файла или запроса" to "The file or request exceeds the allowed size"),
    "artifact_too_large" to ("Превышен допустимый размер файла или запроса" to "The file or request exceeds the allowed size"),
    "chunk_too_large" to ("Превышен допустимый размер файла или запроса" to "The file or request exceeds the allowed size"),
    "json_body_too_large" to ("Превышен допустимый размер файла или запроса" to "The file or request exceeds the allowed size"),
    "artifact_type_mismatch" to ("Тип или описание контрольного файла не соответствует требованиям" to "The reference file type or metadata does not meet the requirements"),
    "reference_type_required" to ("Тип или описание контрольного файла не соответствует требованиям" to "The reference file type or metadata does not meet the requirements"),
    "reference_metadata_required" to ("Тип или описание контрольного файла не соответствует требованиям" to "The reference file type or metadata does not meet the requirements"),
    "unexpected_reference_metadata" to ("Тип или описание контрольного файла не соответствует требованиям" to "The reference file type or metadata does not meet the requirements"),
    "chunk_size_invalid" to ("Размер или позиция части файла не совпадает с ожидаемой сервером" to "The file chunk size or offset does not match what the server expects"),
    "content_length_mismatch" to ("Размер или позиция части файла не совпадает с ожидаемой сервером" to "The file chunk size or offset does not match what the server expects"),
    "content_length_required" to ("Размер или позиция части файла не совпадает с ожидаемой сервером" to "The file chunk size or offset does not match what the server expects"),
    "offset_mismatch" to ("Размер или позиция части файла не совпадает с ожидаемой сервером" to "The file chunk size or offset does not match what the server expects"),
    "invalid_range" to ("Размер или позиция части файла не совпадает с ожидаемой сервером" to "The file chunk size or offset does not match what the server expects"),
    "range_not_satisfiable" to ("Размер или позиция части файла не совпадает с ожидаемой сервером" to "The file chunk size or offset does not match what the server expects"),
    "part_file_missing" to ("На сервере отсутствует ранее сохранённый файл или его часть" to "A previously stored file or file part is missing on the server"),
    "stored_file_missing" to ("На сервере отсутствует ранее сохранённый файл или его часть" to "A previously stored file or file part is missing on the server"),
    "database_unavailable" to ("Серверная база данных сейчас недоступна или не готова" to "The server database is unavailable or not ready"),
    "schema_not_ready" to ("Серверная база данных сейчас недоступна или не готова" to "The server database is unavailable or not ready"),
    "storage_unavailable" to ("Хранилище файлов на сервере недоступно" to "The server file storage is unavailable"),
    "entity_retired" to ("Эта сессия, карточка или файл удалены из активных данных на сервере" to "This session, profile or file has been retired on the server"),
    "questionnaire_revision_conflict" to ("Анкета изменилась на сервере. Восстановите актуальную версию перед редактированием" to "The questionnaire changed on the server. Restore its current version before editing"),
    "revision_conflict" to ("Анкета изменилась на сервере. Восстановите актуальную версию перед редактированием" to "The questionnaire changed on the server. Restore its current version before editing"),
    "immutable_artifact_conflict" to ("Локальные данные не совпадают с уже сохранённой серверной версией" to "Local data conflicts with the version already saved on the server"),
    "immutable_capture_field" to ("Локальные данные не совпадают с уже сохранённой серверной версией" to "Local data conflicts with the version already saved on the server"),
    "immutable_profile_conflict" to ("Локальные данные не совпадают с уже сохранённой серверной версией" to "Local data conflicts with the version already saved on the server"),
    "immutable_recording_conflict" to ("Локальные данные не совпадают с уже сохранённой серверной версией" to "Local data conflicts with the version already saved on the server"),
    "receipt_conflict" to ("Локальные данные не совпадают с уже сохранённой серверной версией" to "Local data conflicts with the version already saved on the server"),
    "duplicate_artifact_id" to ("В сессии повторяется идентификатор или имя файла" to "The session contains a duplicate file ID or name"),
    "duplicate_artifact_name" to ("В сессии повторяется идентификатор или имя файла" to "The session contains a duplicate file ID or name"),
    "ended_before_started" to ("Время окончания указано раньше времени начала" to "The end time precedes the start time"),
    "reference_ended_before_started" to ("Время окончания указано раньше времени начала" to "The end time precedes the start time"),
    "invalid_resource_id" to ("Идентификатор сессии, животного или файла не совпадает с данными запроса" to "The session, animal or file ID does not match the request data"),
    "path_payload_id_mismatch" to ("Идентификатор сессии, животного или файла не совпадает с данными запроса" to "The session, animal or file ID does not match the request data"),
    "session_dog_mismatch" to ("Идентификатор сессии, животного или файла не совпадает с данными запроса" to "The session, animal or file ID does not match the request data"),
    "profile_schema_version_mismatch" to ("Формат анкеты или запроса не соответствует серверному контракту" to "The questionnaire or request format does not match the server contract"),
    "session_schema_version_mismatch" to ("Формат анкеты или запроса не соответствует серверному контракту" to "The questionnaire or request format does not match the server contract"),
    "request_invalid" to ("Формат анкеты или запроса не соответствует серверному контракту" to "The questionnaire or request format does not match the server contract"),
    "legacy_migration_disabled" to ("Перенос старого формата данных отключён на сервере" to "Migration of the legacy data format is disabled on the server"),
    "artifact_already_complete" to ("Этот файл уже полностью загружен; повторное изменение не разрешено" to "This file is already fully uploaded and cannot be changed"),
    "local_copy_not_synced" to ("Локальные файлы ещё не подтверждены сервером. Удаление отменено" to "Local files are not yet confirmed by the server. Removal was cancelled"),
    "server_copy_unverified" to ("Серверная копия неполна или не совпадает с локальными файлами. Удаление отменено" to "The server copy is incomplete or does not match local files. Removal was cancelled"),
    "local_copy_changed" to ("Локальный файл изменился после загрузки. Удаление отменено" to "A local file changed after upload. Removal was cancelled"),
    "local_copy_unsafe_path" to ("Путь файла выходит за каталог сессии. Удаление отменено" to "A file path is outside the session directory. Removal was cancelled"),
    "local_copy_remove_failed" to ("Не удалось удалить один из локальных файлов. Серверная копия сохранена" to "A local file could not be removed. The server copy is preserved"),
)

internal fun recordingUploadErrorText(message: String?, language: AppLanguage): String {
    val raw = message?.trim().orEmpty()
    if (raw.isEmpty()) return errorText(language, "Причина не сохранена; проверьте диагностику сессии", "The cause was not saved; check session diagnostics")
    val code = serverReasons.keys.firstOrNull { Regex("(?<![a-z_])" + Regex.escape(it) + "(?![a-z_])").containsMatchIn(raw) }
    if (code != null) return serverReasons.getValue(code).let { errorText(language, it.first, it.second) }
    val http = Regex("""(?i)(?:HTTP\s+|Server returned\s+)([0-9]{3})""").find(raw)?.groupValues?.get(1)
    if (http != null) {
        val reason = when (http.toInt()) {
            401 -> errorText(language, "Сервер отклонил токен устройства. Переподключите сервер в настройках", "The server rejected the device token. Reconnect the server in Settings")
            403 -> errorText(language, "Недостаточно прав для этой операции", "Permission was denied for this operation")
            404 -> errorText(language, "Запрошенные данные не найдены на сервере", "The requested data was not found on the server")
            408, 504 -> errorText(language, "Сервер не ответил вовремя", "The server did not respond in time")
            409 -> errorText(language, "Конфликт локальных и серверных данных", "Local data conflicts with server data")
            413 -> errorText(language, "Превышен допустимый размер запроса", "The request exceeds the allowed size")
            422 -> errorText(language, "Сервер отклонил формат или значения данных", "The server rejected the data format or values")
            429 -> errorText(language, "Слишком много запросов; сервер временно ограничил загрузку", "Too many requests; the server temporarily limited uploads")
            in 500..599 -> errorText(language, "Ошибка на стороне сервера", "The server encountered an error")
            else -> errorText(language, "Сервер отклонил запрос", "The server rejected the request")
        }
        return "$reason (HTTP $http)"
    }
    val normalized = raw.lowercase()
    return when {
        "token" in normalized && ("missing" in normalized || "required" in normalized) -> errorText(language, "Не указан токен устройства. Переподключите сервер в настройках", "The device token is missing. Reconnect the server in Settings")
        "url" in normalized && "invalid" in normalized -> errorText(language, "Неверный адрес сервера. Проверьте URL в настройках", "The server URL is invalid. Check the URL in Settings")
        listOf("timed out", "timeout").any { it in normalized } -> errorText(language, "Истекло время ожидания соединения с сервером", "The server connection timed out")
        listOf("ssl", "tls", "certificate").any { it in normalized } -> errorText(language, "Не удалось проверить защищённое соединение с сервером", "The secure connection to the server could not be verified")
        listOf("unknownhost", "unable to resolve host", "failed to connect", "not connected", "offline", "could not connect", "network", "connection refused").any { it in normalized } -> errorText(language, "Сервер недоступен или нет подключения к сети", "The server is unreachable or the network is unavailable")
        listOf("missing", "changed", "sha-256", "checksum", "unreadable").any { it in normalized } -> errorText(language, "Локальный файл отсутствует, изменён или не прошёл проверку целостности", "A local file is missing, changed or failed integrity verification")
        else -> raw
    }
}

internal fun recordingCaptureText(status: String, code: String?, message: String?, language: AppLanguage): String {
    val reason = when (code?.takeIf { it.isNotBlank() }) {
        "gatt_error", "ble_disconnected" -> {
            val number = Regex("""(?i)gatt[^0-9\n]{0,80}([0-9]+)""").find(message.orEmpty())?.groupValues?.get(1)
            errorText(language, "сбой связи с ошейником", "collar connection failed") + (number?.let { " (GATT $it)" } ?: "")
        }
        "notification_timeout" -> errorText(language, "ошейник перестал передавать данные; восстановить поток не удалось", "the collar stopped sending data and recovery failed")
        "camera_failed" -> errorText(language, "сбой камеры; видео могло записаться не полностью", "camera failure; the video may be incomplete")
        "queue_overflow" -> errorText(language, "переполнена очередь обработки данных датчика", "the sensor data processing queue overflowed")
        "storage_error", "storage_failed" -> errorText(language, "не удалось сохранить файлы записи", "recording files could not be saved")
        "no_sensor_data" -> errorText(language, "не получено ни одного корректного пакета датчика", "no valid sensor packets were received")
        null -> message?.takeIf { it.isNotBlank() }
        else -> listOfNotNull(code, message?.takeIf { it.isNotBlank() }).joinToString(": ")
    }
    val value = if (reason != null) {
        val prefix = if (status == "completed") errorText(language, "завершена с проблемой", "completed with an issue") else errorText(language, "прервана", "interrupted")
        "$prefix — $reason"
    } else when (status) {
        "completed" -> errorText(language, "завершена", "completed")
        "failed" -> errorText(language, "завершилась с ошибкой; причина не сохранена. Проверьте диагностику сессии", "failed; the cause was not saved. Check session diagnostics")
        "interrupted" -> errorText(language, "прервана до завершения; причина не сохранена. Проверьте диагностику сессии", "interrupted before completion; the cause was not saved. Check session diagnostics")
        "recording" -> errorText(language, "идёт запись", "recording")
        "preparing" -> errorText(language, "подготовка", "preparing")
        else -> errorText(language, "неизвестный статус", "unknown status") + " ($status)"
    }
    return errorText(language, "Запись: ", "Capture: ") + value
}

internal fun recordingUploadText(state: String, message: String?, language: AppLanguage): String {
    val reason = when (state) {
        "pending" -> errorText(language, "ожидает отправки на сервер", "waiting to upload to the server")
        "uploading" -> errorText(language, "отправляется на сервер", "uploading to the server")
        "synced", "complete" -> errorText(language, "загрузка была подтверждена; актуальную копию проверьте ниже", "upload was confirmed; check the current server copy below")
        "remote" -> errorText(language, "сессия получена с сервера", "session restored from the server")
        "retryable_error" -> errorText(language, "не завершена, запланирован повтор. ", "incomplete; a retry is scheduled. ") + recordingUploadErrorText(message, language)
        "permanent_error" -> errorText(language, "остановлена, требуется исправление. ", "stopped; action is required. ") + recordingUploadErrorText(message, language)
        else -> errorText(language, "неизвестный статус", "unknown status") + " ($state)"
    }
    return errorText(language, "Загрузка: ", "Upload: ") + reason
}

internal fun recordingSourceText(source: String, language: AppLanguage): String {
    val value = when (source) {
        "live" -> errorText(language, "запись с датчика", "sensor recording")
        "replay" -> errorText(language, "воспроизведение файла", "local file replay")
        else -> errorText(language, "неизвестен", "unknown") + " ($source)"
    }
    return errorText(language, "Источник: ", "Source: ") + value
}
