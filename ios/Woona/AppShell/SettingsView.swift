import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppViewModel

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
                    TextField("https://server.example", text: $appState.serverBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField(appState.selectedLanguage == .russian ? "Токен устройства" : "Device token", text: $appState.serverToken)
                        .textInputAutocapitalization(.never)
                    Toggle(appState.selectedLanguage == .russian ? "Только Wi-Fi" : "Wi-Fi only", isOn: $appState.serverWifiOnly)
                    HStack {
                        Button(appState.selectedLanguage == .russian ? "Сохранить" : "Save") {
                            appState.saveServerSettings()
                        }
                        Button(appState.selectedLanguage == .russian ? "Проверить и восстановить" : "Test and restore") {
                            appState.refreshFromServer()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button(appState.selectedLanguage == .russian ? "Повторить ошибки синхронизации" : "Retry failed sync") {
                        appState.retryFailedSync()
                    }
                    Text(appState.selectedLanguage == .russian
                         ? "Данные собак и сессий доступны в выбранном аккаунте."
                         : "Dogs and sessions are available within the selected account.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .disabled(!appState.canChangeAccount)
                }.padding(12)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(appState.text(.settings))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
