package com.example.myapplication.sync

import com.example.myapplication.localization.AppLanguage
import com.example.myapplication.localization.recordingUploadErrorText

/** Interpret the stored HTTP error without changing retry, ownership or local data. */
fun serverSyncErrorText(message: String, language: AppLanguage): String {
    val conflict = message.startsWith("Server returned HTTP 409:") &&
        Regex("\"code\"\\s*:\\s*\"animal_id_already_exists\"").containsMatchIn(message)
    if (!conflict) return message
    return animalIdentityConflictText(language)
}

/** ID must come from the actual local questionnaire, never from an arbitrary server message. */
fun animalIdentityConflictText(language: AppLanguage, localAnimalId: String? = null): String {
    val id = localAnimalId?.trim()?.takeIf { it.isNotEmpty() }
    return if (language == AppLanguage.RUSSIAN) {
        "Другая карточка уже использует ID${id?.let { " $it" }.orEmpty()}. Эта запись связана с новой карточкой, поэтому сервер её не принял. Восстановите карточки с сервера и выберите существующее животное. Проверьте аккаунт. Локальные данные сохранены; смена клички не устраняет конфликт."
    } else {
        "Another profile already uses this ID${id?.let { " ($it)" }.orEmpty()}. This recording is linked to a new profile, so the server did not accept it. Use restore from server and select the existing animal. Check the account. Local data is preserved; renaming does not resolve the conflict."
    }
}

/** Raw payloads belong only in collapsed, selectable details. */
fun syncFailureSummary(message: String?, language: AppLanguage): String =
    recordingUploadErrorText(message, language)

/** Known credential/URL redaction for storage AND expanded/copyable details, not general DLP. */
fun redactSyncDetails(value: String, bearerToken: String? = null): String {
    var result = value.replace("\\/", "/")
    if (!bearerToken.isNullOrEmpty()) result = result.replace(bearerToken, "[redacted]")
    // Drop every query/fragment, including unknown signing parameters and encoded delimiters.
    result = Regex("""(?i)https?(?:://|%3a%2f%2f)[^\s"'<>\\]+""").replace(result) { match ->
        var url = match.value
        url = Regex("""(?i)(https?(?:://|%3a%2f%2f))[^/\s]+(?:@|%40)""").replace(url, "$1[redacted]@")
        val delimiter = Regex("""(?i)[?#]|%3f|%23""").find(url)
        if (delimiter == null) url else url.take(delimiter.range.first) + "[redacted]"
    }
    // Keep JSON string delimiters valid: serverCode consumers still parse responseBody.
    val label = """(?i)(["']?\b(?:access[_-]?token|refresh[_-]?token|device[_-]?token|token|authorization|password|secret|api[_-]?key|key|sig|signature|x-amz-signature|x-amz-credential|x-goog-signature)["']?\s*[:=]\s*)"""
    result = Regex(label + """("(?:\\.|[^"\\])*"|'[^']*'|(?:Bearer|Basic|Digest)\s+(?:\[redacted\]|[^\s"',;\]}]+)|\[redacted\]|[^\s,;}\]&]+)""").replace(result) { match ->
        val raw = match.groupValues[2]
        val replacement = when (raw.firstOrNull()) {
            '"' -> "\"[redacted]\""
            '\'' -> "'[redacted]'"
            else -> "[redacted]"
        }
        match.groupValues[1] + replacement
    }
    return Regex("""(?i)\bBearer\s+(?:\[redacted\]|[^\s"',;\]}]+)""").replace(result, "Bearer [redacted]")
}
