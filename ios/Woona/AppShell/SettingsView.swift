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
