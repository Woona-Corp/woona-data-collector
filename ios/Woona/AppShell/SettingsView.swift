import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppViewModel
    @State private var isServerEditorPresented = false
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

                AppCard(title: appState.text(.appearance)) {
                    Picker(appState.text(.theme), selection: $appState.selectedThemeMode) {
                        ForEach(AppThemeMode.allCases, id: \.self) { themeMode in
                            Text(themeMode.rawValue).tag(themeMode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                AppCard(title: appState.text(.language)) {
                    Picker(appState.text(.language), selection: $appState.selectedLanguage) {
                        ForEach(AppLanguage.allCases, id: \.self) { language in
                            Text(language.rawValue).tag(language)
                        }
                    }
                }

                AppCard(title: appState.selectedLanguage == .russian ? "Серверное хранилище" : "Server storage") {
                    HStack {
                        Text(isServerConfigured ? appState.serverBaseURL : (russian ? "Не настроено" : "Not configured"))
                            .font(.subheadline)
                        Spacer()
                        Button(isServerConfigured ? (russian ? "Переподключить" : "Reconnect") : (russian ? "Подключить" : "Connect")) {
                            isServerEditorPresented = true
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("server.configure")
                    }
                    Toggle(russian ? "Только по Wi‑Fi" : "Wi-Fi only", isOn: $appState.serverWifiOnly)
                        .disabled(!isServerConfigured)
                        .onChange(of: appState.serverWifiOnly) { _, _ in appState.saveServerSettings() }
                    Button(russian ? "Повторить выгрузку" : "Retry uploads") { appState.retryFailedSync() }
                        .buttonStyle(.bordered)
                        .disabled(!isServerConfigured)
                    Button(russian ? "Восстановить с сервера" : "Restore from server") { appState.refreshFromServer() }
                        .buttonStyle(.bordered)
                        .disabled(!isServerConfigured)

                }
                .disabled(!appState.canChangeAccount)
                }.padding(12)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(appState.text(.settings))
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $isServerEditorPresented) {
                ServerConnectionEditor(baseURL: appState.serverBaseURL, russian: russian) { baseURL, token in
                    appState.serverBaseURL = baseURL
                    appState.serverToken = token
                    appState.saveServerSettings()
                }
            }
        }
    }
}

private struct ServerConnectionEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var baseURL: String
    @State private var token = ""
    @State private var error: String?
    let russian: Bool
    let onSave: (String, String) -> Void

    init(baseURL: String, russian: Bool, onSave: @escaping (String, String) -> Void) {
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
                        onSave(baseURL, cleanToken)
                        dismiss()
                    }
                    .accessibilityIdentifier("server.save")
                }
            }
        }
    }
}
