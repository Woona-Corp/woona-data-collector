import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppViewModel
    @State private var isServerEditorPresented = false
    @State private var isServerDisconnectPresented = false
    private var russian: Bool { appState.selectedLanguage == .russian }
    private var isServerConfigured: Bool { !appState.serverBaseURL.isEmpty && !appState.serverToken.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                if let error = appState.errorMessage {
                    AppCard(title: appState.selectedLanguage == .russian ? "Ошибка" : "Error") {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                AppCard(title: appState.text(.bleTransport)) {
                    LabeledContent(appState.text(.profile)) {
                        Text(appState.currentTransportProfileTitle)
                            .foregroundStyle(.secondary)
                    }
                    Text(appState.text(.transportAdvisory))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                AppCard(title: appState.text(.theme)) {
                    Text(russian ? "Выберите системную, светлую или тёмную тему приложения." : "Choose whether the app follows the system appearance or always uses a light or dark theme.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Picker(appState.text(.theme), selection: $appState.selectedThemeMode) {
                        ForEach(AppThemeMode.allCases, id: \.self) { themeMode in
                            Text(themeTitle(themeMode)).tag(themeMode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                AppCard(title: appState.text(.language)) {
                    Text(russian ? "Выберите язык для всей оболочки приложения и экрана устройства." : "Choose the app language for the entire shell and device flow.")
                        .font(.footnote).foregroundStyle(.secondary)
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        Button { appState.selectedLanguage = language } label: {
                            HStack(spacing: 10) {
                                Image(systemName: appState.selectedLanguage == language ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(.tint)
                                Text(language == .russian ? "Русский" : "English").foregroundStyle(.primary)
                                Spacer()
                            }
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(language == .russian ? "language.ru" : "language.en")
                        .accessibilityAddTraits(appState.selectedLanguage == language ? [.isSelected] : [])
                    }
                }

                CompleteArchiveCard()

                AppCard(title: russian ? "Очистка по удалениям сервера" : "Server retirement cleanup") {
                    Text(retirementCheckLabel).font(.footnote)
                    if let date = appState.retirementCheckedAt { Text(recordingDisplayTime(date)).font(.caption) }
                    if let error = appState.retirementCheckError { Text(recordingUploadErrorText(error, language: appState.selectedLanguage) + "\n" + error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    Text(russian ? "Локальных удалений в очереди: \(appState.retirementCleanupStatus.pendingCount)" : "Pending local deletions: \(appState.retirementCleanupStatus.pendingCount)").font(.footnote)
                    if appState.retirementCleanupStatus.deferredCount > 0 {
                        Text(russian ? "Отложенных команд удаления: \(appState.retirementCleanupStatus.deferredCount). Повторим после безопасного завершения записи или обновления связанных профилей." : "Deferred retirements: \(appState.retirementCleanupStatus.deferredCount). They retry after capture stops safely or referenced profiles are refreshed.").font(.footnote)
                    }
                    if appState.retirementCleanupStatus.pendingCount > 0 {
                        Text(russian ? "Серверные метаданные уже выведены из обращения. Локальная очистка будет повторена; ошибка файла не отменяет удаление на сервере." : "Server metadata is already retired. Local cleanup will retry; a file error does not undo server retirement.").font(.footnote)
                        if let error = appState.retirementCleanupStatus.lastError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    }
                    if appState.retirementCleanupStatus.pendingCount > 0 || appState.retirementCleanupStatus.deferredCount > 0 || appState.retirementCheckError != nil {
                        Button(russian ? "Повторить проверку и очистку" : "Retry check and cleanup") { appState.recoverLocalData() }
                            .disabled(!appState.canExportCompleteArchive)
                    }
                }

                AppCard(title: appState.selectedLanguage == .russian ? "Серверное хранилище" : "Server storage") {
                    Text(russian ? "Очередь всех локальных аккаунтов. Каждая анкета и запись отправляется в свой аккаунт." : "Queue for all local accounts. Each profile and recording uploads to its own account.").font(.footnote)
                    Text(appState.uploadQueueExplanation).font(.footnote)
                    Text(russian ? "Анкеты: \(appState.profileUploadPending) ожидают · \(appState.profileUploadFailed) ошибок" : "Profiles: \(appState.profileUploadPending) waiting · \(appState.profileUploadFailed) failed").font(.footnote)
                    if let error = appState.profileUploadLastError {
                        DisclosureGroup(russian ? "Ошибка отправки анкеты" : "Profile upload error") {
                            Text(recordingUploadErrorText(error, language: appState.selectedLanguage) + "\n" + error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        }
                    }
                    Text(appState.backgroundSyncExplanation).font(.footnote)
                    if let error = appState.backgroundSyncError {
                        DisclosureGroup(russian ? "Подробности фонового запуска" : "Background scheduling details") {
                            Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        }
                    }
                    Text(russian ? "Аккаунт: \(appState.selectedAccountID ?? "без аккаунта")" : "Account: \(appState.selectedAccountID ?? "unassigned")").font(.footnote)
                    Text(russian ? "Сессии: \(appState.uploadPending) ожидают · \(appState.uploadRunning) выгружаются · \(appState.uploadSynced) подтверждены · \(appState.uploadFailed) ошибок" : "Sessions: \(appState.uploadPending) pending · \(appState.uploadRunning) uploading · \(appState.uploadSynced) confirmed · \(appState.uploadFailed) failed").font(.footnote)
                    if let error = appState.uploadLastError {
                        DisclosureGroup(russian ? "Подробности последней ошибки" : "Last error details") { Text(recordingUploadErrorText(error, language: appState.selectedLanguage) + "\n" + error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    }
                    Text(connectionLabel).font(.footnote)
                    if let date = appState.connectionCheckedAt { Text(recordingDisplayTime(date)).font(.caption) }
                    if let error = appState.connectionCheckError { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    Button(russian ? "Проверить соединение" : "Check connection") { appState.checkServerConnection() }
                        .buttonStyle(.bordered)
                        .disabled(!isServerConfigured || appState.connectionCheck == "checking")
                        .accessibilityIdentifier("server.check")
                    ServerStorageDetails(appState: appState, russian: russian)
                    HStack {
                        Text(isServerConfigured ? appState.serverBaseURL : (russian ? "Не настроено" : "Not configured"))
                            .font(.subheadline)
                        Spacer()
                        Button(isServerConfigured ? (russian ? "Переподключить" : "Reconnect") : (russian ? "Подключить" : "Connect")) {
                            isServerEditorPresented = true
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("server.configure")
                        .disabled(!appState.canChangeAccount)
                    }
                    Toggle(russian ? "Только по Wi‑Fi" : "Wi-Fi only", isOn: Binding(
                        get: { appState.serverWifiOnly },
                        set: { value in
                            _ = appState.updateNetworkPolicy(wifiOnly: value)
                        }
                    ))
                        .disabled(!isServerConfigured || !appState.canChangeNetworkPolicy)
                    Button(russian ? "Повторить выгрузку" : "Retry uploads") { appState.retryFailedSync() }
                        .buttonStyle(.bordered)
                        .disabled(!isServerConfigured || !appState.canChangeAccount)
                    Button(russian ? "Восстановить с сервера" : "Restore from server") { appState.refreshFromServer() }
                        .buttonStyle(.bordered)
                        .disabled(!isServerConfigured || !appState.canChangeAccount)
                    if appState.serverRestoreState != "not_started" {
                        Text(restoreLabel).font(.footnote)
                            .accessibilityIdentifier("server.restoreStatus")
                    }
                    if !appState.serverRestoreWarnings.isEmpty {
                        Text(russian ? "Восстановление частичное: \(appState.serverRestoreWarnings.count) объектов пропущено. Удаление не подтверждено; локальные данные сохранены." : "Restore is partial: \(appState.serverRestoreWarnings.count) entities were skipped. Deletion is unconfirmed; local data is preserved.")
                            .font(.footnote).foregroundStyle(.orange)
                        ForEach(Array(appState.serverRestoreWarnings.prefix(10).enumerated()), id: \.offset) { _, warning in
                            Text("\(warning.kind) · \(warning.id.uuidString) · HTTP \(warning.status)")
                                .font(.caption).textSelection(.enabled)
                        }
                    }
                    if isServerConfigured {
                        Button(russian ? "Отключить сервер" : "Disconnect server", role: .destructive) { isServerDisconnectPresented = true }
                            .buttonStyle(.bordered)
                            .disabled(!appState.canDisconnectServer)
                            .accessibilityIdentifier("server.disconnect")
                    }

                    if let reason = appState.serverMutationBlockedReason {
                        Text(reason).font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("server.mutationBlockReason")
                    }
                }
                }.padding(12)
            }
            .background(Color.woonaBackground)
            .navigationTitle(appState.text(.settings))
            .navigationBarTitleDisplayMode(.inline)
            .alert(russian ? "Отключить сервер на этом устройстве?" : "Disconnect the server on this device?", isPresented: $isServerDisconnectPresented) {
                Button(russian ? "Отмена" : "Cancel", role: .cancel) {}
                Button(russian ? "Отключить сервер" : "Disconnect server", role: .destructive) { _ = appState.disconnectServer() }
            } message: {
                Text(russian
                    ? "Токен будет удалён, текущие передачи остановятся. Локальные файлы, анкеты и очередь сохранятся. Для продолжения подключите сервер с новым токеном."
                    : "The token will be removed and current transfers will stop. Local files, questionnaires and the queue remain saved. Connect the server with a new token to resume.")
            }
            .sheet(isPresented: $isServerEditorPresented) {
                ServerConnectionEditor(baseURL: appState.serverBaseURL, russian: russian) { baseURL, token in
                    guard appState.canChangeAccount else { throw WoonaStoreError.invalidData(appState.serverMutationBlockedReason ?? "Server settings are busy") }
                    let normalizedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    _ = try WoonaServerClient(configuration: ServerConfiguration(baseURL: normalizedURL, wifiOnly: appState.serverWifiOnly, accountID: appState.selectedAccountID), token: token)
                    let oldURL = appState.serverBaseURL, oldToken = appState.serverToken
                    appState.serverBaseURL = normalizedURL
                    appState.serverToken = token
                    if !appState.saveServerSettings() {
                        appState.serverBaseURL = oldURL; appState.serverToken = oldToken
                        throw WoonaStoreError.invalidData(appState.errorMessage ?? "Server settings could not be saved")
                    }
                }
            }
        }
    }
    private var restoreLabel: String {
        switch appState.serverRestoreState {
        case "running": return russian ? "Восстанавливаем данные с сервера…" : "Restoring data from server…"
        case "completed": return russian ? "Последнее восстановление завершено" : "Last restore completed"
        case "partial": return russian ? "Последнее восстановление завершено частично" : "Last restore completed partially"
        default: return russian ? "Последнее восстановление прервано; уже полученные данные сохранены" : "Last restore was interrupted; previously restored data is preserved"
        }
    }

    private var connectionLabel: String {
        switch appState.connectionCheck {
        case "checking": return russian ? "Проверяем сервер и доступ…" : "Checking server and access…"
        case "verified": return russian ? "Последняя проверка успешна" : "Last connection check succeeded"
        case "failed": return russian ? "Последняя проверка не прошла" : "Last connection check failed"
        default: return russian ? "Соединение не проверено" : "Connection not checked"
        }
    }

    private var retirementCheckLabel: String {
        switch appState.retirementCheckState {
        case "checking": return russian ? "Проверяем команды удаления сервера…" : "Checking server retirements…"
        case "verified": return russian ? "Последняя проверка команд удаления успешна" : "Last retirement check succeeded"
        case "failed": return russian ? "Проверка команд удаления не завершена" : "Retirement check is incomplete"
        default: return russian ? "Команды удаления сервера ещё не проверены" : "Server retirements have not been checked"
        }
    }

    private func themeTitle(_ mode: AppThemeMode) -> String {
        guard russian else { return mode.rawValue }
        switch mode {
        case .system: return "Системная"
        case .light: return "Светлая"
        case .dark: return "Темная"
        }
    }

}

private struct ServerConnectionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var baseURL: String
    @State private var token = ""
    @State private var error: String?
    let russian: Bool
    let onSave: (String, String) throws -> Void

    init(baseURL: String, russian: Bool, onSave: @escaping (String, String) throws -> Void) {
        _baseURL = State(initialValue: baseURL)
        self.russian = russian
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Server URL", text: $baseURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .accessibilityIdentifier("server.url")
                SecureField(russian ? "Новый токен" : "New token", text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("server.token")
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(russian ? "Подключение сервера" : "Server connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(russian ? "Отмена" : "Cancel") { dismiss() }
                        .accessibilityIdentifier("server.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(russian ? "Сохранить" : "Save") {
                        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !cleanToken.isEmpty else { error = russian ? "Введите токен" : "Enter token"; return }
                        do { try onSave(baseURL, cleanToken); dismiss() }
                        catch { self.error = (russian ? "Настройки сервера не сохранены. Исправьте причину и повторите.\n" : "Server settings were not saved. Correct the cause and retry.\n") + error.localizedDescription }
                    }
                    .accessibilityIdentifier("server.save")
                }
            }
        }
    }
}


func storageAdmissionText(_ status: String, russian: Bool) -> String {
    switch status {
    case "ready": return russian ? "Место для новых загрузок доступно" : "Storage is available for new uploads"
    case "capacity_reserved": return russian ? "Место зарезервировано другими загрузками" : "Capacity is reserved by other uploads"
    case "account_quota_reached": return russian ? "Лимит хранения аккаунта исчерпан" : "Account storage limit reached"
    default: return status
    }
}

private struct ServerStorageDetails: View {
    @ObservedObject var appState: AppViewModel
    let russian: Bool
    private var configured: Bool { !appState.serverBaseURL.isEmpty && !appState.serverToken.isEmpty }
    private func t(_ ru: String, _ en: String) -> String { russian ? ru : en }
    private func bytes(_ value: Int64?, limit: Bool = false) -> String { storageByteText(value, unlimitedWhenZero: limit, russian: russian) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text(t("Место и лимиты сервера", "Server storage and limits")).font(.headline)
            Text(stateText).font(.footnote).accessibilityIdentifier("server.storageStatus")
            if appState.serverStorageCheck == "checking" { ProgressView() }
            if let checked = appState.serverStorageCheckedAt {
                Text(t("Проверено: ", "Checked: ") + recordingDisplayTime(checked)).font(.caption)
            }
            if let value = appState.serverStorageStatus {
                Text(storageAdmissionText(value.status, russian: russian)).font(.subheadline)
                Text(t("Аккаунт: ", "Account: ") + (value.checkedScope.accountId ?? t("без аккаунта", "unassigned")))
                Text(t("Лимит аккаунта: ", "Account limit: ") + bytes(value.limits.accountBytes, limit: true))
                Text(t("Заявлено и зарезервировано аккаунтом: ", "Declared and reserved by account: ") + bytes(value.account.declaredReservedBytes))
                Text(t("Принято данных аккаунта (объём): ", "Account data received (volume): ") + bytes(value.account.acknowledgedBytes))
                Text(t("Осталось по лимиту аккаунта: ", "Remaining account quota: ") + bytes(value.account.remainingQuotaBytes))
                Text(t("Лимит одной записи: ", "Per-recording limit: ") + bytes(value.limits.recordingBytes, limit: true))
                Text(russian ? "Записей: \(value.account.recordings) · файлов: \(value.account.artifacts)" : "Recordings: \(value.account.recordings) · artifacts: \(value.account.artifacts)")
                Text(t("Сервер целиком — всего: ", "Entire server — total: ") + bytes(value.serverStorage.totalBytes))
                Text(t("Сервер целиком — свободно на диске: ", "Entire server — free on disk: ") + bytes(value.serverStorage.freeBytes))
                Text(t("Сервер целиком — резерв свободного места: ", "Entire server — free-space reserve: ") + bytes(value.serverStorage.freeSpaceReserveBytes))
                Text(t("Сервер целиком — зарезервировано загрузками: ", "Entire server — reserved by uploads: ") + bytes(value.serverStorage.pendingReservedBytes))
                Text(t("Сервер целиком — доступно новым загрузкам: ", "Entire server — available for new uploads: ") + bytes(value.serverStorage.newReservationAvailableBytes))
                Text(russian ? "Сервер целиком — незавершённых файлов: \(value.serverStorage.pendingArtifacts)" : "Entire server — unfinished artifacts: \(value.serverStorage.pendingArtifacts)")
                if !value.admission.blockingReasons.isEmpty {
                    Text(t("Причины ограничений: ", "Admission restrictions: ") + value.admission.blockingReasons.map { recordingUploadErrorText($0, language: appState.selectedLanguage) }.joined(separator: "; "))
                }
                Text(t("Следующее действие: ", "Next action: ") + transferNextAction(value.nextAction, ru: russian))
                Text(t("Лимиты учитывают заявленные байты незавершённых загрузок. Эти объёмы не подтверждают целостность файлов.", "Quotas include declared bytes of unfinished uploads. These volumes do not verify file integrity.")).font(.caption)
                if value.admission.existingUploadsMayResume {
                    Text(t("Ранее принятые загрузки могут продолжаться.", "Previously accepted uploads may resume.")).font(.caption)
                }
            }
            if let error = appState.serverStorageError {
                DisclosureGroup(t("Подробности ошибки проверки места", "Storage check error details")) {
                    Text(recordingUploadErrorText(error, language: appState.selectedLanguage) + "\n" + error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            Button(appState.serverStorageCheck == "failed" || appState.serverStorageCheck == "unavailable" ? t("Повторить проверку места", "Retry storage check") : t("Проверить место на сервере", "Check server storage")) { appState.checkServerStorage() }
                .buttonStyle(.bordered).disabled(!configured || appState.serverStorageCheck == "checking").accessibilityIdentifier("server.storageCheck")
        }.font(.footnote)
    }
    private var stateText: String {
        guard configured else { return t("Подключите сервер, чтобы проверить место и лимиты.", "Connect the server to check storage and limits.") }
        switch appState.serverStorageCheck {
        case "checking": return t("Проверяем место и лимиты…", "Checking storage and limits…")
        case "checked": return t("Место и лимиты проверены на момент запроса.", "Storage and limits were checked at the time of this request.")
        case "unavailable": return t("Эта версия сервера не поддерживает проверку места и лимитов. Проверка соединения доступна отдельно.", "This server version does not support storage and limits checks. Connection checks remain available separately.")
        case "failed": return t("Не удалось проверить место и лимиты. Повторите проверку; локальные данные сохранены.", "Storage and limits could not be checked. Retry; local data is preserved.")
        default: return t("Место и лимиты ещё не проверены.", "Storage and limits have not been checked yet.")
        }
    }
}
