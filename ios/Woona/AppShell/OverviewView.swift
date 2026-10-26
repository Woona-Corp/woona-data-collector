import SwiftUI
import UniformTypeIdentifiers

struct DogProfileEditorPresentation: Identifiable {
    let id = UUID()
    let profile: DogProfile?
}

struct AppCard<Content: View>: View {
    let title: String
    let content: Content
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 16, weight: .semibold))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.woonaSurface, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct AccountControls: View {
    @EnvironmentObject private var appState: AppViewModel
    private var russian: Bool { appState.selectedLanguage == .russian }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(russian ? "Аккаунт" : "Account").font(.caption).foregroundStyle(.secondary)
            TextField(russian ? "Аккаунт" : "Account", text: $appState.accountInput)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("account.input")
                .disabled(!appState.canChangeAccount)
            Text(russian ? "Уникальный идентификатор без пароля. Пустое поле — данные без аккаунта." : "Unique identifier without a password. Leave empty to show unassigned data.")
                .font(.footnote).foregroundStyle(.secondary)
            Button(russian ? "Применить аккаунт" : "Apply account") { appState.applyAccount() }
                .buttonStyle(.borderedProminent).foregroundStyle(Color.woonaOnPrimary)
                .accessibilityIdentifier("account.apply")
                .disabled(!appState.canChangeAccount)
            if appState.isAccountOperationRunning { ProgressView() }
            Text(russian ? "Локальная история: \(appState.localProfileCount) животных, \(appState.localRecordingCount) сессий. Активный аккаунт: \(appState.selectedAccountID ?? "без аккаунта")." : "Local history: \(appState.localProfileCount) animals, \(appState.localRecordingCount) sessions. Active account: \(appState.selectedAccountID ?? "unassigned").")
                .font(.footnote).accessibilityIdentifier("account.localInventory")
            if appState.hiddenProfileCount > 0 {
                Text(russian ? "Фильтр аккаунта скрывает \(appState.hiddenProfileCount) животных. Данные не удалены: примените прежний аккаунт или свяжите животное без аккаунта." : "The account filter hides \(appState.hiddenProfileCount) animals. Data is not deleted: apply the previous account or link an unassigned animal.")
                    .font(.footnote).foregroundStyle(.orange)
            }

            if appState.selectedAccountID != nil && !appState.unassignedDogProfiles.isEmpty {
                Text(russian ? "Собаки без аккаунта. Связывание перенесёт все сессии собаки в этот аккаунт." : "Unassigned dogs. Linking moves all this dog’s sessions into this account.")
                    .font(.footnote)
                ForEach(appState.unassignedDogProfiles) { dog in
                    Button(russian ? "Связать \(dog.numberOrName)" : "Link \(dog.numberOrName)") { appState.linkUnassignedDog(dog) }
                        .buttonStyle(.bordered)
                        .disabled(!appState.canChangeAccount)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.account")
    }
}

func recordingDisplayTime(_ value: String, timeZone: TimeZone = .current) -> String {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var date = iso.date(from: value)
    if date == nil { iso.formatOptions = [.withInternetDateTime]; date = iso.date(from: value) }
    guard let date else { return value }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "dd.MM.yyyy HH:mm"
    return formatter.string(from: date)
}


private func errorText(_ language: AppLanguage, _ ru: String, _ en: String) -> String {
    language == .russian ? ru : en
}

private let serverReasons: [String: (String, String)] = [
    "upload_offset_invalid": ("Сервер подтвердил недопустимую позицию файла. Завершение загрузки не подтверждено; исходник сохранён. Проверьте сервер и повторите отправку.", "The server acknowledged an invalid file position. Upload completion is not verified; the source is preserved. Check the server and retry."),
    "upload_offset_missing": ("Сервер не сообщил допустимую позицию принятого файла. Продолжение остановлено; исходник сохранён. Проверьте сервер и повторите отправку.", "The server did not report a valid accepted file position. The transfer stopped and the source is preserved. Check the server and retry."),
    "upload_conflict_stalled": ("Позиция загрузки не стабилизировалась после повторной сверки. Исходник сохранён; повтор продолжит отправку с подтверждённой позиции.", "The upload position did not stabilize after repeated checks. The source is preserved; a retry resumes from the confirmed position."),
    "download_incomplete": ("Скачивание оборвалось до ожидаемого размера. Сохранённая часть остаётся; повторное скачивание продолжит её.", "The download ended before its expected size. The saved prefix remains and a retry resumes it."),
    "download_hash_mismatch": ("Скачанная копия не прошла проверку SHA-256 и отброшена. Исходные данные сохранены; повторите скачивание.", "The downloaded copy failed SHA-256 verification and was discarded. Original data is preserved; retry the download."),
    "download_range_invalid": ("Сервер вернул другую или некорректную часть файла. Сохранённая часть не перезаписана; проверьте сервер и повторите скачивание.", "The server returned a different or malformed file range. The saved prefix was not overwritten; check the server and retry."),
    "download_length_invalid": ("Сервер сообщил противоречивый размер файла. Скачивание остановлено без замены локальных данных; проверьте сервер.", "The server reported conflicting file sizes. Download stopped without replacing local data; check the server."),
    "download_size_invalid": ("Размер скачиваемого файла недопустим или превышен. Готовый локальный файл не заменён; проверьте сервер.", "The download size is invalid or exceeded. The existing local file was not replaced; check the server."),
    "download_etag_mismatch": ("Версия файла на сервере не совпала с ожидаемой. Локальные данные не заменены; обновите сведения о сессии и повторите скачивание.", "The server file version does not match the expected version. Local data was not replaced; refresh the session metadata and retry."),
    "download_encoding_invalid": ("Сервер вернул файл в неподходящем кодировании. Продолжение скачивания остановлено; проверьте сервер и повторите.", "The server returned an unsupported file encoding. Download resumption stopped; check the server and retry."),
    "download_status_invalid": ("Ответ сервера не содержит ожидаемый файл. Локальные данные сохранены; проверьте сервер и повторите скачивание.", "The server response does not contain the expected file. Local data is preserved; check the server and retry."),
    "local_artifact_conflict": ("По этому пути уже есть другой локальный файл. Он не перезаписан. Сохраните полный архив и проверьте файл перед повтором.", "A different local file already exists at this path. It was not overwritten. Save a complete archive and check the file before retrying."),
    "local_artifact_changed": ("Исходный локальный файл отсутствует или изменился. Отправка остановлена. Сохраните полный архив и проверьте исходник.", "The local source file is missing or changed. Upload stopped. Save a complete archive and check the source."),
    "local_artifact_truncated": ("Исходный файл оборвался раньше сохранённого размера. Отправка остановлена; сохраните полный архив и проверьте исходник.", "The source file ended before its saved size. Upload stopped; save a complete archive and check the source."),
    "local_artifact_path_invalid": ("Путь исходного файла выходит за хранилище приложения. Отправка остановлена; локальные данные сохранены.", "The source file path escapes app storage. Upload stopped; local data is preserved."),
    "local_download_changed": ("Промежуточный файл скачивания изменился во время операции. Данные не перезаписаны; завершите другие операции и повторите.", "The incomplete local file changed during download. Data was not overwritten; finish other operations and retry."),
    "pagination_stalled": ("Сервер повторяет одну страницу истории. Восстановление остановлено; сохранённые записи не удалены. Проверьте сервер и повторите.", "The server repeated a history page. Restore stopped and saved recordings were not deleted. Check the server and retry."),
    "pagination_cursor_invalid": ("Сервер вернул некорректную ссылку на следующую страницу. Восстановление остановлено; локальные данные сохранены.", "The server returned an invalid next-page cursor. Restore stopped and local data is preserved."),
    "orphaned_upload_recovered": ("Предыдущая отправка прервалась, и активной задачи нет. Очередь восстановлена; файлы и подтверждённые позиции сохранены.", "A previous upload was interrupted and has no active task. The queue was recovered; files and confirmed positions are preserved."),
    "transfer_paused": ("Отправка приостановлена. Файлы и принятые сервером байты сохранены; повтор продолжит загрузку.", "The upload is paused. Files and accepted server bytes are preserved; a retry resumes the transfer."),
    "profile_content_already_exists": ("Эти ответы анкеты уже сохранены на сервере. Восстановите профили и выберите текущую карточку; не создавайте её повторно", "These questionnaire answers are already saved on the server. Restore profiles and select the current profile; do not create it again"),
    "account_header_mismatch": ("Аккаунт запроса не совпадает с аккаунтом животного", "The request account does not match the animal account"),
    "dog_account_conflict": ("Аккаунт запроса не совпадает с аккаунтом животного", "The request account does not match the animal account"),
    "account_required": ("Не выбран аккаунт", "No account is selected"),
    "animal_id_already_exists": ("Этот ID животного уже занят другой карточкой. Восстановите анкеты и выберите существующее животное", "This animal ID belongs to another profile. Restore profiles and select the existing animal"),
    "invalid_account_identifier": ("Недопустимый идентификатор аккаунта", "The account identifier is invalid"),
    "invalid_bearer_token": ("Токен устройства отсутствует или отклонён сервером. Переподключите сервер в настройках", "The device token is missing or rejected. Reconnect the server in Settings"),
    "missing_bearer_token": ("Токен устройства отсутствует или отклонён сервером. Переподключите сервер в настройках", "The device token is missing or rejected. Reconnect the server in Settings"),
    "artifact_hash_mismatch": ("Контрольная сумма файла не совпала: целостность загрузки не подтверждена", "The file checksum does not match: upload integrity is not verified"),
    "artifact_not_available": ("Не все обязательные файлы полностью загружены на сервер", "Required files are not all fully uploaded to the server"),
    "artifacts_incomplete": ("Не все обязательные файлы полностью загружены на сервер", "Required files are not all fully uploaded to the server"),
    "missing_required_artifacts": ("Не все обязательные файлы полностью загружены на сервер", "Required files are not all fully uploaded to the server"),
    "upload_incomplete": ("Не все обязательные файлы полностью загружены на сервер", "Required files are not all fully uploaded to the server"),
    "artifact_not_found": ("Запрошенная сессия, карточка или файл не найдены на сервере", "The requested session, profile or file was not found on the server"),
    "recording_not_found": ("Запрошенная сессия, карточка или файл не найдены на сервере", "The requested session, profile or file was not found on the server"),
    "dog_not_found": ("Запрошенная сессия, карточка или файл не найдены на сервере", "The requested session, profile or file was not found on the server"),
    "resource_not_found": ("Запрошенная сессия, карточка или файл не найдены на сервере", "The requested session, profile or file was not found on the server"),
    "artifact_not_owned": ("Этот файл или сессия принадлежат другому устройству", "This file or session belongs to another device"),
    "recording_not_owned": ("Этот файл или сессия принадлежат другому устройству", "This file or session belongs to another device"),
    "wrong_capture_device": ("Этот файл или сессия принадлежат другому устройству", "This file or session belongs to another device"),
    "artifact_size_exceeded": ("Превышен допустимый размер файла или запроса", "The file or request exceeds the allowed size"),
    "artifact_too_large": ("Превышен допустимый размер файла или запроса", "The file or request exceeds the allowed size"),
    "chunk_too_large": ("Превышен допустимый размер файла или запроса", "The file or request exceeds the allowed size"),
    "json_body_too_large": ("Превышен допустимый размер файла или запроса", "The file or request exceeds the allowed size"),
    "artifact_type_mismatch": ("Тип или описание контрольного файла не соответствует требованиям", "The reference file type or metadata does not meet the requirements"),
    "reference_type_required": ("Тип или описание контрольного файла не соответствует требованиям", "The reference file type or metadata does not meet the requirements"),
    "reference_metadata_required": ("Тип или описание контрольного файла не соответствует требованиям", "The reference file type or metadata does not meet the requirements"),
    "unexpected_reference_metadata": ("Тип или описание контрольного файла не соответствует требованиям", "The reference file type or metadata does not meet the requirements"),
    "chunk_size_invalid": ("Размер или позиция части файла не совпадает с ожидаемой сервером", "The file chunk size or offset does not match what the server expects"),
    "content_length_mismatch": ("Размер или позиция части файла не совпадает с ожидаемой сервером", "The file chunk size or offset does not match what the server expects"),
    "content_length_required": ("Размер или позиция части файла не совпадает с ожидаемой сервером", "The file chunk size or offset does not match what the server expects"),
    "offset_mismatch": ("Размер или позиция части файла не совпадает с ожидаемой сервером", "The file chunk size or offset does not match what the server expects"),
    "invalid_range": ("Размер или позиция части файла не совпадает с ожидаемой сервером", "The file chunk size or offset does not match what the server expects"),
    "range_not_satisfiable": ("Размер или позиция части файла не совпадает с ожидаемой сервером", "The file chunk size or offset does not match what the server expects"),
    "part_file_missing": ("На сервере отсутствует ранее сохранённый файл или его часть", "A previously stored file or file part is missing on the server"),
    "stored_file_missing": ("На сервере отсутствует ранее сохранённый файл или его часть", "A previously stored file or file part is missing on the server"),
    "database_unavailable": ("Серверная база данных сейчас недоступна или не готова", "The server database is unavailable or not ready"),
    "schema_not_ready": ("Серверная база данных сейчас недоступна или не готова", "The server database is unavailable or not ready"),
    "storage_unavailable": ("Хранилище файлов на сервере недоступно", "The server file storage is unavailable"),
    "entity_retired": ("Эта сессия, карточка или файл удалены из активных данных на сервере", "This session, profile or file has been retired on the server"),
    "questionnaire_revision_conflict": ("Анкета изменилась на сервере. Восстановите актуальную версию перед редактированием", "The questionnaire changed on the server. Restore its current version before editing"),
    "revision_conflict": ("Анкета изменилась на сервере. Восстановите актуальную версию перед редактированием", "The questionnaire changed on the server. Restore its current version before editing"),
    "immutable_artifact_conflict": ("Локальные данные не совпадают с уже сохранённой серверной версией", "Local data conflicts with the version already saved on the server"),
    "immutable_capture_field": ("Локальные данные не совпадают с уже сохранённой серверной версией", "Local data conflicts with the version already saved on the server"),
    "immutable_profile_conflict": ("Локальные данные не совпадают с уже сохранённой серверной версией", "Local data conflicts with the version already saved on the server"),
    "immutable_recording_conflict": ("Локальные данные не совпадают с уже сохранённой серверной версией", "Local data conflicts with the version already saved on the server"),
    "receipt_conflict": ("Локальные данные не совпадают с уже сохранённой серверной версией", "Local data conflicts with the version already saved on the server"),
    "duplicate_artifact_id": ("В сессии повторяется идентификатор или имя файла", "The session contains a duplicate file ID or name"),
    "duplicate_artifact_name": ("В сессии повторяется идентификатор или имя файла", "The session contains a duplicate file ID or name"),
    "ended_before_started": ("Время окончания указано раньше времени начала", "The end time precedes the start time"),
    "reference_ended_before_started": ("Время окончания указано раньше времени начала", "The end time precedes the start time"),
    "invalid_resource_id": ("Идентификатор сессии, животного или файла не совпадает с данными запроса", "The session, animal or file ID does not match the request data"),
    "path_payload_id_mismatch": ("Идентификатор сессии, животного или файла не совпадает с данными запроса", "The session, animal or file ID does not match the request data"),
    "session_dog_mismatch": ("Идентификатор сессии, животного или файла не совпадает с данными запроса", "The session, animal or file ID does not match the request data"),
    "profile_schema_version_mismatch": ("Формат анкеты или запроса не соответствует серверному контракту", "The questionnaire or request format does not match the server contract"),
    "session_schema_version_mismatch": ("Формат анкеты или запроса не соответствует серверному контракту", "The questionnaire or request format does not match the server contract"),
    "request_invalid": ("Формат анкеты или запроса не соответствует серверному контракту", "The questionnaire or request format does not match the server contract"),
    "legacy_migration_disabled": ("Перенос старого формата данных отключён на сервере", "Migration of the legacy data format is disabled on the server"),
    "artifact_already_complete": ("Этот файл уже полностью загружен; повторное изменение не разрешено", "This file is already fully uploaded and cannot be changed"),
    "local_copy_not_synced": ("Локальные файлы ещё не подтверждены сервером. Удаление отменено", "Local files are not yet confirmed by the server. Removal was cancelled"),
    "server_copy_unverified": ("Серверная копия неполна или не совпадает с локальными файлами. Удаление отменено", "The server copy is incomplete or does not match local files. Removal was cancelled"),
    "local_copy_changed": ("Локальный файл изменился после загрузки. Удаление отменено", "A local file changed after upload. Removal was cancelled"),
    "local_copy_unsafe_path": ("Путь файла выходит за каталог сессии. Удаление отменено", "A file path is outside the session directory. Removal was cancelled"),
    "local_copy_remove_failed": ("Не удалось удалить один из локальных файлов. Серверная копия сохранена", "A local file could not be removed. The server copy is preserved"),
]

private func httpFailureNextAction(_ status: Int, language: AppLanguage) -> String {
    switch status {
    case 401: return ""
    case 403: return errorText(language, "Проверьте права доступа с администратором. Повтор без изменения прав не устранит отказ.", "Check access permissions with an administrator. Retrying without a permission change will not resolve the refusal.")
    case 404: return errorText(language, "Обновите историю и проверьте выбранный аккаунт. Сохраните локальные оригиналы.", "Refresh history and check the selected account. Preserve local originals.")
    case 408, 504: return errorText(language, "Проверьте доступность сервера и повторите операцию. Её результат пока не подтверждён.", "Check server availability and retry the operation. Its outcome is not yet confirmed.")
    case 409: return errorText(language, "Обновите данные с сервера и сравните их с черновиком перед повтором. Сохраните черновик и файлы.", "Refresh server data and compare it with the draft before retrying. Preserve the draft and files.")
    case 413: return errorText(language, "Сохраните данные и передайте подробности разработчику для проверки лимита сервера. Не удаляйте файлы.", "Preserve data and send details to support to check the server limit. Keep the original files.")
    case 422: return errorText(language, "Проверьте указанные поля. Если ошибка повторяется, передайте код и подробности разработчику.", "Check the indicated fields. If the error repeats, send its code and details to support.")
    case 429: return errorText(language, "Подождите и повторите операцию позже.", "Wait and retry the operation later.")
    case 500...599: return errorText(language, "Проверьте сервер и повторите позже. При повторении ошибки передайте подробности разработчику.", "Check the server and retry later. If the error repeats, send details to support.")
    default: return errorText(language, "Проверьте подробности и настройки сервера. Сохраните исходные данные перед исправлением причины.", "Check details and server settings. Preserve original data before resolving the cause.")
    }
}

func recordingUploadErrorText(_ message: String?, language: AppLanguage) -> String {
    let raw = (message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !raw.isEmpty else { return errorText(language, "Причина не сохранена; проверьте диагностику сессии", "The cause was not saved; check session diagnostics") }
    if let code = serverReasons.keys.sorted().first(where: {
        raw.range(of: "(?<![a-z_])" + NSRegularExpression.escapedPattern(for: $0) + "(?![a-z_])", options: .regularExpression) != nil
    }), let pair = serverReasons[code] { return errorText(language, pair.0, pair.1) }
    if let range = raw.range(of: #"(?i)(?:HTTP\s+|Server returned\s+)([0-9]{3})"#, options: .regularExpression),
       let status = Int(raw[range].suffix(3)) {
        let reason: String
        switch status {
        case 401: reason = errorText(language, "Сервер отклонил токен устройства. Переподключите сервер в настройках", "The server rejected the device token. Reconnect the server in Settings")
        case 403: reason = errorText(language, "Недостаточно прав для этой операции", "Permission was denied for this operation")
        case 404: reason = errorText(language, "Запрошенные данные не найдены на сервере", "The requested data was not found on the server")
        case 408, 504: reason = errorText(language, "Сервер не ответил вовремя", "The server did not respond in time")
        case 409: reason = errorText(language, "Конфликт локальных и серверных данных", "Local data conflicts with server data")
        case 413: reason = errorText(language, "Превышен допустимый размер запроса", "The request exceeds the allowed size")
        case 422: reason = errorText(language, "Сервер отклонил формат или значения данных", "The server rejected the data format or values")
        case 429: reason = errorText(language, "Слишком много запросов; сервер временно ограничил загрузку", "Too many requests; the server temporarily limited uploads")
        case 500...599: reason = errorText(language, "Ошибка на стороне сервера", "The server encountered an error")
        default: reason = errorText(language, "Сервер отклонил запрос", "The server rejected the request")
        }
        return ["\(reason) (HTTP \(status))", httpFailureNextAction(status, language: language)].filter { !$0.isEmpty }.joined(separator: ". ")
    }
    let normalized = raw.lowercased()
    if normalized.contains("token") && (normalized.contains("missing") || normalized.contains("required")) {
        return errorText(language, "Не указан токен устройства. Переподключите сервер в настройках", "The device token is missing. Reconnect the server in Settings")
    }
    if normalized.contains("url") && normalized.contains("invalid") {
        return errorText(language, "Неверный адрес сервера. Проверьте URL в настройках", "The server URL is invalid. Check the URL in Settings")
    }
    if ["timed out", "timeout"].contains(where: normalized.contains) {
        return errorText(language, "Истекло время ожидания соединения с сервером", "The server connection timed out")
    }
    if ["ssl", "tls", "certificate"].contains(where: normalized.contains) {
        return errorText(language, "Не удалось проверить защищённое соединение с сервером", "The secure connection to the server could not be verified")
    }
    if ["unknownhost", "unable to resolve host", "failed to connect", "not connected", "offline", "could not connect", "network", "connection refused"].contains(where: normalized.contains) {
        return errorText(language, "Сервер недоступен или нет подключения к сети", "The server is unreachable or the network is unavailable")
    }
    if ["missing", "changed", "sha-256", "checksum", "unreadable"].contains(where: normalized.contains) {
        return errorText(language, "Локальный файл отсутствует, изменён или не прошёл проверку целостности", "A local file is missing, changed or failed integrity verification")
    }
    return errorText(language, "Результат операции не подтверждён. Причина не распознана: проверьте статус операции, сохраните полный архив и передайте подробности разработчику. Технические сведения: ", "The operation outcome is not confirmed. The cause is unrecognized: check the operation status, save a complete archive and send details to support. Technical details: ") + raw
}

func recordingCaptureText(status: String, code: String?, message: String?, language: AppLanguage) -> String {
    let code = code?.trimmingCharacters(in: .whitespacesAndNewlines)
    let message = message?.trimmingCharacters(in: .whitespacesAndNewlines)
    let reason: String?
    switch code?.isEmpty == false ? code : nil {
    case "gatt_error", "ble_disconnected":
        var suffix = ""
        if let range = message?.range(of: #"(?i)gatt[^0-9\n]{0,80}([0-9]+)"#, options: .regularExpression), let message {
            let digits = message[range].reversed().prefix(while: { $0.isNumber }).reversed()
            suffix = " (GATT " + String(digits) + ")"
        }
        reason = errorText(language, "сбой связи с ошейником", "collar connection failed") + suffix
    case "notification_timeout": reason = errorText(language, "ошейник перестал передавать данные; восстановить поток не удалось", "the collar stopped sending data and recovery failed")
    case "camera_failed": reason = errorText(language, "сбой камеры; видео могло записаться не полностью", "camera failure; the video may be incomplete")
    case "queue_overflow": reason = errorText(language, "переполнена очередь обработки данных датчика", "the sensor data processing queue overflowed")
    case "storage_error", "storage_failed": reason = errorText(language, "не удалось сохранить файлы записи", "recording files could not be saved")
    case "no_sensor_data": reason = errorText(language, "не получено ни одного корректного пакета датчика", "no valid sensor packets were received")
    case nil: reason = message?.isEmpty == false ? message : nil
    default: reason = [code, message].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
    }
    let value: String
    if let reason {
        let prefix = status == "completed" ? errorText(language, "завершена с проблемой", "completed with an issue") : errorText(language, "прервана", "interrupted")
        value = prefix + " — " + reason
    } else {
        switch status {
        case "completed": value = errorText(language, "завершена", "completed")
        case "failed": value = errorText(language, "завершилась с ошибкой; причина не сохранена. Проверьте диагностику сессии", "failed; the cause was not saved. Check session diagnostics")
        case "interrupted": value = errorText(language, "прервана до завершения; причина не сохранена. Проверьте диагностику сессии", "interrupted before completion; the cause was not saved. Check session diagnostics")
        case "recording": value = errorText(language, "идёт запись", "recording")
        case "preparing": value = errorText(language, "подготовка", "preparing")
        default: value = errorText(language, "неизвестный статус", "unknown status") + " (" + status + ")"
        }
    }
    return errorText(language, "Запись: ", "Capture: ") + value
}

func recordingUploadText(state: String, message: String?, language: AppLanguage) -> String {
    let reason: String
    switch state {
    case "pending": reason = errorText(language, "ожидает отправки на сервер", "waiting to upload to the server")
    case "uploading": reason = errorText(language, "отправляется на сервер", "uploading to the server")
    case "synced", "complete": reason = errorText(language, "загрузка была подтверждена; актуальную копию проверьте ниже", "upload was confirmed; check the current server copy below")
    case "remote": reason = errorText(language, "сессия получена с сервера", "session restored from the server")
    case "retryable_error": reason = errorText(language, "не завершена, запланирован повтор. ", "incomplete; a retry is scheduled. ") + recordingUploadErrorText(message, language: language)
    case "permanent_error": reason = errorText(language, "остановлена, требуется исправление. ", "stopped; action is required. ") + recordingUploadErrorText(message, language: language)
    default: reason = errorText(language, "неизвестный статус", "unknown status") + " (" + state + ")"
    }
    return errorText(language, "Загрузка: ", "Upload: ") + reason
}

struct ServerRecordingTransferView: View {
    @EnvironmentObject private var appState: AppViewModel
    let recordingID: UUID
    private var ru: Bool { appState.selectedLanguage == .russian }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(ru ? "Проверить доставку и файлы на сервере" : "Check server transfer and files") { appState.checkRecordingTransfer(recordingID) }
                .disabled(appState.serverToken.isEmpty || appState.checkingTransferIDs.contains(recordingID))
                .accessibilityIdentifier("recording.serverStatus." + recordingID.uuidString)
            if appState.serverToken.isEmpty { Text(ru ? "Для проверки подключите сервер в Настройках." : "Configure the server in Settings to check.").font(.caption) }
            if appState.checkingTransferIDs.contains(recordingID) { ProgressView() }
            if let error = appState.transferStatusErrors[recordingID] { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let status = appState.serverTransferStatuses[recordingID] {
                if let date = appState.transferCheckedAt[recordingID] {
                    Text((ru ? "Проверено: " : "Checked: ") + recordingDisplayTime(date) + " · " + appState.serverBaseURL).font(.caption)
                }
                if let transfer = status.transfer {
                    Text((ru ? "Доставка: " : "Transfer: ") + transferStateText(transfer.status, ru: ru)).font(.caption)
                    Text(ru ? "Передано \(transfer.uploadedBytes) из \(transfer.totalBytes) байт; проверено \(transfer.verifiedFiles) из \(transfer.totalFiles) файлов." : "Transferred \(transfer.uploadedBytes) of \(transfer.totalBytes) bytes; verified \(transfer.verifiedFiles) of \(transfer.totalFiles) files.").font(.caption)
                    ProgressView(value: Double(transfer.uploadedBytes), total: max(1, Double(transfer.totalBytes)))
                    Text(transfer.receiptVerified ? (ru ? "Серверная копия подтверждена по receipt и наличию файлов." : "Server copy confirmed by receipt and file availability.") : (ru ? "Полная серверная копия пока не подтверждена. Сохраняйте локальные данные." : "The full server copy is not confirmed. Preserve local data."))
                        .font(.caption)
                    if let date = transfer.lastProgressAtUtc { Text((ru ? "Последнее продвижение: " : "Last progress: ") + recordingDisplayTime(date)).font(.caption) }
                    Text((ru ? "Следующее действие: " : "Next action: ") + transferNextAction(transfer.nextAction, ru: ru)).font(.caption)
                } else { Text((ru ? "Сервер вернул прежний формат статуса: " : "Server returned the earlier status format: ") + status.ingestStatus).font(.caption) }
                if let quality = status.quality {
                    Text(quality.status == "warnings" ? (ru ? "Качество потока: есть предупреждения" : "Stream quality: warnings present") : (ru ? "Качество потока: " : "Stream quality: ") + (quality.status == "not_audited" ? (ru ? "не проверено" : "not checked") : (quality.status == "audited" ? (ru ? "диагностика проверена" : "diagnostics checked") : quality.status)))
                        .font(.caption).foregroundStyle(quality.status == "warnings" ? Color.orange : Color.secondary)
                    ForEach(Array(quality.warnings.enumerated()), id: \.offset) { _, warning in
                        Text(qualityWarningText(warning.code, count: warning.count, ru: ru)).font(.caption)
                    }
                    if !quality.continuousSensorCoverageVerified {
                        Text(ru ? "Непрерывное покрытие датчиком не подтверждено. Успешная загрузка файлов не проверяет полноту измерений." : "Continuous sensor coverage is not verified. A successful file transfer does not verify measurement completeness.").font(.caption)
                    }
                }
                if let labeling = status.labeling {
                    Text(labeling.eligible ? (ru ? "Подходит для разметки. Наличие и выполнение задачи Label Studio этой проверкой не подтверждаются." : "Eligible for labeling. This check does not confirm a Label Studio task or its completion.") : (ru ? "Пока не подходит для разметки: " : "Not yet eligible for labeling: ") + labeling.exclusionReasons.joined(separator: "; ")).font(.caption)
                }
                DisclosureGroup(ru ? "Файлы и подробности доставки" : "Files and transfer details") {
                    ForEach(status.artifacts ?? []) { artifact in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(artifact.fileName): \(artifact.uploadedBytes)/\(artifact.sizeBytes) · \(artifact.storageStatus)")
                            let rawError = [artifact.errorCode, artifact.errorMessage].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ": ")
                            if !rawError.isEmpty {
                                let explanation = recordingUploadErrorText(rawError, language: appState.selectedLanguage)
                                Text((ru ? "Причина: " : "Cause: ") + explanation).foregroundStyle(.red).textSelection(.enabled)
                                if !explanation.contains(rawError) { Text((ru ? "Технические сведения: " : "Technical details: ") + rawError).textSelection(.enabled) }
                            }
                            Text(transferNextAction(artifact.nextAction, ru: ru))
                        }.font(.caption)
                    }
                }
            }
        }
    }
}

func qualityWarningText(_ code: String, count: Int?, ru: Bool) -> String {
    let label: String
    switch code {
    case "packet_rejections_observed": label = ru ? "Зафиксированы отклонённые пакеты" : "Rejected packets were recorded"
    case "reported_packet_loss_requires_validation": label = ru ? "Счётчик сообщал о потерях; число требует проверки и не является доказанной потерей" : "Reported packet loss requires validation; the counter is not proof of actual loss"
    case "excluded_sensor_intervals": label = ru ? "При восстановлении исключены участки потока" : "Stream intervals were excluded during recovery"
    default: label = code
    }
    return label + (count.map { ": \($0)" } ?? "")
}

func transferStateText(_ value: String, ru: Bool) -> String {
    switch value {
    case "metadata_pending": return ru ? "ожидаются метаданные и список файлов" : "waiting for metadata and file manifest"
    case "uploading": return ru ? "передача файлов не завершена" : "file transfer is incomplete"
    case "awaiting_verification": return ru ? "байты получены; проверка файлов или завершение ещё ожидается" : "bytes received; verification or finalization is pending"
    case "verified": return ru ? "копия подтверждена на момент проверки" : "copy confirmed at the time of this check"
    case "integrity_problem": return ru ? "обнаружена проблема целостности; сохраните локальные оригиналы" : "integrity problem; preserve local originals"
    case "rejected": return ru ? "файл отклонён; требуется исправление причины" : "file rejected; the cause needs correction"
    default: return value
    }
}

func transferNextAction(_ value: String, ru: Bool) -> String {
    switch value {
    case "none": return ru ? "не требуется" : "none required"
    case "resume_upload": return ru ? "возобновите выгрузку с устройства-источника" : "resume uploads on the source device"
    case "upload_manifest": return ru ? "отправьте метаданные и список файлов с устройства-источника" : "upload metadata and the file manifest from the source device"
    case "verify_file", "verify_files", "finalize_recording": return ru ? "повторите выгрузку для проверки файлов и завершения сессии" : "retry upload to verify files and finalize the session"
    case "restart_file_upload": return ru ? "повторите передачу файла; сохраните оригинал" : "retry the file transfer; preserve the original"
    case "contact_support_preserve_local_data": return ru ? "сохраните локальные данные и передайте диагностику разработчику" : "preserve local data and send diagnostics to support"
    case "review_rejected_file": return ru ? "проверьте причину отклонения файла; не удаляйте оригинал" : "review why the file was rejected; preserve the original"
    case "retry_later": return ru ? "повторите позже" : "retry later"
    default: return value
    }
}

func recordingSourceText(_ source: String, language: AppLanguage) -> String {
    let value: String
    switch source {
    case "live": value = errorText(language, "запись с датчика", "sensor recording")
    case "replay": value = errorText(language, "воспроизведение файла", "local file replay")
    default: value = errorText(language, "неизвестен", "unknown") + " (" + source + ")"
    }
    return errorText(language, "Источник: ", "Source: ") + value
}

enum OverviewSection { case animals, session, video, recordings }

struct OverviewView: View {
    var section: OverviewSection = .animals
    @EnvironmentObject private var appState: AppViewModel
    @State private var isReplayImporterPresented = false
    @State private var isExportOptionsPresented = false
    @State private var pendingExportKind: ExportKind?
    @State private var dogEditorPresentation: DogProfileEditorPresentation?
    @State private var editingSession: WoonaRecording?
    @State private var isSessionEditorPresented = false
    @State private var isBLESelectionPresented = false
    @State private var pendingReplaySelection = false
    @State private var pendingDevice: BleDevice?
    @State private var pendingReplayURL: URL?
    @State private var heartRecording: WoonaRecording?
    @State private var pendingLocalRemoval: WoonaRecording?
    @State private var referenceRecording: WoonaRecording?
    @State private var isReferenceImporterPresented = false
    @State private var referenceURL: URL?
    @State private var isReferenceEditorPresented = false

    private var russian: Bool { appState.selectedLanguage == .russian }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                if section == .animals { AccountControls() }
                if appState.errorMessage != nil {
                    AppCard(title: appState.selectedLanguage == .russian ? "Ошибка" : "Error") {
                    if let errorMessage = appState.errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                        if appState.hasDogIdentityConflict {
                            Button(appState.selectedLanguage == .russian ? "Проверить и восстановить анкеты" : "Check and restore profiles") { appState.refreshFromServer() }
                                .disabled(!appState.canChangeAccount)
                            Button(appState.selectedLanguage == .russian ? "Проверить аккаунт" : "Check account") { appState.selectedTab = .overview }
                        }
                    }
                    }
                }
                if (section == .session || section == .video) && (appState.activeRecording != nil || appState.isCaptureReady) {
                    AppCard(title: russian ? "Синхронная сессия" : "Synchronized session") {
                        Text(appState.statusText).foregroundStyle(.secondary)
                        if section == .video, appState.activeRecording?.videoRequested == false {
                            Text(russian ? "Видео выключено в анкете этой сессии. Датчик записывается отдельно." : "Video is disabled in this session’s questionnaire. The sensor records separately.").font(.footnote)
                        }
                        if section == .video, appState.isCameraDegraded {
                            Text(russian ? "Камера недоступна. Данные датчика сохраняются; подробности сбоя указаны в ошибке сессии." : "Camera unavailable. Sensor data is preserved; session error details explain the failure.").font(.footnote).foregroundStyle(.red)
                        }

                    if section == .video, appState.isCaptureReady, appState.activeRecording?.videoRequested == true, !appState.isCameraDegraded {
                        CameraPreview(recorder: appState.cameraRecorder)
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    if appState.isCaptureReady {
                        Button(appState.isRecording ? (appState.selectedLanguage == .russian ? "Завершить сессию" : "Stop session") : (appState.selectedLanguage == .russian ? "Начать сессию" : "Start session")) {
                            if appState.isRecording { appState.stopActiveCapture() }
                            else { appState.startActiveCapture() }
                        }
                        .buttonStyle(.borderedProminent).foregroundStyle(Color.woonaOnPrimary)
                    }
                    }
                }
                if section == .animals {
                if !appState.canSelectAnimal {
                    Text(russian ? "Завершите текущую запись или операцию с аккаунтом перед сменой животного." : "Finish the active recording or account operation before changing the animal.").font(.footnote)
                }
                AppCard(title: appState.selectedLanguage == .russian ? "Активная собака" : "Active dog") {
                    if appState.dogProfiles.isEmpty {
                        Text(appState.selectedLanguage == .russian ? "Создайте обязательную анкету перед записью" : "Create the required questionnaire before recording")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.dogProfiles) { profile in
                            Button { appState.selectDogProfile(profile) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: appState.selectedDogProfile?.id == profile.id ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(.tint)
                                    Text(profile.numberOrName).foregroundStyle(.primary)
                                    Spacer()
                                }
                                .frame(minHeight: 48)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(profile.numberOrName)
                            .disabled(!appState.canSelectAnimal)
                            .accessibilityIdentifier("dog.select." + profile.id.uuidString)
                            .accessibilityAddTraits(appState.selectedDogProfile?.id == profile.id ? [.isSelected] : [])
                        }
                    }

                    HStack(spacing: 16) {
                        Button(appState.selectedLanguage == .russian ? "Новая собака" : "New dog") {
                            dogEditorPresentation = DogProfileEditorPresentation(profile: nil)
                        }
                        .buttonStyle(.borderedProminent).foregroundStyle(Color.woonaOnPrimary)
                        .disabled(!appState.canSelectAnimal)
                        .accessibilityIdentifier("dog.new")
                        Button(appState.selectedLanguage == .russian ? "Изменить" : "Edit") {
                            guard let profile = appState.selectedDogProfile else { return }
                            dogEditorPresentation = DogProfileEditorPresentation(profile: profile)
                        }
                        .accessibilityIdentifier("dog.edit")
                        .disabled(appState.selectedDogProfile == nil || !appState.canSelectAnimal)
                    }
                    // Keep New and Edit as separate visible actions on both platforms.
                    .buttonStyle(.bordered)
                }

                }

                if section == .recordings, let profile = appState.selectedDogProfile {
                    AppCard(title: appState.selectedLanguage == .russian
                            ? (appState.showingAllRecordings ? "Все записи" : "Последние 10 записей")
                            : (appState.showingAllRecordings ? "All recordings" : "Last 10 recordings")) {
                        if appState.recentRecordings.isEmpty && appState.serverRecordings.isEmpty {
                            Text(appState.selectedLanguage == .russian ? "У этой собаки пока нет записей" : "No recordings for this dog")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(appState.recentRecordings) { recording in
                            let remote = appState.serverRecordings.first { $0.id == recording.id }
                            let captureCode = recording.captureErrorCode ?? remote?.captureErrorCode
                            let captureMessage = recording.captureErrorMessage ?? remote?.captureErrorMessage
                            VStack(alignment: .leading, spacing: 8) {
                                if ["completed", "failed", "interrupted"].contains(recording.status) {
                                    Button(appState.selectedLanguage == .russian ? "Изменить анкету" : "Edit questionnaire") { editingSession = recording }
                                        .disabled(!appState.canEditQuestionnaire(recording))
                                    if recording.questionnaire?.sessionKind == "heart", recording.questionnaire?.readyForSync == false {
                                        Button(appState.selectedLanguage == .russian ? "Заполнить анкету по сердцебиению" : "Complete heart questionnaire") { heartRecording = recording }.disabled(!appState.canEditQuestionnaire(recording))
                                    }
                                    Button(appState.selectedLanguage == .russian ? "Добавить ЭКГ / ЧСС / интервалы" : "Add ECG / heart rate / intervals") {
                                        referenceRecording = recording
                                        isReferenceImporterPresented = true
                                    }
                                    .disabled(recording.serverSyncState == "remote" || !appState.canEditQuestionnaire(recording))
                                }
                                VStack(alignment: .leading) {
                                    Text(recording.sessionLabel)
                                    Text(recordingDisplayTime(recording.startedAtUTC)).font(.caption)
                                    Text(profile.numberOrName).font(.caption)
                                    Text(recordingSourceText(recording.source, language: appState.selectedLanguage)).font(.caption)
                                    Text(recordingCaptureText(status: recording.status, code: captureCode, message: captureMessage, language: appState.selectedLanguage))
                                        .font(.caption)
                                        .foregroundStyle(["failed", "interrupted"].contains(recording.status) || captureCode != nil ? Color.red : Color.secondary)
                                    Text(recordingUploadText(state: recording.serverSyncState, message: appState.recordingSyncErrors[recording.id], language: appState.selectedLanguage))
                                        .font(.caption)
                                        .foregroundStyle(["retryable_error", "permanent_error"].contains(recording.serverSyncState) ? Color.red : Color.secondary)
                                }
                                let details = [captureCode, captureMessage, appState.recordingSyncErrors[recording.id]].compactMap { $0 }.joined(separator: "\n")
                                if !details.isEmpty {
                                    DisclosureGroup(russian ? "Подробности ошибки" : "Error details") {
                                        Text(details).font(.caption).textSelection(.enabled)
                                    }
                                    .accessibilityIdentifier("recording.error." + recording.id.uuidString)
                                }
                                if let progress = appState.recordingUploadProgress[recording.id] {
                                    Text(russian ? "Передано: \(progress.bytes) из \(progress.total) байт. Подтверждено файлов: \(progress.verified)/\(progress.files)." : "Transferred: \(progress.bytes) of \(progress.total) bytes. Confirmed files: \(progress.verified)/\(progress.files).")
                                        .font(.caption)
                                    if progress.total > 0 { ProgressView(value: Double(progress.bytes), total: Double(progress.total)) }
                                }
                                ServerRecordingTransferView(recordingID: recording.id)
                                if let count = appState.recordingFileCounts[recording.id] {
                                    Text(appState.selectedLanguage == .russian ? "На устройстве: \(count.local) из \(count.total) файлов" : "On device: \(count.local) of \(count.total) files")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Button(appState.selectedLanguage == .russian ? "Поделиться ZIP сессии" : "Share session ZIP") {
                                        appState.shareRecording(recording.id)
                                    }
                                    .disabled(appState.exportPhase != nil || !appState.exportableRecordingIDs.contains(recording.id))
                                    if appState.downloadableRecordingIDs.contains(recording.id) {
                                        Button(appState.selectedLanguage == .russian ? "Скачать" : "Download") {
                                            appState.downloadRecording(recording.id)
                                        }
                                        .disabled(appState.downloadingRecordingID != nil)
                                    }
                                }
                                if let counts = appState.recordingFileCounts[recording.id], counts.local > 0 {
                                    Button(russian ? "Удалить с устройства" : "Remove from device", role: .destructive) { pendingLocalRemoval = recording }
                                        .disabled(!appState.canRemoveLocalRecording(recording))
                                        .accessibilityIdentifier("recording.removeLocal." + recording.id.uuidString)
                                    if recording.serverSyncState != "synced" {
                                        Text(russian ? "Удаление локальных файлов доступно после подтверждения полной загрузки." : "Local files can be removed after the server confirms the full upload.")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }

                            }
                        }
                        if !appState.showingAllRecordings && appState.recentRecordings.count == 10 {
                            Button(appState.selectedLanguage == .russian ? "Показать все записи" : "Show all recordings") {
                                appState.showAllRecordings()
                            }
                        }
                        ForEach(appState.serverRecordings.filter { remote in !appState.recentRecordings.contains(where: { $0.id == remote.id }) }) { recording in
                            VStack(alignment: .leading) {
                                Text(recording.sessionLabel)
                                Text(recordingSourceText(recording.source, language: appState.selectedLanguage)).font(.caption)
                                Text(recordingCaptureText(status: recording.captureStatus, code: recording.captureErrorCode, message: recording.captureErrorMessage, language: appState.selectedLanguage)).font(.caption)
                                Text(recordingUploadText(state: recording.ingestStatus == "uploading" ? "uploading" : recording.ingestStatus, message: nil, language: appState.selectedLanguage))
                                    .font(.caption).foregroundStyle(.secondary)
                                if let details = recording.captureErrorMessage { Text(details).font(.caption).textSelection(.enabled) }
                            }
                        }
                    }
                    .id(profile.id)
                }

                if section == .session && (appState.isConnectionActive || appState.activeRecording != nil || appState.packetsReceived > 0) {
                AppCard(title: appState.text(.session)) {
                    LabeledContent(appState.text(.status), value: appState.statusText)
                    if appState.isReplayRunning {
                        Text(appState.text(.replay))
                            .foregroundStyle(.purple)
                    }
                    MetricGrid(
                        packetsLabel: appState.text(.packets),
                        lostLabel: appState.text(.lost),
                        rejectedLabel: appState.text(.rejected),
                        packetsReceived: appState.packetsReceived,
                        packetsLost: appState.packetsLost,
                        packetsRejected: appState.packetsRejected
                    )
                    CompactSessionDetails()

                }

                }

                if section == .session {
                    AppCard(title: russian ? "Подготовка сессии" : "Session preparation") {
                        Text((russian ? "Животное: " : "Animal: ") + (appState.selectedDogProfile?.numberOrName ?? (russian ? "не выбрано" : "not selected")))
                        Text(russian ? "Хранение: телефон. Файлы остаются здесь до подтверждения серверной загрузки." : "Storage: phone. Files stay here until the server verifies their upload.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if appState.isConnectionActive || appState.isReplayRunning {
                            Button(russian ? "ОТКЛЮЧИТЬ" : "DISCONNECT") { appState.disconnect() }.buttonStyle(.bordered)
                        } else {
                            Button(russian ? "Новое соединение" : "New connection") { pendingDevice = nil; pendingReplaySelection = false; pendingReplayURL = nil; isBLESelectionPresented = true }
                                .buttonStyle(.borderedProminent).foregroundStyle(Color.woonaOnPrimary).accessibilityIdentifier("devices.newConnection")
                                .disabled(appState.selectedDogProfile == nil || !appState.canStartNewSession)
                            if appState.selectedDogProfile == nil {
                                Text(russian ? "Сначала выберите или создайте анкету во вкладке «Животные»." : "First select or create an animal in Animals.").font(.footnote)
                            }
                        }
                    }
                }
                if section == .video && appState.activeRecording == nil {
                    AppCard(title: russian ? "Видео" : "Video") {
                        Text(russian ? "Видео не запущено. Подготовьте сессию и включите видео в её анкете. Старт и остановка управляют датчиком и камерой вместе." : "No active video. Prepare a session and enable video in its questionnaire. Start and stop control the sensor and camera together.")
                    }
                }
                if section == .recordings && appState.selectedDogProfile == nil {
                    Text(russian ? "Выберите животное во вкладке «Животные». Для истории другого аккаунта примените его идентификатор; смена аккаунта не удаляет локальные записи." : "Select an animal in Animals. To see another account’s history, apply its identifier; changing accounts does not delete local recordings.")
                }
                if section == .session {
                AppCard(title: russian ? "Последние события" : "Latest events") {
                    if appState.diagnosticMessages.isEmpty {
                        Text(russian ? "Здесь будут показаны диагностические сообщения и события захвата." : "Session diagnostics and capture events will appear here.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(appState.diagnosticMessages.enumerated()), id: \.offset) { _, message in
                            Text(message)
                                .font(.footnote)
                        }
                    }
                }
                }
                }
                .padding(12)
            }
            .background(Color.woonaBackground)
            .safeAreaInset(edge: .top, spacing: 0) {
                if section == .session { SessionSectionPicker() }
            }
            .navigationTitle(screenTitle)
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: appState.recentRecordings) { _, records in
                presentIncompleteHeartQuestionnaire(records)
            }
            .alert(russian ? "Удалить файлы сессии с устройства?" : "Remove session files from this device?", isPresented: Binding(
                get: { pendingLocalRemoval != nil }, set: { if !$0 { pendingLocalRemoval = nil } }
            ), presenting: pendingLocalRemoval) { recording in
                Button(russian ? "Удалить с устройства" : "Remove from device", role: .destructive) {
                    appState.removeLocalRecordingFiles(recording.id)
                    pendingLocalRemoval = nil
                }
                Button(russian ? "Отмена" : "Cancel", role: .cancel) { pendingLocalRemoval = nil }
            } message: { recording in
                Text(russian ? "Сессия \(recording.sessionLabel): приложение сначала проверит серверную копию. Будут удалены только локальные файлы. История останется, файлы можно будет скачать снова." : "Session \(recording.sessionLabel): the app will first verify the server copy. Only local files will be removed. Session history stays and files can be downloaded again.")
            }
            .sheet(isPresented: $isBLESelectionPresented, onDismiss: {
                if pendingDevice != nil { isSessionEditorPresented = true }
                else if pendingReplaySelection { pendingReplaySelection = false; isReplayImporterPresented = true }
            }) {
                NavigationStack {
                    ScrollView { discoveryCard.padding(12) }
                        .navigationTitle(russian ? "Новое соединение" : "New connection")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .cancellationAction) {
                            Button(russian ? "Закрыть" : "Close") { isBLESelectionPresented = false }
                        } }
                }
            }
            .sheet(item: $editingSession) { recording in
                if let questionnaire = recording.questionnaire {
                    if questionnaire.schemaVersion == 1 {
                        LegacySessionQuestionnaireEditor(language: appState.selectedLanguage, source: recording.source, initial: questionnaire) { answers, revision in
                            try await appState.saveSessionQuestionnaire(answers, displayedRecording: recording, expectedRevision: revision)
                        }
                    } else {
                        SessionQuestionnaireEditor(language: appState.selectedLanguage, source: recording.source, initial: questionnaire) { answers, revision in
                            try await appState.saveSessionQuestionnaire(answers, displayedRecording: recording, expectedRevision: revision)
                        }
                    }
                }
            }
            .sheet(item: $heartRecording) { recording in
                HeartQuestionnaireEditor(initial: appState.heartQuestionnaireDraft(recordingID: recording.id), language: appState.selectedLanguage) { heart, revision in try await appState.saveHeartQuestionnaire(heart, displayedRecording: recording, expectedRevision: revision) }
            }
            .fileImporter(isPresented: $isReferenceImporterPresented, allowedContentTypes: [.data, .item], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls): referenceURL = urls.first; isReferenceEditorPresented = referenceURL != nil
                case .failure(let error): appState.reportError("Не удалось выбрать контрольную запись", error: error)
                }
            }
            .sheet(isPresented: $isReferenceEditorPresented) {
                if let url = referenceURL, let recording = referenceRecording {
                    ReferenceAttachmentEditor(url: url) { type, metadata in
                        try await appState.attachReference(recordingID: recording.id, type: type, url: url, metadata: metadata)
                    }
                }
            }
            .toolbar {
                if section == .session || section == .recordings {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(appState.text(.export)) {
                            isExportOptionsPresented = true
                        }
                        .disabled(!appState.canOpenSessionExport)
                    }
                }
            }
            .fileImporter(
                isPresented: $isReplayImporterPresented,
                allowedContentTypes: [.data, .item],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        pendingReplayURL = url
                        pendingDevice = nil
                        isSessionEditorPresented = true
                    }
                case .failure(let error):
                    appState.reportError("Replay file selection failed", error: error)
                }
            }
            .sheet(isPresented: $isExportOptionsPresented, onDismiss: preparePendingExport) {
                ExportOptionsSheet(isPresented: $isExportOptionsPresented) { kind in
                    pendingExportKind = kind
                }
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $dogEditorPresentation) { presentation in
                DogQuestionnaireEditor(
                    initial: presentation.profile?.questionnaire,
                    language: appState.selectedLanguage
                ) { questionnaire in
                    try appState.saveDogProfile(questionnaire, replacing: presentation.profile)
                }
                .id(presentation.id)
            }
            .sheet(isPresented: $isSessionEditorPresented, onDismiss: { pendingDevice = nil; pendingReplayURL = nil }) {
                SessionQuestionnaireEditor(
                    language: appState.selectedLanguage,
                    source: pendingReplayURL == nil ? "live" : "replay"
                ) { questionnaire, _ in
                    if let device = pendingDevice {
                        try appState.connect(to: device, questionnaire: questionnaire)
                    } else if let url = pendingReplayURL {
                        try appState.startReplay(from: url, questionnaire: questionnaire)
                    } else { throw WoonaStoreError.invalidData("Устройство или файл больше не выбран / No device or replay file selected") }
                    pendingDevice = nil
                    pendingReplayURL = nil
                }
            }
        }
    }

    private var screenTitle: String {
        switch section {
        case .animals: return russian ? "Животные" : "Animals"
        case .session: return russian ? "Сессия" : "Session"
        case .video: return russian ? "Видео" : "Video"
        case .recordings: return russian ? "Записи" : "Recordings"
        }
    }

    private var discoveryCard: some View {
                AppCard(title: russian ? "BLE-устройства" : "BLE devices") {
                    Text(russian ? "Запустите сканирование, выберите найденное устройство или воспроизведите сохраненный дамп." : "Start a scan, pick a discovered device, or replay a captured dump.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(appState.isScanning ? (russian ? "ИДЕТ СКАНИРОВАНИЕ..." : "SCANNING...") : (russian ? "НАЧАТЬ ПОИСК" : "START SCAN")) { appState.startScanning() }
                        .buttonStyle(.borderedProminent).foregroundStyle(Color.woonaOnPrimary)
                        .frame(maxWidth: .infinity)
                        .disabled(appState.isScanning || appState.selectedDogProfile == nil)
                        .accessibilityIdentifier("devices.scan")
                    Button(russian ? "Воспроизвести локальный файл (отладка)" : "Replay local file (debug)") { pendingReplaySelection = true; isBLESelectionPresented = false }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                        .disabled(appState.selectedDogProfile == nil || !appState.canStartNewSession)
                        .accessibilityIdentifier("devices.replay")
                    if appState.foundDevices.isEmpty {
                        Text(appState.isScanning ? (russian ? "Идет поиск ближайших BLE-устройств..." : "Scanning for nearby BLE devices...") : (russian ? "Устройства еще не найдены." : "No discovered devices yet."))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.foundDevices) { device in
                            Button {
                                pendingDevice = device
                                pendingReplayURL = nil
                                isBLESelectionPresented = false
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(device.name)
                                    Text(device.stableIdentifier)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .disabled(appState.isConnectionActive)
                        }
                    }
                }
    }

    private func presentIncompleteHeartQuestionnaire(_ records: [WoonaRecording]) {
        guard heartRecording == nil, !isSessionEditorPresented else { return }
        heartRecording = records.first { recording in
            guard ["completed", "failed", "interrupted"].contains(recording.status),
                  let questionnaire = recording.questionnaire else { return false }
            return questionnaire.sessionKind == "heart" && !questionnaire.readyForSync
        }
    }

    private func preparePendingExport() {
        guard let kind = pendingExportKind else { return }
        pendingExportKind = nil
        appState.prepareExport(kind)
    }
}

private struct CompactSessionDetails: View {
    @EnvironmentObject private var appState: AppViewModel

    var body: some View {
        VStack(spacing: 4) {
            Text("\(appState.text(.fragments)): \(appState.fragmentsReceived) | \(appState.text(.rawBytes)): \(appState.rawBytesReceived)")
            Text("\(appState.text(.lastIssue)): \(appState.lastPacketIssue ?? appState.text(.none))")
                .foregroundStyle(appState.lastPacketIssue == nil ? Color.secondary : Color.red)
            Text("\(appState.text(.timerRegressions)): \(appState.timerRegressionRejects)")
                .foregroundStyle(appState.timerRegressionRejects == 0 ? Color.secondary : Color.red)
            Text("\(appState.text(.rejects)): \(appState.rejectionBreakdown ?? appState.text(.none))")
                .foregroundStyle(appState.rejectionBreakdown == nil ? Color.secondary : Color.purple)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .lineLimit(2)
    }
}

struct ExportOptionsSheet: View {
    @EnvironmentObject private var appState: AppViewModel
    @Binding var isPresented: Bool
    let onSelect: (ExportKind) -> Void

    var body: some View {
        NavigationStack {
            List {
                if let exportPhase = appState.exportPhase {
                    Section {
                        LabeledContent(appState.text(.status), value: exportPhase.rawValue)
                    }
                }

                Section {
                    ForEach(ExportKind.allCases) { kind in
                        Button {
                            onSelect(kind)
                            isPresented = false
                        } label: {
                            Text(appState.title(for: kind))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(!appState.canExportSessionFile(kind))
                    }
                }
            }
            .navigationTitle(appState.text(.export))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(appState.selectedLanguage == .russian ? "Готово" : "Done") {
                        isPresented = false
                    }
                }
            }
        }
    }
}

private struct MetricGrid: View {
    let packetsLabel: String
    let lostLabel: String
    let rejectedLabel: String
    let packetsReceived: UInt64
    let packetsLost: UInt64
    let packetsRejected: UInt64

    var body: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 8) {
            GridRow {
                MetricCell(title: packetsLabel, value: packetsReceived, role: .primary)
                MetricCell(title: lostLabel, value: packetsLost, role: packetsLost > 0 ? .destructive : .secondary)
                MetricCell(title: rejectedLabel, value: packetsRejected, role: packetsRejected > 0 ? .destructive : .secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct MetricCell: View {
    enum Role {
        case primary
        case secondary
        case destructive
    }

    let title: String
    let value: UInt64
    let role: Role

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.title2.monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
    }

    private var color: Color {
        switch role {
        case .primary:
            .accentColor
        case .secondary:
            .secondary
        case .destructive:
            .red
        }
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
