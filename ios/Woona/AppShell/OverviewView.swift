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
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
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
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("account.apply")
                .disabled(!appState.canChangeAccount)
            if appState.isAccountOperationRunning { ProgressView() }
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

struct OverviewView: View {
    @EnvironmentObject private var appState: AppViewModel
    @State private var isReplayImporterPresented = false
    @State private var isExportOptionsPresented = false
    @State private var pendingExportKind: ExportKind?
    @State private var dogEditorPresentation: DogProfileEditorPresentation?
    @State private var editingSession: WoonaRecording?
    @State private var isSessionEditorPresented = false
    @State private var pendingDevice: BleDevice?
    @State private var pendingReplayURL: URL?
    @State private var heartRecording: WoonaRecording?
    @State private var referenceRecording: WoonaRecording?
    @State private var isReferenceImporterPresented = false
    @State private var referenceURL: URL?
    @State private var isReferenceEditorPresented = false

    private var russian: Bool { appState.selectedLanguage == .russian }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                AccountControls()
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
                if appState.activeRecording != nil || appState.isCaptureReady {
                    AppCard(title: russian ? "Синхронная сессия" : "Synchronized session") {
                        Text(appState.statusText).foregroundStyle(.secondary)
                    if appState.isCaptureReady, appState.activeRecording?.videoRequested == true, !appState.isCameraDegraded {
                        CameraPreview(recorder: appState.cameraRecorder)
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    if appState.isCaptureReady {
                        Button(appState.isRecording ? (appState.selectedLanguage == .russian ? "Завершить сессию" : "Stop session") : (appState.selectedLanguage == .russian ? "Начать сессию" : "Start session")) {
                            if appState.isRecording { appState.stopActiveCapture() }
                            else { appState.startActiveCapture() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    }
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
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(profile.numberOrName)
                            .accessibilityIdentifier("dog.select." + profile.id.uuidString)
                            .accessibilityAddTraits(appState.selectedDogProfile?.id == profile.id ? [.isSelected] : [])
                        }
                    }

                    HStack(spacing: 16) {
                        Button(appState.selectedLanguage == .russian ? "Новая собака" : "New dog") {
                            dogEditorPresentation = DogProfileEditorPresentation(profile: nil)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("dog.new")
                        Button(appState.selectedLanguage == .russian ? "Изменить" : "Edit") {
                            guard let profile = appState.selectedDogProfile else { return }
                            dogEditorPresentation = DogProfileEditorPresentation(profile: profile)
                        }
                        .accessibilityIdentifier("dog.edit")
                        .disabled(appState.selectedDogProfile == nil)
                    }
                    // Keep New and Edit as separate visible actions on both platforms.
                    .buttonStyle(.bordered)
                }

                if let profile = appState.selectedDogProfile {
                    AppCard(title: appState.selectedLanguage == .russian
                            ? (appState.showingAllRecordings ? "Все записи" : "Последние 10 записей")
                            : (appState.showingAllRecordings ? "All recordings" : "Last 10 recordings")) {
                        if appState.recentRecordings.isEmpty && appState.serverRecordings.isEmpty {
                            Text(appState.selectedLanguage == .russian ? "У этой собаки пока нет записей" : "No recordings for this dog")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(appState.recentRecordings) { recording in
                            VStack(alignment: .leading, spacing: 8) {
                                if recording.endedAtUTC != nil {
                                    Button(appState.selectedLanguage == .russian ? "Изменить анкету" : "Edit questionnaire") { editingSession = recording }
                                        .disabled(!appState.canEditQuestionnaire(recording))
                                    if recording.questionnaire?.sessionKind == "heart", recording.questionnaire?.readyForSync == false {
                                        Button("Заполнить анкету по сердцебиению") { heartRecording = recording }
                                    }
                                    Button("Добавить ЭКГ / ЧСС / интервалы") {
                                        referenceRecording = recording
                                        isReferenceImporterPresented = true
                                    }
                                    .disabled(recording.serverSyncState == "remote")
                                }
                                VStack(alignment: .leading) {
                                    Text(recording.sessionLabel)
                                    Text(recordingDisplayTime(recording.startedAtUTC)).font(.caption)
                                    Text("\(recording.source) · \(recording.status) · \(recording.serverSyncState)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                if let error = appState.recordingSyncErrors[recording.id] {
                                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                                }
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
                                Text("server · \(recording.source) · \(recording.ingestStatus)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .id(profile.id)
                }

                if appState.isConnectionActive || appState.activeRecording != nil || appState.packetsReceived > 0 {
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

                if appState.isConnectionActive || appState.isReplayRunning {
                    AppCard(title: russian ? "Подключение" : "Connection") {
                        Button(russian ? "ОТКЛЮЧИТЬ" : "DISCONNECT") { appState.disconnect() }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                AppCard(title: russian ? "BLE-устройства" : "BLE devices") {
                    Text(russian ? "Запустите сканирование, выберите найденное устройство или воспроизведите сохраненный дамп." : "Start a scan, pick a discovered device, or replay a captured dump.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(appState.isScanning ? (russian ? "ИДЕТ СКАНИРОВАНИЕ..." : "SCANNING...") : (russian ? "НАЧАТЬ ПОИСК" : "START SCAN")) { appState.startScanning() }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity)
                        .disabled(appState.isScanning || appState.selectedDogProfile == nil)
                        .accessibilityIdentifier("devices.scan")
                    Button(russian ? "Загрузить файл (debug)" : "Upload binary (debug)") { isReplayImporterPresented = true }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                        .disabled(appState.selectedDogProfile == nil)
                        .accessibilityIdentifier("devices.replay")
                    if appState.foundDevices.isEmpty {
                        Text(appState.isScanning ? (russian ? "Идет поиск ближайших BLE-устройств..." : "Scanning for nearby BLE devices...") : (russian ? "Устройства еще не найдены." : "No discovered devices yet."))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.foundDevices) { device in
                            Button {
                                pendingDevice = device
                                pendingReplayURL = nil
                                isSessionEditorPresented = true
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
                .padding(12)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(appState.text(.overview))
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: appState.recentRecordings) { _, records in
                if heartRecording == nil, !isSessionEditorPresented {
                    heartRecording = records.first { $0.endedAtUTC != nil && $0.questionnaire?.sessionKind == "heart" && $0.questionnaire?.readyForSync == false }
                }
            }
            .sheet(item: $editingSession) { recording in
                if let questionnaire = recording.questionnaire {
                    if questionnaire.schemaVersion == 1 {
                        LegacySessionQuestionnaireEditor(language: appState.selectedLanguage, source: recording.source, initial: questionnaire) {
                            appState.saveSessionQuestionnaire($0, displayedRecording: recording)
                        }
                    } else {
                        SessionQuestionnaireEditor(language: appState.selectedLanguage, source: recording.source, initial: questionnaire) {
                            appState.saveSessionQuestionnaire($0, displayedRecording: recording)
                        }
                    }
                }
            }
            .sheet(item: $heartRecording) { recording in
                HeartQuestionnaireEditor(initial: appState.heartQuestionnaireDraft(recordingID: recording.id)) { appState.saveHeartQuestionnaire($0, recordingID: recording.id) }
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
                        appState.attachReference(recordingID: recording.id, type: type, url: url, metadata: metadata)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(appState.text(.export)) {
                        isExportOptionsPresented = true
                    }
                    .disabled(appState.exportPhase != nil)
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
                    appState.saveDogProfile(questionnaire, replacing: presentation.profile)
                }
                .id(presentation.id)
            }
            .sheet(isPresented: $isSessionEditorPresented) {
                SessionQuestionnaireEditor(
                    language: appState.selectedLanguage,
                    source: pendingReplayURL == nil ? "live" : "replay"
                ) { questionnaire in
                    if let device = pendingDevice {
                        appState.connect(to: device, questionnaire: questionnaire)
                    } else if let url = pendingReplayURL {
                        appState.startReplay(from: url, questionnaire: questionnaire)
                    }
                    pendingDevice = nil
                    pendingReplayURL = nil
                }
            }
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
                        .disabled(appState.exportPhase != nil)
                    }
                }
            }
            .navigationTitle(appState.text(.export))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
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
