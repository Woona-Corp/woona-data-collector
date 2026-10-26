import BackgroundTasks
import Foundation
import Network

@MainActor
final class AppViewModel: ObservableObject {
    @Published var selectedTab: AppTab = .overview
    @Published var showingSessionCharts = false
    @Published private(set) var isReplayRunning = false
    @Published private(set) var isConnected = false
    @Published private(set) var isConnectionActive = false
    @Published private(set) var isScanning = false
    @Published private(set) var statusText = "Idle"
    @Published private(set) var foundDevices: [BleDevice] = []
    @Published private(set) var packetsReceived: UInt64 = 0
    @Published private(set) var packetsLost: UInt64 = 0
    @Published private(set) var packetsRejected: UInt64 = 0
    @Published private(set) var timerRegressionRejects: UInt64 = 0
    @Published private(set) var fragmentsReceived: UInt64 = 0
    @Published private(set) var rawBytesReceived: UInt64 = 0
    @Published private(set) var lastPacketIssue: String?
    @Published private(set) var rejectionBreakdown: String?
    @Published private(set) var diagnosticMessages: [String] = []
    @Published private(set) var hasDogIdentityConflict = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var selectedTransportProfile: BleTransportProfile = .iosManaged
    @Published var selectedThemeMode: AppThemeMode = .system {
        didSet { UserDefaults.standard.set(selectedThemeMode.rawValue, forKey: "themeMode") }
    }
    @Published var selectedLanguage: AppLanguage = .english {
        didSet { UserDefaults.standard.set(selectedLanguage.rawValue, forKey: "language") }
    }
    @Published private(set) var selectedSensorType = 2
    @Published private(set) var selectedChannel = 1
    @Published private(set) var chart = ChartUiState()
    @Published private(set) var exportPhase: ExportPhase?
    @Published private(set) var preparedExport: PreparedExport?
    @Published private(set) var isCompleteArchiveExporting = false
    @Published private(set) var completeArchiveProgress: CompleteDataArchive.Progress?
    private var completeArchiveTask: Task<Void, Never>?
    private var completeArchiveWorker: Task<URL, Error>?
    @Published private(set) var dogProfiles: [DogProfile] = []
    @Published private(set) var selectedDogProfile: DogProfile?
    @Published private(set) var recentRecordings: [WoonaRecording] = []
    @Published private(set) var serverRecordings: [ServerRecordingSummary] = []
    @Published private(set) var downloadableRecordingIDs: Set<UUID> = []
    @Published private(set) var exportableRecordingIDs: Set<UUID> = []
    @Published private(set) var recordingFileCounts: [UUID: (local: Int, total: Int)] = [:]
    @Published private(set) var recordingSyncErrors: [UUID: String] = [:]
    @Published private(set) var recordingUploadProgress: [UUID: (bytes: Int64, total: Int64, verified: Int, files: Int)] = [:]
    @Published private(set) var showingAllRecordings = false
    @Published private(set) var removingLocalRecordingID: UUID?
    @Published private(set) var downloadingRecordingID: UUID?
    @Published private(set) var activeRecording: WoonaRecording?
    @Published private(set) var isCaptureReady = false
    @Published private(set) var isRecording = false
    @Published private(set) var isCameraDegraded = false
    @Published var serverBaseURL = ""
    @Published var serverToken = ""
    @Published var serverWifiOnly = true
    @Published var accountInput = ""
    @Published private(set) var selectedAccountID: String?
    @Published private(set) var unassignedDogProfiles: [DogProfile] = []
    @Published private(set) var isAccountOperationRunning = false
    @Published private var uploadingProfileCount = 0
    @Published private var scheduledSyncCount = 0

    @Published private(set) var localProfileCount = 0
    @Published private(set) var localRecordingCount = 0
    @Published private(set) var hiddenProfileCount = 0
    @Published private(set) var uploadPending = 0
    @Published private(set) var uploadRunning = 0
    @Published private(set) var uploadSynced = 0
    @Published private(set) var uploadFailed = 0
    @Published private(set) var uploadLastError: String?
    @Published private(set) var networkAvailable: Bool?
    @Published private(set) var networkUnmetered: Bool?
    @Published private(set) var connectionCheck = "not_checked"
    @Published private(set) var connectionCheckedAt: String?
    @Published private(set) var connectionCheckError: String?
    @Published private(set) var serverTransferStatuses: [UUID: ServerTransferStatus] = [:]
    @Published private(set) var transferStatusErrors: [UUID: String] = [:]
    @Published private(set) var checkingTransferIDs: Set<UUID> = []
    private var networkMonitor: NWPathMonitor?

    var uploadQueueExplanation: String {
        let ru = selectedLanguage == .russian
        if serverToken.isEmpty { return ru ? "Сервер не подключён. Данные сохраняются на телефоне; настройте адрес и токен." : "Server is not configured. Data stays on this phone; configure the address and token." }
        if isAccountOperationRunning { return ru ? "Выполняется операция с аккаунтом или восстановление. Существующие локальные файлы сохраняются." : "An account or restore operation is running. Existing local files are preserved." }
        if networkAvailable == false { return ru ? "Нет интернета. Очередь сохранена; отправка продолжится после подключения." : "No internet. The queue is saved and will resume when connected." }
        if serverWifiOnly && networkUnmetered == false { return ru ? "Отправка ждёт Wi-Fi или сети без тарификации. Подключите её либо отключите ограничение." : "Uploads are waiting for Wi-Fi or an unmetered network. Connect or disable the restriction." }
        if uploadFailed > 0 { return ru ? "Есть ошибки доставки. Откройте причину в записи; повторите отправку после устранения причины." : "Some transfers failed. Open the recording for its cause; retry after correcting it." }
        if !syncingRecordingIDs.isEmpty || uploadingProfileCount > 0 { return ru ? "Обрабатываем очередь: подготовка, передача и проверка целостности. Переданные байты ещё не подтверждают копию." : "Processing the queue: preparation, transfer and integrity checks. Transferred bytes alone do not confirm a verified copy." }
        if uploadPending > 0 { return ru ? "Сессии ожидают запуска, анкеты или повтора. Нажмите «Повторить выгрузку». Незавершённая анкета сессии должна быть заполнена." : "Sessions are waiting for their questionnaire, a start or a retry. Use Retry uploads. Complete any unfinished session questionnaire." }
        return ru ? "Локальная очередь пуста. Это не проверка доступности сервера и не статус разметки Label Studio." : "The local queue is empty. This does not verify server availability or Label Studio annotation status."
    }

    func checkServerConnection() {
        guard connectionCheck != "checking" else { return }
        let configuration = ServerConfiguration(baseURL: serverBaseURL, wifiOnly: serverWifiOnly, accountID: selectedAccountID)
        let token = serverToken
        connectionCheck = "checking"; connectionCheckError = nil
        Task {
            do {
                try await WoonaServerClient(configuration: configuration, token: token).checkConnection()
                guard configuration == ServerConfiguration(baseURL: serverBaseURL, wifiOnly: serverWifiOnly, accountID: selectedAccountID), token == serverToken else { connectionCheck = "not_checked"; return }
                connectionCheck = "verified"
            } catch {
                guard configuration == ServerConfiguration(baseURL: serverBaseURL, wifiOnly: serverWifiOnly, accountID: selectedAccountID), token == serverToken else { connectionCheck = "not_checked"; return }
                connectionCheck = "failed"
                connectionCheckError = recordingUploadErrorText(error.localizedDescription, language: selectedLanguage) + "\n" + error.localizedDescription
            }
            connectionCheckedAt = WoonaStore.iso8601(Date())
        }
    }

    func checkRecordingTransfer(_ id: UUID) {
        guard !checkingTransferIDs.contains(id) else { return }
        let account = selectedAccountID
        checkingTransferIDs.insert(id)
        Task {
            defer { checkingTransferIDs.remove(id) }
            do {
                let status = try await serverClient(accountID: account).syncStatus(id)
                guard selectedAccountID == account else { return }
                serverTransferStatuses[id] = status
                transferStatusErrors[id] = nil
            } catch {
                guard selectedAccountID == account else { return }
                transferStatusErrors[id] = recordingUploadErrorText(error.localizedDescription, language: selectedLanguage) + "\n" + error.localizedDescription
            }
        }
    }

    var canChangeAccount: Bool {
        completeArchiveTask == nil && !isAccountOperationRunning && !isConnectionActive && !isReplayRunning && !isRecording &&
        !captureStopInProgress && activeRecording == nil && syncingRecordingIDs.isEmpty &&
        uploadingProfileCount == 0 && scheduledSyncCount == 0 && downloadingRecordingID == nil && removingLocalRecordingID == nil
    }

    let cameraRecorder = CameraRecorder()

    private lazy var packetProcessor = makePacketProcessor()
    private lazy var packetUpdateBatcher = makePacketUpdateBatcher()
    private lazy var packetFragmentSubmitter = makePacketFragmentSubmitter()
    private lazy var bleSessionManager = makeBleSessionManager()
    private lazy var replayController = makeReplayController()
    private let packetIngressGate = PacketIngressGate()
    private let keychainTokenStore = KeychainTokenStore()
    private let store: WoonaStore?
    private var currentSessionWallClockStartMillis: Int64?
    private var chartHistory: [ChartStreamKey: [ChartPoint]] = [:]
    private var sessionStartMillis: UInt64?
    private var latestChartTimeMillis: UInt64?
    private var chartWindowPreset: ChartWindowPreset = .thirtySeconds
    private var isFollowingLive = true
    private var manualViewportEndMillis: UInt64?
    private var chartVerticalZoomFactor: Float = 1
    private var chartVerticalCenterOverride: Float?
    private var hasInitializedBleSessionManager = false
    private var isCaptureDiagnosticsActive = false
    private var finishCaptureProcessingTask: Task<Void, Never>?
    private var finishCaptureProcessingTaskID: UInt64 = 0
    private var preparedExportSnapshotDirectory: URL?
    private var cameraCaptureInfo: CameraCaptureInfo?
    private var captureErrorCode: String?
    private var captureErrorMessage: String?
    private var captureSessionZeroAtUTC: String?
    private var captureSessionZeroWallClockMs: Int64?
    private var captureSessionZeroMonotonicNs: UInt64?
    private var captureSessionZeroUncertaintyNs: UInt64?
    private var captureStopInProgress = false
    private var hasPreparedActiveCapture = false
    @Published private var syncingRecordingIDs = Set<UUID>()

    init(store: WoonaStore? = try? WoonaStore(), uiTesting: Bool = false) {
        self.store = store
        let defaults = UserDefaults.standard
        selectedThemeMode = defaults.string(forKey: "themeMode").flatMap(AppThemeMode.init(rawValue:)) ?? .system
        selectedLanguage = defaults.string(forKey: "language").flatMap(AppLanguage.init(rawValue:)) ?? .english
        serverBaseURL = defaults.string(forKey: "serverBaseURL") ?? "https://cool-trams.digital"
        serverWifiOnly = defaults.object(forKey: "serverWifiOnly") as? Bool ?? true
        serverToken = keychainTokenStore.load()
        selectedAccountID = defaults.string(forKey: "selectedAccountID")
        accountInput = selectedAccountID ?? ""
        if uiTesting {
            selectedLanguage = .english
            selectedThemeMode = .light
            selectedAccountID = nil
            accountInput = ""
            serverToken = ""
            serverBaseURL = ""
        }
        cameraRecorder.onRecordingFailure = { [weak self] message in
            Task { @MainActor in self?.handleCameraFailure(message) }
        }
        reloadProfiles(selecting: defaults.string(forKey: "selectedDogID").flatMap(UUID.init(uuidString:)))
        if uiTesting, let profile = dogProfiles.first(where: { $0.numberOrName == "UI Dog 1" }) { selectDogProfile(profile) }
        if store == nil { errorMessage = "Unable to open local Woona database" }
        if !uiTesting {
            let monitor = NWPathMonitor()
            networkMonitor = monitor
            monitor.pathUpdateHandler = { [weak self] path in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let wasBlocked = self.networkAvailable == false || (self.serverWifiOnly && self.networkUnmetered == false)
                    self.networkAvailable = path.status == .satisfied
                    self.networkUnmetered = !path.isExpensive
                    if wasBlocked && self.networkAvailable == true && (!self.serverWifiOnly || self.networkUnmetered == true) { self.schedulePendingSync() }
                }
            }
            monitor.start(queue: DispatchQueue(label: "woona.network-status"))
            registerBackgroundSync()
            schedulePendingSync()
        }
    }

    deinit { networkMonitor?.cancel() }

    enum AppTab: Hashable {
        case overview
        case session
        case video
        case recordings
        case settings
    }

    var currentTransportProfileTitle: String {
        selectedTransportProfile.title
    }

    func saveDogProfile(_ questionnaire: DogQuestionnaire, replacing profile: DogProfile? = nil) {
        guard !isAccountOperationRunning, let store else { return }
        guard profile == nil || profile?.accountID == selectedAccountID else { return }
        do {
            let saved = try store.saveProfile(questionnaire, replacing: profile, accountID: selectedAccountID)
            reloadProfiles(selecting: saved.id)
            uploadingProfileCount += 1
            Task {
                defer { uploadingProfileCount -= 1 }
                await uploadProfile(saved)
            }
        } catch { showError("Failed to save dog profile", error: error) }
    }

    func selectDogProfile(_ profile: DogProfile) {
        guard profile.accountID == selectedAccountID else { return }
        serverRecordings = []
        selectedDogProfile = profile
        showingAllRecordings = false
        UserDefaults.standard.set(profile.id.uuidString, forKey: "selectedDogID")
        reloadRecentRecordings()
        Task { await reloadServerRecordings() }
    }

    func saveServerSettings() {
        guard canChangeAccount else { return }
        connectionCheck = "not_checked"; connectionCheckedAt = nil; connectionCheckError = nil
        serverBaseURL = serverBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        serverToken = serverToken.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(serverBaseURL, forKey: "serverBaseURL")
        UserDefaults.standard.set(serverWifiOnly, forKey: "serverWifiOnly")
        do { try keychainTokenStore.save(serverToken) }
        catch { showError("Failed to store server token", error: error) }
    }

    func applyAccount() {
        guard canChangeAccount, let store else { return }
        do {
            let account = try WoonaServerClient.normalizedAccount(accountInput)
            if serverToken.isEmpty || serverBaseURL.isEmpty {
                selectedAccountID = account
                accountInput = account ?? ""
                UserDefaults.standard.set(account, forKey: "selectedAccountID")
                serverRecordings = []
                showingAllRecordings = false
                reloadProfiles()
                return
            }
            let client = try serverClient(accountID: account)
            isAccountOperationRunning = true
            Task {
                defer { isAccountOperationRunning = false; schedulePendingSync() }
                do {
                    try await client.applyAccount()
                    selectedAccountID = account
                    accountInput = account ?? ""
                    UserDefaults.standard.set(account, forKey: "selectedAccountID")
                    serverRecordings = []
                    showingAllRecordings = false
                    reloadProfiles()
                    let restored = try await client.restoreProfiles(into: store)
                    _ = try await client.restoreRecordings(dogIDs: restored.map(\.id), into: store)
                    reloadProfiles()
                    await reloadServerRecordings()
                } catch { showError("Account restore failed; retry Apply", error: error) }
            }
        } catch { showError("Invalid account", error: error) }
    }

    func linkUnassignedDog(_ dog: DogProfile) {
        guard canChangeAccount, let account = selectedAccountID, dog.accountID == nil, let store else { return }
        isAccountOperationRunning = true
        Task {
            defer { isAccountOperationRunning = false; schedulePendingSync() }
            do {
                let client = try serverClient(accountID: account)
                do { try await client.linkDog(dog.id) }
                catch ServerSyncError.requestFailed(404, _) {
                    guard dog.revision == 0 else { throw WoonaStoreError.invalidData("Server dog was not found; restore before linking") }
                    // A never-uploaded local dog can be explicitly assigned before its first upload.
                }
                try store.linkDog(dogID: dog.id, accountID: account)
                reloadProfiles(selecting: dog.id)
                if let linked = selectedDogProfile { await uploadProfile(linked) }
            } catch { showError("Dog link failed", error: error) }
        }
    }

    func refreshFromServer() {
        guard canChangeAccount, let store else { return }
        saveServerSettings()
        isAccountOperationRunning = true
        Task {
            defer { isAccountOperationRunning = false; schedulePendingSync() }
            do {
                let client = try serverClient()
                _ = try await client.deviceID()
                let restored = try await client.restoreProfiles(into: store)
                _ = try await client.restoreRecordings(dogIDs: restored.map(\.id), into: store)
                reloadProfiles(selecting: selectedDogProfile?.id)
                await reloadServerRecordings()
                appendDiagnostic("Server restore completed")
            } catch { showError("Server restore failed", error: error) }
        }
    }

    private func schedulePendingSync() {
        scheduledSyncCount += 1
        Task {
            defer { scheduledSyncCount -= 1 }
            await resumePendingSync()
        }
    }

    private func scheduleSync(_ recording: WoonaRecording) {
        scheduledSyncCount += 1
        Task {
            defer { scheduledSyncCount -= 1 }
            await sync(recording: recording)
        }
    }

    func resumePendingSync() async {
        guard !serverToken.isEmpty, let store else { return }
        do {
            for recording in try store.pendingRecordings() {
                await sync(recording: recording)
            }
            reloadRecentRecordings()
        } catch { appendDiagnostic("Pending sync unavailable: \(error.localizedDescription)") }
    }

    func canRemoveLocalRecording(_ recording: WoonaRecording) -> Bool {
        canChangeAccount && exportPhase == nil && preparedExport == nil && recording.serverSyncState == "synced" &&
        !recording.questionnaireDirty && recording.endedAtUTC != nil &&
        (recordingFileCounts[recording.id]?.local ?? 0) > 0
    }

    func removeLocalRecordingFiles(_ recordingID: UUID) {
        guard let store, let recording = try? store.recording(id: recordingID), canRemoveLocalRecording(recording) else { return }
        removingLocalRecordingID = recordingID
        Task {
            defer { removingLocalRecordingID = nil; reloadRecentRecordings() }
            do {
                let client = try serverClient(accountID: selectedAccountID)
                let status = try await client.syncStatus(recordingID)
                guard status.confirmsCurrentServerCopy else { throw WoonaStoreError.invalidData("server_copy_unverified") }
                let remote = try await client.recordingDetail(recordingID)
                let plan = try store.localRemovalPlan(recordingID: recordingID, verifiedRemote: remote)
                _ = try await Task.detached(priority: .userInitiated) { try plan.removeFiles() }.value
                appendDiagnostic(selectedLanguage == .russian ? "Локальные файлы удалены. Сессия осталась на сервере" : "Local files removed. The session remains on the server")
            } catch {
                showError(selectedLanguage == .russian ? "Удаление с устройства не выполнено" : "Removal from this device failed",
                          error: WoonaStoreError.invalidData(recordingUploadErrorText(error.localizedDescription, language: selectedLanguage)))
            }
        }
    }

    func downloadRecording(_ recordingID: UUID) {
        guard downloadingRecordingID == nil, removingLocalRecordingID == nil, let store else { return }
        downloadingRecordingID = recordingID
        Task {
            defer { downloadingRecordingID = nil }
            do {
                let client = try serverClient()
                for artifact in try store.missingArtifacts(recordingID: recordingID) where artifact.uploadState == "available" {
                    let target = store.rootDirectory.appendingPathComponent(artifact.relativePath)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try await client.download(
                        artifactID: artifact.id,
                        to: target,
                        expectedSize: artifact.sizeBytes,
                        sha256: artifact.sha256
                    )
                }
                reloadRecentRecordings()
                appendDiagnostic("Server files downloaded and verified")
            } catch { showError("Server download failed", error: error) }
        }
    }

    func retryFailedSync() {
        guard let store else { return }
        do {
            try store.resetFailedSync()
            schedulePendingSync()
        } catch { showError("Failed to retry synchronization", error: error) }
    }

    func scheduleBackgroundSync() {
        let request = BGProcessingTaskRequest(identifier: Self.backgroundSyncIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    func applyConnectionState(isConnected: Bool) {
        guard !isReplayRunning else { return }
        self.isConnected = isConnected
        isConnectionActive = isConnected
        statusText = isConnected ? "Connected" : "Disconnected"
    }

    func addFoundDevice(_ device: BleDevice) {
        if let existingIndex = foundDevices.firstIndex(where: { $0.id == device.id }) {
            foundDevices[existingIndex] = device
        } else {
            foundDevices.append(device)
        }
    }

    func startScanning() {
        foundDevices.removeAll(keepingCapacity: true)
        errorMessage = nil
        _ = bleSessionManager
        bleSessionManager.startScanning(useServiceFilter: false)
    }

    func stopScanning() {
        bleSessionManager.stopScanning()
    }

    func connect(to device: BleDevice) {
        Task {
            var didPrepareCapture = false
            let didStartConnection = await bleSessionManager.connect(to: device.id) {
                didPrepareCapture = true
                await prepareCaptureForConnection()
            }
            if didPrepareCapture, !didStartConnection {
                await finishCaptureProcessing()
            }
            if !didStartConnection, activeRecording != nil {
                stopActiveCapture(status: "failed")
            }
        }
    }

    func connect(to device: BleDevice, questionnaire: SessionQuestionnaire) {
        guard !isAccountOperationRunning else { return }
        guard activeRecording == nil, !captureStopInProgress else { return }
        guard let profile = selectedDogProfile, let store else {
            showError("Select or create a dog profile first", error: nil)
            return
        }
        do {
            activeRecording = try store.createRecording(profile: profile, source: "live", questionnaire: questionnaire)
            isCaptureReady = false
            isRecording = false
            isCameraDegraded = false
            cameraCaptureInfo = nil
            captureErrorCode = nil
            captureErrorMessage = nil
            captureStopInProgress = false
            hasPreparedActiveCapture = false
            resetCaptureClockAnchor()
            connect(to: device)
        } catch { showError("Failed to create recording", error: error) }
    }

    func disconnect() {
        if activeRecording != nil {
            stopActiveCapture(status: isRecording ? "completed" : "interrupted")
            return
        }
        bleSessionManager.disconnect()
        finishCaptureProcessingIfNeeded()
    }

    func startReplay(from fileURL: URL) {
        Task {
            do {
                let didAccess = fileURL.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        fileURL.stopAccessingSecurityScopedResource()
                    }
                }
                let bytes = try [UInt8](Data(contentsOf: fileURL))
                packetUpdateBatcher.clearPending()
                await packetProcessor.resetSession()
                hasPreparedActiveCapture = true
                packetUpdateBatcher.clearPending()
                await replayController.startReplay(bytes)
            } catch {
                await packetProcessor.resetSession()
                showError("Failed to load replay file", error: error)
                if activeRecording?.source == "replay" { stopActiveCapture(status: "failed") }
            }
        }
    }

    func startReplay(from fileURL: URL, questionnaire: SessionQuestionnaire) {
        guard !isAccountOperationRunning else { return }
        guard activeRecording == nil, !captureStopInProgress else { return }
        guard let profile = selectedDogProfile, let store else {
            showError("Select or create a dog profile first", error: nil)
            return
        }
        do {
            activeRecording = try store.createRecording(profile: profile, source: "replay", questionnaire: questionnaire)
            cameraCaptureInfo = nil
            captureErrorCode = nil
            captureErrorMessage = nil
            captureStopInProgress = false
            hasPreparedActiveCapture = false
            resetCaptureClockAnchor()
            startReplay(from: fileURL)
        } catch { showError("Failed to create replay recording", error: error) }
    }

    func startActiveCapture() {
        guard isCaptureReady, !isRecording, !captureStopInProgress,
              let recording = activeRecording, let store else { return }
        do { try store.markRecording(recording.id, status: "recording") }
        catch { showError("Failed to start recording", error: error); return }
        isRecording = true
        statusText = "Recording"
        setCaptureClockAnchor()
        packetIngressGate.start()
        guard recording.videoRequested else { return }
        guard !isCameraDegraded else { return }
        let output = store.directory(for: recording).appendingPathComponent("video.mp4")
        Task {
            do { _ = try await cameraRecorder.startRecording(to: output) }
            catch {
                handleCameraFailure(error.localizedDescription)
            }
        }
    }

    func stopActiveCapture(status: String = "completed") {
        guard let recording = activeRecording, !captureStopInProgress else { return }
        captureStopInProgress = true
        packetIngressGate.stop()
        isRecording = false
        statusText = "Finalizing"
        Task {
            if recording.videoRequested {
                do { cameraCaptureInfo = try await cameraRecorder.stopRecording() }
                catch {
                    handleCameraFailure(error.localizedDescription)
                }
            }
            cameraRecorder.stopPreview()
            if recording.source == "live" { bleSessionManager.disconnect() }
            else { await replayController.stop() }
            await finishCaptureProcessing()
            await finalizeActiveRecording(recording, requestedStatus: status)
        }
    }

    func stopReplay() {
        Task {
            await replayController.stop()
        }
    }

    func startReplaySession() {
        setCaptureClockAnchor()
        currentSessionWallClockStartMillis = Self.currentWallClockMillis()
        clearChartHistory()
        resetCounters()
        selectedTab = .session
        isReplayRunning = true
        isConnected = false
        isConnectionActive = false
        isScanning = false
        statusText = "Replay"
        foundDevices.removeAll(keepingCapacity: true)
        errorMessage = nil
    }

    func finishReplaySession() {
        packetUpdateBatcher.flushNow()
        isReplayRunning = false
        if let recording = activeRecording {
            guard !captureStopInProgress else { return }
            captureStopInProgress = true
            Task {
                await finishCaptureProcessing()
                await finalizeActiveRecording(recording, requestedStatus: packetsReceived > 0 ? "completed" : "failed")
            }
        } else {
            statusText = "Idle"
        }
    }

    func stopCaptureSession() {
        isReplayRunning = false
        isConnected = false
        isConnectionActive = false
        isScanning = false
        statusText = "Idle"
        foundDevices.removeAll(keepingCapacity: true)
    }

    func enterBackground() {
        if activeRecording != nil {
            stopActiveCapture(status: "interrupted")
            return
        }
        if hasInitializedBleSessionManager {
            bleSessionManager.stopScanning()
            bleSessionManager.disconnect()
        }
        Task {
            await replayController.stop()
            await finishCaptureProcessing()
        }
        isScanning = false
        isConnected = false
        isConnectionActive = false
        statusText = "Background"
    }

    func reportError(_ message: String, error: Error? = nil) {
        showError(message, error: error)
    }

    func text(_ key: AppTextKey) -> String {
        key.localized(language: selectedLanguage)
    }

    func title(for exportKind: ExportKind) -> String {
        exportKind.localizedTitle(language: selectedLanguage)
    }

#if DEBUG
    func applyPacketUpdateForTesting(_ update: PacketProcessingUpdate) {
        applyPacketUpdate(update)
    }

    func beginCaptureDiagnosticsForTesting() async {
        await prepareCaptureForConnection()
    }

    func submitPacketFragmentForTesting(_ fragment: [UInt8]) {
        packetFragmentSubmitter.enqueue(fragment)
    }

    func applyBleStateForTesting(_ state: BleSessionState) {
        applyBleState(state)
    }

    func finishCaptureProcessingForTesting() async {
        await finishCaptureProcessing()
    }

    func hasOpenOutputFilesForTesting() async -> Bool {
        await packetProcessor.hasOpenOutputFiles()
    }

    func currentPacketFileForTesting() async -> URL? {
        await packetProcessor.currentPacketFile()
    }
#endif

    func selectSensorType(_ sensorType: Int) {
        selectedSensorType = sensorType
        selectedChannel = 1
        chartVerticalCenterOverride = nil
        rebuildChartState()
    }

    func selectChannel(_ channel: Int) {
        selectedChannel = channel
        chartVerticalCenterOverride = nil
        rebuildChartState()
    }

    func selectChartWindow(_ preset: ChartWindowPreset) {
        chartWindowPreset = preset
        chartVerticalCenterOverride = nil
        rebuildChartState()
    }

    func setFollowLive(_ enabled: Bool) {
        isFollowingLive = enabled
        manualViewportEndMillis = enabled ? nil : latestChartTimeMillis
        chartVerticalCenterOverride = nil
        rebuildChartState()
    }

    func jumpToLive() {
        setFollowLive(true)
    }

    func panChartLeft() {
        guard let latest = latestChartTimeMillis, let sessionStartMillis else { return }
        let currentEnd = resolveViewportEnd(latest: latest)
        let duration = effectiveViewportDurationMillis(viewportEnd: currentEnd)
        guard duration > 0 else { return }
        let minViewportEnd = min(sessionStartMillis + duration, latest)
        let panStep = chartPanStepMillis(viewportEnd: currentEnd)
        let shiftedEnd = currentEnd > panStep ? currentEnd - panStep : 0
        chartVerticalCenterOverride = nil
        isFollowingLive = false
        manualViewportEndMillis = max(shiftedEnd, minViewportEnd)
        rebuildChartState()
    }

    func panChartRight() {
        guard let latest = latestChartTimeMillis else { return }
        let currentEnd = resolveViewportEnd(latest: latest)
        let shiftedEnd = min(currentEnd + chartPanStepMillis(viewportEnd: currentEnd), latest)
        chartVerticalCenterOverride = nil
        isFollowingLive = shiftedEnd >= latest
        manualViewportEndMillis = isFollowingLive ? nil : shiftedEnd
        rebuildChartState()
    }

    func panChart(byFraction deltaFraction: Double) {
        guard
            let latest = latestChartTimeMillis
        else { return }
        let viewportEnd = resolveViewportEnd(latest: latest)

        let duration = effectiveViewportDurationMillis(viewportEnd: viewportEnd)
        guard duration > 0 else { return }
        let deltaMillis = Int64(Double(duration) * deltaFraction)
        guard deltaMillis != 0, let sessionStartMillis else { return }

        let minViewportEnd = min(sessionStartMillis + duration, latest)
        let shiftedEnd: UInt64
        if deltaMillis < 0 {
            shiftedEnd = viewportEnd > UInt64(abs(deltaMillis)) ? viewportEnd - UInt64(abs(deltaMillis)) : 0
        } else {
            shiftedEnd = viewportEnd + UInt64(deltaMillis)
        }

        chartVerticalCenterOverride = nil
        let clampedEnd = min(max(shiftedEnd, minViewportEnd), latest)
        isFollowingLive = clampedEnd >= latest
        manualViewportEndMillis = isFollowingLive ? nil : clampedEnd
        rebuildChartState()
    }

    func zoomChart(scaleFactor: Float, anchorFractionY: Float = 0.5) {
        guard scaleFactor > 0 else { return }
        let currentRange = chart.yAxisAbsRange
        let currentCenter = chart.yAxisCenter
        let nextZoomFactor = min(max(chartVerticalZoomFactor * scaleFactor, 1), 64)
        guard nextZoomFactor != chartVerticalZoomFactor else { return }

        let nextRange = chartYAxisAbsRange(zoomFactor: nextZoomFactor)
        chartVerticalZoomFactor = nextZoomFactor
        if nextZoomFactor == 1 {
            chartVerticalCenterOverride = nil
        } else {
            let clampedAnchor = min(max(anchorFractionY, 0), 1)
            let anchorCoefficient = 1 - (2 * clampedAnchor)
            chartVerticalCenterOverride = currentCenter + ((currentRange - nextRange) * anchorCoefficient)
        }
        rebuildChartState()
    }

    func zoomChartIn() {
        zoomChart(scaleFactor: 2)
    }

    func zoomChartOut() {
        zoomChart(scaleFactor: 0.5)
    }

    func resetChartY() {
        chartVerticalZoomFactor = 1
        chartVerticalCenterOverride = nil
        rebuildChartState()
    }

    func prepareCompleteDataArchive() {
        guard let store else {
            showError(selectedLanguage == .russian ? "Локальная база недоступна. Полный архив не создан; исходные файлы не изменены." : "The local database is unavailable. The complete archive was not created; original files are unchanged.", error: nil)
            return
        }
        guard exportPhase == nil, canChangeAccount else {
            showError(selectedLanguage == .russian ? "Сначала завершите запись и операции с сервером, затем повторите экспорт." : "Finish recording and server operations, then retry export.", error: nil)
            return
        }
        isCompleteArchiveExporting = true
        discardPreparedExportSnapshot()
        preparedExport = nil
        exportPhase = .preparingSnapshots
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("WoonaAllData-\(UUID().uuidString)", isDirectory: true)
        preparedExportSnapshotDirectory = directory
        var roots: [CompleteDataArchive.Root] = []
        if let documents = manager.urls(for: .documentDirectory, in: .userDomainMask).first {
            roots.append(.init(prefix: "data/documents", directory: documents))
        }
        if let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            roots.append(.init(prefix: "data/recovered-cache", directory: caches, legacyOnly: true))
        }
        roots.append(.init(prefix: "data/recovered-temporary", directory: manager.temporaryDirectory, legacyOnly: true))
        let exporter = CompleteDataArchive(dataDirectory: store.rootDirectory, additionalRoots: roots, configuration: [
            "language": selectedLanguage.rawValue, "theme": selectedThemeMode.rawValue,
            "transport": String(describing: selectedTransportProfile), "wifiOnly": String(serverWifiOnly),
            "serverConfigured": String(!serverBaseURL.isEmpty && !serverToken.isEmpty),
            "selectedAccountId": selectedAccountID ?? "", "selectedDogId": selectedDogProfile?.id.uuidString ?? "",
        ])
        completeArchiveTask = Task {
            do {
                let worker = Task.detached(priority: .userInitiated) { [weak self] in
                    var lastUpdate = Date.distantPast
                    return try exporter.create(in: directory.appendingPathComponent("Woona-All-Data.zip"), onProgress: { progress in
                        if Date().timeIntervalSince(lastUpdate) >= 0.1 || progress.completedFiles == progress.totalFiles {
                            lastUpdate = Date()
                            Task { @MainActor [weak self] in
                                if self?.isCompleteArchiveExporting == true { self?.completeArchiveProgress = progress }
                            }
                        }
                    })
                }
                completeArchiveWorker = worker
                let url = try await worker.value
                try Task.checkCancellation()
                exportPhase = .openingShareSheet
                preparedExport = PreparedExport(kind: .all, urls: [url])
            } catch is CancellationError {
                exportPhase = nil
                discardPreparedExportSnapshot()
            } catch {
                exportPhase = nil
                discardPreparedExportSnapshot()
                showError(selectedLanguage == .russian ? "Архив не создан. Исходные данные сохранены. Причина" : "Archive was not created. Original data is safe. Reason", error: error)
            }
            isCompleteArchiveExporting = false
            completeArchiveProgress = nil
            completeArchiveWorker = nil
            completeArchiveTask = nil
        }
    }

    func cancelCompleteDataArchive() {
        completeArchiveWorker?.cancel()
        completeArchiveTask?.cancel()
    }

    func prepareExport(_ kind: ExportKind) {
        guard exportPhase == nil, removingLocalRecordingID == nil else { return }
        if kind == .all {
            guard activeRecording == nil else {
                showError("Stop and finalize the recording before exporting its ZIP", error: nil)
                return
            }
            guard let recording = recentRecordings.first(where: { exportableRecordingIDs.contains($0.id) }) else {
                showError("No saved local session files; download a recording first", error: nil)
                return
            }
            shareRecording(recording.id)
            return
        }
        exportPhase = .preparingSnapshots
        Task {
            do {
                discardPreparedExportSnapshot()
                preparedExport = nil
                await packetProcessor.flush()
                packetUpdateBatcher.flushNow()
                let recording = activeRecording == nil ? recentRecordings.first(where: { exportableRecordingIDs.contains($0.id) }) : nil
                let saved = try recording.flatMap { try store?.recordingArchive(recordingID: $0.id) }
                let currentPacket = await packetProcessor.currentPacketFile()
                let currentRaw = await packetProcessor.currentRawFile()
                let currentLog = await packetProcessor.currentLogFile()
                let snapshot = try snapshotExportArtifacts(
                    packetFile: saved == nil ? currentPacket : saved?.files.first { $0.url.lastPathComponent == "packets.bin" }?.url,
                    rawFile: saved == nil ? currentRaw : saved?.files.first { $0.url.lastPathComponent == "raw_fragments.binlog" }?.url,
                    logFile: saved == nil ? currentLog : saved?.files.first { $0.url.lastPathComponent == "diagnostics.log" }?.url
                )
                preparedExportSnapshotDirectory = snapshot.directory

                let packetFile = snapshot.packetFile
                let rawFile = snapshot.rawFile
                let logFile = snapshot.logFile
                let savedManifest = try saved.flatMap { try JSONSerialization.jsonObject(with: $0.manifest) as? [String: Any] }
                let savedStart = (savedManifest?["sessionStartMillis"] as? NSNumber)?.int64Value
                var urls: [URL] = []

                switch kind {
                case .all:
                    break // Full session ZIP is handled above, using persisted recording metadata.
                case .packetDump:
                    urls.append(contentsOf: [packetFile].compactMap { $0 })
                case .channelCsv:
                    if let csv = try await createCsvExport(packetFile: packetFile, sessionStartMillis: savedStart) {
                        urls.append(csv)
                    }
                case .rawFragments:
                    urls.append(contentsOf: [rawFile].compactMap { $0 })
                case .diagnosticLog:
                    urls.append(contentsOf: [logFile].compactMap { $0 })
                }

                guard !urls.isEmpty else {
                    exportPhase = nil
                    discardPreparedExportSnapshot()
                    showError("No \(kind.title.lowercased()) artifact is available yet", error: nil)
                    return
                }

                exportPhase = .openingShareSheet
                preparedExport = PreparedExport(kind: kind, urls: urls)
            } catch {
                exportPhase = nil
                discardPreparedExportSnapshot()
                showError("Failed to prepare \(kind.title.lowercased()) export", error: error)
            }
        }
    }

    func clearPreparedExport() {
        preparedExport = nil
        exportPhase = nil
        discardPreparedExportSnapshot()
    }

    func shareRecording(_ recordingID: UUID) {
        guard exportPhase == nil, removingLocalRecordingID == nil else { return }
        exportPhase = .preparingSnapshots
        discardPreparedExportSnapshot()
        preparedExport = nil
        Task {
            do {
                guard let store else { throw WoonaStoreError.invalidData("Local recording database is unavailable") }
                let archive = try store.recordingArchive(recordingID: recordingID)
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WoonaExport-\(UUID().uuidString)", isDirectory: true)
                preparedExportSnapshotDirectory = directory
                let url = try await Task.detached(priority: .userInitiated) { try archive.create(in: directory) }.value
                exportPhase = .openingShareSheet
                preparedExport = PreparedExport(kind: .all, urls: [url])
            } catch {
                exportPhase = nil
                discardPreparedExportSnapshot()
                showError("Failed to export session ZIP", error: error)
            }
        }
    }

    func saveSessionQuestionnaire(_ questionnaire: SessionQuestionnaire, displayedRecording: WoonaRecording) {
        guard canEditQuestionnaire(displayedRecording), let store, let profile = try? store.profile(dogID: displayedRecording.dogID, versionID: displayedRecording.profileVersionID),
              profile.accountID == selectedAccountID else { return }
        if ["synced", "remote"].contains(displayedRecording.serverSyncState) {
            isAccountOperationRunning = true
            Task {
                defer { isAccountOperationRunning = false; schedulePendingSync() }
                do {
                    let detail = try await serverClient(accountID: profile.accountID).updateQuestionnaire(
                        recordingID: displayedRecording.id, questionnaire: questionnaire,
                        expectedRevision: displayedRecording.questionnaireRevision)
                    let canonical = try JSONDecoder().decode(SessionQuestionnaire.self, from: JSONEncoder().encode(detail.sessionQuestionnaire))
                    try store.saveSessionQuestionnaire(recordingID: detail.id, questionnaire: canonical, revision: detail.questionnaireRevision ?? 1)
                    reloadRecentRecordings()
                } catch ServerSyncError.requestFailed(409, _) {
                    showError("Questionnaire changed on the server. Use Restore questionnaire from server, then reopen the editor before saving", error: ServerSyncError.requestFailed(409, "Revision conflict"))
                } catch { showError("Questionnaire save failed; reopen to retry", error: error) }
            }
        } else {
            guard !syncingRecordingIDs.contains(displayedRecording.id) else { return }
            do {
                try store.saveSessionQuestionnaire(recordingID: displayedRecording.id, questionnaire: questionnaire)
                reloadRecentRecordings()
                if let updated = try store.recording(id: displayedRecording.id) { scheduleSync(updated) }
            } catch { showError("Questionnaire save failed", error: error) }
        }
    }

    func restoreSessionQuestionnaire(_ recording: WoonaRecording) {
        guard canEditQuestionnaire(recording), let store,
              let profile = try? store.profile(dogID: recording.dogID, versionID: recording.profileVersionID),
              profile.accountID == selectedAccountID else { return }
        isAccountOperationRunning = true
        Task {
            defer { isAccountOperationRunning = false; schedulePendingSync() }
            do {
                let detail = try await serverClient(accountID: profile.accountID).recordingDetail(recording.id)
                let canonical = try JSONDecoder().decode(SessionQuestionnaire.self, from: JSONEncoder().encode(detail.sessionQuestionnaire))
                try store.saveSessionQuestionnaire(recordingID: recording.id, questionnaire: canonical, revision: detail.questionnaireRevision ?? 1)
                _ = try store.restoreRemoteRecording(detail)
                reloadRecentRecordings()
            } catch { showError("Server questionnaire restore failed", error: error) }
        }
    }

    func canEditQuestionnaire(_ recording: WoonaRecording) -> Bool {
        removingLocalRecordingID == nil && !isAccountOperationRunning && scheduledSyncCount == 0 && !syncingRecordingIDs.contains(recording.id) && recording.endedAtUTC != nil
    }

    func saveHeartQuestionnaire(_ heart: HeartQuestionnaire, recordingID: UUID) {
        do {
            guard let store, let recording = try store.recording(id: recordingID), var questionnaire = recording.questionnaire else { return }
            questionnaire.heartQuestionnaire = heart.normalized()
            saveSessionQuestionnaire(questionnaire, displayedRecording: recording)
        } catch { showError("Не удалось сохранить анкету по сердцебиению", error: error) }
    }

    func heartQuestionnaireDraft(recordingID: UUID) -> HeartQuestionnaire {
        let artifacts = (try? store?.artifacts(recordingID: recordingID)) ?? []
        let artifact = artifacts.first { $0.type == "ecg" }
            ?? artifacts.first { $0.type == "rr" && $0.referenceMetadata?.source.localizedCaseInsensitiveContains("polar") == true }
        var draft = HeartQuestionnaire()
        if let artifact {
            let method = artifact.type == "ecg" ? "ecg" : "polar_rr"
            draft.referenceMethod = HeartQuestionnaire.options["referenceMethod"]!.first { $0.key == method }
            draft.referenceArtifact = "\(artifact.fileName); \(artifact.referenceMetadata?.startedAtUtc ?? "") – \(artifact.referenceMetadata?.endedAtUtc ?? "")"
        }
        return draft
    }

    func attachReference(recordingID: UUID, type: String, url: URL, metadata: ReferenceMetadata) {
        guard removingLocalRecordingID == nil, let root = store?.rootDirectory,
              let recording = try? store?.recording(id: recordingID),
              let profile = try? store?.profile(dogID: recording.dogID, versionID: recording.profileVersionID),
              profile.accountID == selectedAccountID else { return }
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try WoonaStore(rootDirectory: root).attachReference(recordingID: recordingID, type: type, sourceURL: url, metadata: metadata)
                }.value
                reloadRecentRecordings()
                if let recording = try store?.recording(id: recordingID), recording.questionnaire?.readyForSync != false { await sync(recording: recording) }
            } catch { showError("Не удалось добавить контрольную запись", error: error) }
        }
    }

    func showAllRecordings() {
        showingAllRecordings = true
        reloadRecentRecordings()
    }

    private func reloadProfiles(selecting preferredID: UUID? = nil) {
        guard let store else { return }
        do {
            let previousDogID = selectedDogProfile?.id
            let previousAccountID = selectedDogProfile?.accountID
            let allProfiles = try store.profiles()
            let inventory = try store.localInventory()
            localProfileCount = inventory.profiles; localRecordingCount = inventory.recordings
            hiddenProfileCount = allProfiles.filter { $0.accountID != selectedAccountID }.count
            dogProfiles = allProfiles.filter { $0.accountID == selectedAccountID }
            unassignedDogProfiles = allProfiles.filter { $0.accountID == nil }
            let id = preferredID ?? selectedDogProfile?.id
            selectedDogProfile = id.flatMap { id in dogProfiles.first { $0.id == id } } ?? dogProfiles.first
            if previousDogID != selectedDogProfile?.id || previousAccountID != selectedDogProfile?.accountID { serverRecordings = [] }
            if let selectedDogProfile {
                UserDefaults.standard.set(selectedDogProfile.id.uuidString, forKey: "selectedDogID")
            }
            reloadRecentRecordings()
        } catch { errorMessage = "Failed to load profiles: \(error.localizedDescription)" }
    }

    private func reloadRecentRecordings() {
        if let overview = try? store?.syncOverview() {
            uploadPending = overview.pending; uploadRunning = overview.uploading; uploadSynced = overview.synced; uploadFailed = overview.failed; uploadLastError = overview.lastError
        }
        guard let store, let selectedDogProfile else {
            recentRecordings = []; downloadableRecordingIDs = []; exportableRecordingIDs = []; recordingSyncErrors = [:]; recordingFileCounts = [:]
            return
        }
        do {
            recentRecordings = try store.recentRecordings(dogID: selectedDogProfile.id, limit: showingAllRecordings ? nil : 10)
            downloadableRecordingIDs = []; exportableRecordingIDs = []; recordingSyncErrors = [:]; recordingFileCounts = [:]
            for recording in recentRecordings {
                let artifacts = try store.artifacts(recordingID: recording.id)
                recordingUploadProgress[recording.id] = (artifacts.reduce(0) { $0 + min(max(0, $1.uploadedBytes), $1.sizeBytes) }, artifacts.reduce(0) { $0 + $1.sizeBytes }, artifacts.filter { $0.uploadState == "available" }.count, artifacts.count)
                let local = artifacts.filter {
                    FileManager.default.fileExists(atPath: store.rootDirectory.appendingPathComponent($0.relativePath).path)
                }.count
                recordingFileCounts[recording.id] = (local, artifacts.count)
                if artifacts.contains(where: { $0.uploadState == "available" && !FileManager.default.fileExists(atPath: store.rootDirectory.appendingPathComponent($0.relativePath).path) }) {
                    downloadableRecordingIDs.insert(recording.id)
                }
                if local > 0 && !["preparing", "recording"].contains(recording.status) { exportableRecordingIDs.insert(recording.id) }
                recordingSyncErrors[recording.id] = try store.recordingSyncError(recordingID: recording.id)
            }
        }
        catch { showError("Failed to load recordings", error: error) }
    }

    private func serverClient() throws -> WoonaServerClient {
        try serverClient(accountID: selectedAccountID)
    }

    private func serverClient(accountID: String?) throws -> WoonaServerClient {
        try WoonaServerClient(
            configuration: ServerConfiguration(baseURL: serverBaseURL, wifiOnly: serverWifiOnly, accountID: accountID),
            token: serverToken
        )
    }

    private func uploadProfile(_ profile: DogProfile) async {
        guard !serverToken.isEmpty, let store else { return }
        uploadingProfileCount += 1
        defer { uploadingProfileCount -= 1 }
        do {
            let revision = try await serverClient(accountID: profile.accountID).upload(profile: profile, store: store)
            try store.setServerRevision(dogID: profile.id, revision: revision)
            reloadProfiles(selecting: profile.id)
        } catch { showError("Profile upload failed", error: error) }
    }

    private func reloadServerRecordings() async {
        guard !serverToken.isEmpty, let profile = selectedDogProfile else { serverRecordings = []; return }
        let accountID = selectedAccountID
        do {
            let client = try serverClient(accountID: accountID)
            var recordings = try await client.recordings(dogID: profile.id, limit: 10)
            guard selectedAccountID == accountID, selectedDogProfile?.id == profile.id else { return }
            serverRecordings = recordings
            // Older restores did not retain the top-level capture error fields.
            // Hydrate visible history as well as server-only rows from the existing detail API.
            for index in recordings.indices {
                let detail = try await client.recordingDetail(recordings[index].id)
                guard selectedAccountID == accountID, selectedDogProfile?.id == profile.id else { return }
                recordings[index].captureErrorCode = detail.captureErrorCode
                recordings[index].captureErrorMessage = detail.captureErrorMessage
                serverRecordings = recordings
            }
        }
        catch { appendDiagnostic("Server recordings unavailable: \(error.localizedDescription)") }
    }

    private func finalizeActiveRecording(_ recording: WoonaRecording, requestedStatus: String) async {
        guard activeRecording?.id == recording.id, let store else { captureStopInProgress = false; return }
        defer { captureStopInProgress = false }
        var packetFile: URL?
        var rawFile: URL?
        var logFile: URL?
        var timelineFile: URL?
        if hasPreparedActiveCapture {
            packetFile = await packetProcessor.currentPacketFile()
            rawFile = await packetProcessor.currentRawFile()
            logFile = await packetProcessor.currentLogFile()
            timelineFile = await packetProcessor.currentTimelineFile()
        }
        var files: [(type: String, source: URL, name: String, mime: String)] = []
        if let packetFile { files.append(("packet", packetFile, "packets.bin", "application/octet-stream")) }
        if let timelineFile { files.append(("packet_timeline", timelineFile, "packet_timeline.bin", "application/octet-stream")) }
        if let rawFile { files.append(("raw", rawFile, "raw_fragments.binlog", "application/octet-stream")) }
        if let logFile { files.append(("diagnostic", logFile, "diagnostics.log", "text/plain")) }
        let video = store.directory(for: recording).appendingPathComponent("video.mp4")
        if FileManager.default.fileExists(atPath: video.path) {
            files.append(("video", video, "video.mp4", "video/mp4"))
        }
        let acceptedTiming = await packetProcessor.acceptedPacketTiming()
        let sensorTime = acceptedTiming?.first
        let lastSensorTime = acceptedTiming?.last
        let info = cameraCaptureInfo
        let fallbackWallClockMs = Int64((ISO8601DateFormatter().date(from: recording.startedAtUTC)?.timeIntervalSince1970 ?? 0) * 1_000)
        var sync: [String: Any] = [
            "schemaVersion": 2,
            "monotonicClock": "ios.CMClock.hostTime",
            "sessionZeroAtUtc": captureSessionZeroAtUTC ?? recording.startedAtUTC,
            "sessionZeroWallClockMs": captureSessionZeroWallClockMs ?? fallbackWallClockMs,
            "sessionZeroMonotonicNs": captureSessionZeroMonotonicNs ?? 0,
            "sessionZeroUncertaintyNs": captureSessionZeroUncertaintyNs ?? 0,
            "cameraClockQuality": info?.clockQuality ?? "unavailable",
            "sensorClockQuality": sensorTime == nil ? "unavailable" : "first_packet_arrival",
            "overallSyncQuality": sensorTime != nil && info?.firstFrameMonotonicNs != nil ? (info?.clockQuality == "callback_estimate" ? "callback_estimate" : "arrival_aligned") : "unavailable",
            "calibrationOffsetNs": 0,
        ]
        if let sensorTime { sync["firstSensorPacketMonotonicNs"] = sensorTime }
        if let timer = acceptedTiming?.deviceTimer { sync["firstSensorDeviceTimerMs"] = timer }
        if let lastSensorTime { sync["lastSensorPacketMonotonicNs"] = lastSensorTime }
        if let info {
            sync["videoRequestedMonotonicNs"] = info.requestedMonotonicNs
            sync["mediaRecorderStartedMonotonicNs"] = info.writerStartedMonotonicNs
            sync["videoFirstFrameMonotonicNs"] = info.firstFrameMonotonicNs
            sync["videoFirstFrameCameraTimestampNs"] = info.firstFrameCameraTimestampNs
            sync["videoFirstFrameCallbackMonotonicNs"] = info.firstFrameCallbackMonotonicNs
            sync["videoFirstSamplePtsUs"] = info.firstVideoSamplePtsUs
            if let sensorTime, let frame = info.firstFrameMonotonicNs {
                sync["videoOffsetFromSensorNs"] = Int64(bitPattern: frame &- sensorTime)
            }
            sync["cameraTimestampSource"] = info.timestampSource
        }
        if requestedStatus == "completed", packetsReceived == 0, captureErrorCode == nil {
            captureErrorCode = "no_sensor_data"
            captureErrorMessage = "No valid sensor packets were received"
        }
        if let captureErrorCode { sync["captureErrorCode"] = captureErrorCode }
        if let captureErrorMessage { sync["captureErrorMessage"] = captureErrorMessage }
        do {
            let data = try JSONSerialization.data(withJSONObject: sync, options: [.sortedKeys, .withoutEscapingSlashes])
            let finalStatus = captureErrorCode == "storage_failed" || (requestedStatus == "completed" && packetsReceived == 0) ? "failed" : requestedStatus
            try store.finalize(recording: recording, status: finalStatus, files: files, syncJSON: data)
            activeRecording = nil
            hasPreparedActiveCapture = false
            isCaptureReady = false
            isRecording = false
            statusText = finalStatus.capitalized
            reloadRecentRecordings()
            if let finalized = try store.recording(id: recording.id) {
                await self.sync(recording: finalized)
            }
        } catch { showError("Failed to finalize recording", error: error) }
    }

    private func sync(recording: WoonaRecording) async {
        guard networkAvailable != false, !(serverWifiOnly && networkUnmetered == false), removingLocalRecordingID == nil, !isAccountOperationRunning, !serverToken.isEmpty, let store, recording.questionnaire?.readyForSync != false, !syncingRecordingIDs.contains(recording.id) else { return }
        syncingRecordingIDs.insert(recording.id)
        reloadRecentRecordings()
        defer { syncingRecordingIDs.remove(recording.id); reloadRecentRecordings() }
        do {
            guard let profile = try store.profile(dogID: recording.dogID, versionID: recording.profileVersionID) else {
                throw WoonaStoreError.invalidData("Recording profile version is missing")
            }
            try await serverClient(accountID: profile.accountID).upload(recording: recording, profile: profile, store: store, onProgress: { [weak self] in self?.reloadRecentRecordings() })
            reloadRecentRecordings()
            await reloadServerRecordings()
            if let latest = try store.recording(id: recording.id), latest.serverSyncState == "pending" {
                scheduleSync(latest)
            }
        } catch {
            reloadRecentRecordings()
            showError("Recording upload failed", error: error)
        }
        scheduleBackgroundSync()
    }

    private func registerBackgroundSync() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.backgroundSyncIdentifier, using: nil) { [weak self] task in
            guard let task = task as? BGProcessingTask else { return }
            let operation = Task { @MainActor [weak self] in
                await self?.resumePendingSync()
                task.setTaskCompleted(success: !Task.isCancelled)
            }
            task.expirationHandler = { operation.cancel() }
        }
    }

    private func makeBleSessionManager() -> BleSessionManager {
        hasInitializedBleSessionManager = true
        let submitter = packetFragmentSubmitter
        let processor = packetProcessor
        let ingressGate = packetIngressGate
        return BleSessionManager(
            onDeviceFound: { [weak self] device in
                self?.addFoundDevice(device)
            },
            onPacketReceived: { data in
                guard let timestamp = ingressGate.timestampIfActive() else { return }
                submitter.enqueue(data, receivedAtMonotonicNs: timestamp)
            },
            onDiagnosticMessage: { [weak self] message in
                self?.appendBleDiagnostic(message, packetProcessor: processor)
            },
            onCaptureReady: { [weak self] in
                guard let self else { return }
                self.isCaptureReady = true
                self.statusText = "Ready"
                self.appendBleDiagnostic("BLE capture ready", packetProcessor: processor)
                if self.activeRecording?.videoRequested == true {
                    Task {
                        do { try await self.cameraRecorder.prepare() }
                        catch {
                            self.handleCameraFailure(error.localizedDescription)
                        }
                    }
                }
            },
            onStateChanged: { [weak self] state in
                self?.applyBleState(state)
            },
            onError: { [weak self] message, error in
                if let self, self.activeRecording != nil, self.captureErrorCode == nil {
                    self.captureErrorCode = "gatt_error"
                    self.captureErrorMessage = [message, error?.localizedDescription].compactMap { $0 }.joined(separator: ": ")
                }
                self?.showError(message, error: error)
            }
        )
    }

    private func makeReplayController() -> PacketReplayController {
        let processor = packetProcessor
        return PacketReplayController(
            submitFragment: { bytes in
                await processor.submit(bytes)
            },
            onReplayStarted: { [weak self] in
                await self?.startReplaySession()
            },
            onReplayCompleted: { [weak self] in
                await self?.finishReplaySession()
            },
            onReplayStopped: { [weak self] in
                await self?.finishReplaySession()
            },
            onError: { [weak self] message, error in
                await self?.showError(message, error: error)
            }
        )
    }

    private func makePacketProcessor() -> PacketCaptureProcessor {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Woona", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Woona", isDirectory: true)
        let updateBatcher = packetUpdateBatcher

        return PacketCaptureProcessor(
            packetFileStore: PacketFileStore(directory: directory),
            rawFragmentFileStore: RawFragmentFileStore(directory: directory),
            packetTimelineFileStore: PacketTimelineFileStore(directory: directory),
            diagnosticLogFileStore: DiagnosticLogFileStore(directory: directory),
            onUpdate: { update in
                await updateBatcher.submit(update)
            },
            onError: { [weak self] message, error in
                await self?.handleStorageFailure(message, error: error)
            }
        )
    }

    private func makePacketUpdateBatcher() -> PacketProcessingUpdateBatcher {
        PacketProcessingUpdateBatcher { [weak self] update in
            self?.applyPacketUpdate(update)
        }
    }

    private func makePacketFragmentSubmitter() -> PacketFragmentSubmitter {
        let ingress = packetIngressGate
        return PacketFragmentSubmitter(
            packetProcessor: packetProcessor,
            maxPendingFragments: Self.maxPendingPacketFragments,
            onIngressStop: { ingress.stop() },
            onOverflow: { [weak self] in
                guard let self else { return }
                await MainActor.run {
                    self.handleCaptureQueueOverflow()
                }
            }
        )
    }

    private func applyBleState(_ state: BleSessionState) {
        guard !isReplayRunning else { return }
        switch state {
        case .idle:
            isScanning = false
            isConnected = false
            isConnectionActive = false
            statusText = "Idle"
        case .scanning:
            isScanning = true
            isConnected = false
            isConnectionActive = false
            statusText = "Scanning"
        case .connecting:
            isScanning = false
            isConnected = false
            isConnectionActive = true
            statusText = "Connecting"
        case .connected:
            isScanning = false
            isConnected = true
            isConnectionActive = true
            statusText = "Connected"
        case .disconnected:
            isScanning = false
            isConnected = false
            isConnectionActive = false
            statusText = "Disconnected"
            isCaptureReady = false
            if activeRecording != nil { stopActiveCapture(status: "interrupted") }
            else { finishCaptureProcessingIfNeeded() }
        case .failed:
            isScanning = false
            isConnected = false
            isConnectionActive = false
            statusText = "Error"
            isCaptureReady = false
            if activeRecording != nil { stopActiveCapture(status: "failed") }
            else { finishCaptureProcessingIfNeeded() }
        }
    }

    private func applyPacketUpdate(_ update: PacketProcessingUpdate) {
        appendChartSamples(update.chartSamplesByStream)
        packetsReceived = update.packetsReceived
        packetsLost = update.packetsLost
        packetsRejected = update.packetsRejected
        timerRegressionRejects = update.timerRegressionRejects
        fragmentsReceived = update.fragmentsReceived
        rawBytesReceived = update.rawBytesReceived
        lastPacketIssue = update.lastPacketIssue ?? lastPacketIssue
        rejectionBreakdown = update.rejectionBreakdown ?? rejectionBreakdown
        rebuildChartState()
        for event in update.diagnosticEvents {
            appendDiagnostic(event.message)
        }
    }

    private func prepareCaptureForConnection() async {
        await waitForCaptureFinishIfNeeded()
        packetUpdateBatcher.clearPending()
        await packetFragmentSubmitter.reset()
        await packetProcessor.resetSession()
        hasPreparedActiveCapture = true
        packetUpdateBatcher.clearPending()
        resetSessionUi(keepConnectionState: true)
        isCaptureDiagnosticsActive = true
    }

    private func finishCaptureProcessing() async {
        let (taskID, task) = ensureFinishCaptureProcessingTask()
        await task.value
        clearFinishedCaptureProcessingTask(id: taskID)
    }

    private func waitForCaptureFinishIfNeeded() async {
        while let task = finishCaptureProcessingTask {
            let taskID = finishCaptureProcessingTaskID
            await task.value
            clearFinishedCaptureProcessingTask(id: taskID)
        }
    }

    private func ensureFinishCaptureProcessingTask() -> (UInt64, Task<Void, Never>) {
        if let finishCaptureProcessingTask {
            return (finishCaptureProcessingTaskID, finishCaptureProcessingTask)
        }

        finishCaptureProcessingTaskID += 1
        let taskID = finishCaptureProcessingTaskID
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runCaptureFinish()
        }
        finishCaptureProcessingTask = task
        return (taskID, task)
    }

    private func clearFinishedCaptureProcessingTask(id taskID: UInt64) {
        guard finishCaptureProcessingTaskID == taskID else { return }
        finishCaptureProcessingTask = nil
    }

    private func runCaptureFinish() async {
        await packetFragmentSubmitter.finishCaptureProcessing()
        packetUpdateBatcher.flushNow()
        isCaptureDiagnosticsActive = false
    }

    private func finishCaptureProcessingIfNeeded() {
        guard isCaptureDiagnosticsActive else { return }
        isCaptureDiagnosticsActive = false
        let (taskID, task) = ensureFinishCaptureProcessingTask()
        Task { [weak self] in
            await task.value
            self?.clearFinishedCaptureProcessingTask(id: taskID)
        }
    }

    private func handleStorageFailure(_ message: String, error: Error?) {
        captureErrorCode = "storage_failed"
        captureErrorMessage = message
        packetIngressGate.stop()
        showError(message, error: error)
        if let recording = activeRecording {
            do { try store?.markRecording(recording.id, status: "failed") }
            catch { showError("Failed to persist recording failure", error: error) }
            stopActiveCapture(status: "failed")
        } else { finishCaptureProcessingIfNeeded() }
    }

    private func handleCaptureQueueOverflow() {
        captureErrorCode = "queue_overflow"
        captureErrorMessage = "Capture queue overflow; stopped capture to preserve packet ordering"
        showError("Capture queue overflow; stopped capture to preserve packet ordering", error: nil)
        if activeRecording != nil { stopActiveCapture(status: "failed") }
        else { bleSessionManager.disconnect(); finishCaptureProcessingIfNeeded() }
    }

    private func showError(_ message: String, error: Error?) {
        hasDogIdentityConflict = false
        if let syncError = error as? ServerSyncError, case .animalIDConflict = syncError {
            hasDogIdentityConflict = true
            errorMessage = selectedLanguage == .russian
                ? "Этот ID животного уже закреплён за другой карточкой. Проверьте аккаунт, восстановите анкеты и выберите существующую собаку. Локальные записи сохранены. Смена клички не освобождает ID. Если карточка не найдена, сохраните экспорт для сверки."
                : syncError.localizedDescription
            return
        }
        if let error {
            errorMessage = "\(message): \(error.localizedDescription)"
        } else {
            errorMessage = message
        }
        appendDiagnostic(errorMessage ?? message)
    }

    private func handleCameraFailure(_ message: String) {
        let isDuplicate = isCameraDegraded && captureErrorMessage == message
        isCameraDegraded = true
        if captureErrorCode != "storage_failed" {
            captureErrorCode = "camera_failed"
            captureErrorMessage = message
        }
        if isRecording { statusText = "Recording — camera degraded" }
        if !isDuplicate { appendDiagnostic("Camera degraded: \(message)") }
    }

    private func appendDiagnostic(_ message: String) {
        diagnosticMessages.insert(message, at: 0)
        if diagnosticMessages.count > 40 {
            diagnosticMessages.removeLast(diagnosticMessages.count - 40)
        }
    }

    private func appendBleDiagnostic(_ message: String, packetProcessor: PacketCaptureProcessor) {
        appendDiagnostic(message)
        guard isCaptureDiagnosticsActive else { return }

        Task {
            await packetProcessor.recordDiagnosticEvent(type: .info, message: "BLE: \(message)", publish: false)
        }
    }

    private func snapshotExportArtifacts(packetFile: URL?, rawFile: URL?, logFile: URL?) throws -> ExportArtifactSnapshot {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("WoonaExport-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        return ExportArtifactSnapshot(
            directory: directory,
            packetFile: try copyExportArtifact(packetFile, to: directory, fileManager: fileManager),
            rawFile: try copyExportArtifact(rawFile, to: directory, fileManager: fileManager),
            logFile: try copyExportArtifact(logFile, to: directory, fileManager: fileManager)
        )
    }

    private func copyExportArtifact(_ source: URL?, to directory: URL, fileManager: FileManager) throws -> URL? {
        guard let source, fileManager.fileExists(atPath: source.path) else { return nil }
        let target = directory.appendingPathComponent(source.lastPathComponent)
        try fileManager.copyItem(at: source, to: target)
        return target
    }

    private func discardPreparedExportSnapshot() {
        guard let preparedExportSnapshotDirectory else { return }
        try? FileManager.default.removeItem(at: preparedExportSnapshotDirectory)
        self.preparedExportSnapshotDirectory = nil
    }

    private func createCsvExport(packetFile: URL?, sessionStartMillis: Int64? = nil) async throws -> URL? {
        guard let packetFile else { return nil }
        exportPhase = .generatingCsv
        let csvURL = packetFile
            .deletingPathExtension()
            .appendingPathExtension("csv")
        let sessionStart = sessionStartMillis ?? exportSessionStartMillis(packetFile: packetFile)
        return try await Task.detached(priority: .userInitiated) {
            try CsvExporter().export(packetFile: packetFile, sessionStartMillis: sessionStart, targetFile: csvURL)
        }.value
    }

    private func exportSessionStartMillis(packetFile: URL) -> Int64 {
        if let currentSessionWallClockStartMillis {
            return currentSessionWallClockStartMillis
        }
        if
            let attributes = try? FileManager.default.attributesOfItem(atPath: packetFile.path),
            let creationDate = attributes[.creationDate] as? Date
        {
            return Int64(creationDate.timeIntervalSince1970 * 1_000)
        }
        return Self.currentWallClockMillis()
    }

    private func appendChartSamples(_ samplesByStream: [ChartStreamKey: [ChartPoint]]) {
        guard !samplesByStream.isEmpty else { return }

        for (streamKey, points) in samplesByStream where !points.isEmpty {
            chartHistory[streamKey, default: []].append(contentsOf: points)

            if let first = points.first?.timeMillis {
                sessionStartMillis = min(sessionStartMillis ?? first, first)
            }
            if let last = points.last?.timeMillis {
                latestChartTimeMillis = max(latestChartTimeMillis ?? last, last)
            }
        }

        trimChartHistory()
    }

    private func clearChartHistory() {
        chartHistory.removeAll(keepingCapacity: true)
        sessionStartMillis = nil
        latestChartTimeMillis = nil
        chartWindowPreset = .thirtySeconds
        isFollowingLive = true
        manualViewportEndMillis = nil
        chartVerticalZoomFactor = 1
        chartVerticalCenterOverride = nil
        chart = ChartUiState()
    }

    private func trimChartHistory() {
        guard let latestChartTimeMillis else { return }
        let cutoff = latestChartTimeMillis > Self.maxRetainedHistoryMillis
            ? latestChartTimeMillis - Self.maxRetainedHistoryMillis
            : 0

        for key in Array(chartHistory.keys) {
            guard let firstPoint = chartHistory[key]?.first, firstPoint.timeMillis < cutoff else { continue }
            guard let firstRetainedIndex = chartHistory[key]?.firstIndex(where: { $0.timeMillis >= cutoff }) else {
                chartHistory.removeValue(forKey: key)
                continue
            }
            if firstRetainedIndex > 0 {
                chartHistory[key]?.removeSubrange(0..<firstRetainedIndex)
            }
        }

        sessionStartMillis = chartHistory.values.compactMap(\.first?.timeMillis).min()
        self.latestChartTimeMillis = chartHistory.values.compactMap(\.last?.timeMillis).max()
        if !isFollowingLive {
            manualViewportEndMillis = manualViewportEndMillis.map { max($0, sessionStartMillis ?? $0) }
        }
    }

    private func rebuildChartState() {
        let sessionStart = sessionStartMillis
        let latest = latestChartTimeMillis
        let viewportEnd = latest.map { resolveViewportEnd(latest: $0) }
        let viewportDuration = viewportEnd.map(effectiveViewportDurationMillis) ?? chartWindowPreset.durationMillis
        let viewportStart: UInt64?
        if let viewportEnd {
            viewportStart = max(sessionStart ?? viewportEnd, viewportEnd > viewportDuration ? viewportEnd - viewportDuration : 0)
        } else {
            viewportStart = nil
        }

        let streamPoints = chartHistory[ChartStreamKey(sensorType: selectedSensorType, channel: selectedChannel)] ?? []
        let visiblePoints: [ChartPoint]
        if let viewportStart, let viewportEnd {
            visiblePoints = downsampleVisiblePoints(
                Array(slicePoints(streamPoints, startMillis: viewportStart, endMillis: viewportEnd)),
                maxPoints: Self.maxRenderedChartPoints
            )
        } else {
            visiblePoints = []
        }

        chart = ChartUiState(
            points: visiblePoints,
            windowPreset: chartWindowPreset,
            isFollowingLive: isFollowingLive,
            canPanLeft: viewportStart != nil && sessionStart != nil && viewportStart! > sessionStart!,
            canPanRight: !isFollowingLive && viewportEnd != nil && latest != nil && viewportEnd! < latest!,
            canZoomIn: chartVerticalZoomFactor < 64,
            canZoomOut: chartVerticalZoomFactor > 1,
            yAxisAbsRange: chartYAxisAbsRange(),
            yAxisCenter: chartYAxisCenter(points: visiblePoints),
            viewportStartMillis: viewportStart,
            viewportEndMillis: viewportEnd,
            sessionStartMillis: sessionStart,
            latestPointMillis: latest
        )
    }

    private func resolveViewportEnd(latest: UInt64) -> UInt64 {
        if isFollowingLive {
            return latest
        }
        return min(manualViewportEndMillis ?? latest, latest)
    }

    private func chartPanStepMillis(viewportEnd: UInt64) -> UInt64 {
        max(effectiveViewportDurationMillis(viewportEnd: viewportEnd) / 4, 1_000)
    }

    private func effectiveViewportDurationMillis(viewportEnd: UInt64) -> UInt64 {
        let sessionStart = sessionStartMillis ?? viewportEnd
        let availableDuration = viewportEnd > sessionStart ? viewportEnd - sessionStart : 0
        return min(chartWindowPreset.durationMillis, availableDuration)
    }

    private func chartYAxisAbsRange(zoomFactor: Float? = nil) -> Float {
        max(32_768 / (zoomFactor ?? chartVerticalZoomFactor), 256)
    }

    private func chartYAxisCenter(points: [ChartPoint]) -> Float {
        if let chartVerticalCenterOverride {
            return chartVerticalCenterOverride
        }
        guard !points.isEmpty else { return 0 }
        let values = points.map(\.value)
        return ((values.min() ?? 0) + (values.max() ?? 0)) / 2
    }

    private func slicePoints(_ points: [ChartPoint], startMillis: UInt64, endMillis: UInt64) -> ArraySlice<ChartPoint> {
        guard !points.isEmpty else { return [] }
        guard let firstIndex = points.firstIndex(where: { $0.timeMillis >= startMillis }) else { return [] }
        guard let lastIndex = points.lastIndex(where: { $0.timeMillis <= endMillis }), lastIndex >= firstIndex else { return [] }
        let startIndex = max(points.startIndex, firstIndex - 1)
        return points[startIndex...lastIndex]
    }

    private func downsampleVisiblePoints(_ points: [ChartPoint], maxPoints: Int) -> [ChartPoint] {
        guard points.count > maxPoints else { return points }
        let step = max(Int(ceil(Double(points.count) / Double(maxPoints))), 1)
        var result: [ChartPoint] = []
        var pendingSegmentBreak = false

        for (index, point) in points.enumerated() {
            pendingSegmentBreak = pendingSegmentBreak || point.startsNewSegment
            if index == 0 || index == points.count - 1 || index.isMultiple(of: step) {
                result.append(
                    ChartPoint(
                        timeMillis: point.timeMillis,
                        value: point.value,
                        startsNewSegment: result.isEmpty ? false : pendingSegmentBreak
                    )
                )
                pendingSegmentBreak = false
            }
        }
        return result
    }

    private func resetSessionUi(keepConnectionState: Bool = false) {
        currentSessionWallClockStartMillis = Self.currentWallClockMillis()
        clearChartHistory()
        resetCounters()
        errorMessage = nil
        preparedExport = nil
        exportPhase = nil
        discardPreparedExportSnapshot()
        isCaptureDiagnosticsActive = false
        if !keepConnectionState {
            isConnected = false
            isConnectionActive = false
        }
    }

    private func resetCounters() {
        packetsReceived = 0
        packetsLost = 0
        packetsRejected = 0
        timerRegressionRejects = 0
        fragmentsReceived = 0
        rawBytesReceived = 0
        lastPacketIssue = nil
        rejectionBreakdown = nil
        diagnosticMessages.removeAll(keepingCapacity: true)
    }

    private func setCaptureClockAnchor() {
        let before = HostClock.nowNanoseconds()
        let wallClockMs = Self.currentWallClockMillis()
        let after = HostClock.nowNanoseconds()
        captureSessionZeroAtUTC = WoonaStore.iso8601(Date(timeIntervalSince1970: Double(wallClockMs) / 1_000))
        captureSessionZeroWallClockMs = wallClockMs
        captureSessionZeroMonotonicNs = before + (after - before) / 2
        captureSessionZeroUncertaintyNs = (after - before) / 2
    }

    private func resetCaptureClockAnchor() {
        captureSessionZeroAtUTC = nil
        captureSessionZeroWallClockMs = nil
        captureSessionZeroMonotonicNs = nil
        captureSessionZeroUncertaintyNs = nil
    }

    private static let maxRenderedChartPoints = 1_200
    private static let maxRetainedHistoryMillis: UInt64 = 15 * 60_000
    private static let maxPendingPacketFragments = 512
    private static let backgroundSyncIdentifier = "com.woona.apps.sync"

    private static func currentWallClockMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }
}

final class PacketFragmentSubmitter: @unchecked Sendable {
    private let packetProcessor: PacketCaptureProcessor
    private let maxPendingFragments: Int
    private let onOverflow: @Sendable () async -> Void
    private let onIngressStop: @Sendable () -> Void
    private let lock = NSLock()

    private var pendingFragments: [QueuedPacketFragment] = []
    private var pendingHeadIndex = 0
    private var isDraining = false
    private var isFinishing = false
    private var generation: UInt64 = 0

    init(
        packetProcessor: PacketCaptureProcessor,
        maxPendingFragments: Int,
        onIngressStop: @escaping @Sendable () -> Void = {},
        onOverflow: @escaping @Sendable () async -> Void
    ) {
        self.packetProcessor = packetProcessor
        self.maxPendingFragments = max(0, maxPendingFragments)
        self.onOverflow = onOverflow
        self.onIngressStop = onIngressStop
    }

    func enqueue(_ data: Data, receivedAtMonotonicNs: UInt64? = nil) {
        enqueue([UInt8](data), receivedAtMonotonicNs: receivedAtMonotonicNs)
    }

    func enqueue(_ bytes: [UInt8], receivedAtMonotonicNs: UInt64? = nil) {
        guard !bytes.isEmpty else { return }

        let action = lock.withLock {
            guard !isFinishing else { return EnqueueAction.none }
            guard pendingQueueDepthLocked() < maxPendingFragments else {
                pendingFragments.append(QueuedPacketFragment(generation: generation,bytes: bytes,receivedAtMonotonicNs: receivedAtMonotonicNs))
                isFinishing = true
                let startDrain = !isDraining
                isDraining = true
                return EnqueueAction.overflow(startDrain)
            }
            pendingFragments.append(
                QueuedPacketFragment(
                    generation: generation,
                    bytes: bytes,
                    receivedAtMonotonicNs: receivedAtMonotonicNs
                )
            )
            guard !isDraining else { return EnqueueAction.none }
            isDraining = true
            return EnqueueAction.startDrain
        }

        switch action {
        case .none:
            break
        case .startDrain:
            Task(priority: .userInitiated) {
                await drain()
            }
        case .overflow(let startDrain):
            onIngressStop()
            if startDrain { Task(priority: .userInitiated) { await drain() } }
            Task(priority: .userInitiated) {
                await onOverflow()
            }
        }
    }

    func reset() async {
        lock.withLock {
            generation += 1
            pendingFragments.removeAll(keepingCapacity: true)
            pendingHeadIndex = 0
            isFinishing = false
        }
        await waitForDrain()
    }

    func finishCaptureProcessing() async {
        lock.withLock {
            isFinishing = true
        }
        await waitForDrain()
        await packetProcessor.finishCaptureSession()
        lock.withLock {
            generation += 1
            pendingFragments.removeAll(keepingCapacity: true)
            pendingHeadIndex = 0
            isFinishing = false
        }
    }

    private func drain() async {
        while true {
            guard let fragment = nextFragment() else {
                let shouldContinue = lock.withLock {
                    if pendingHeadIndex < pendingFragments.count {
                        return true
                    }
                    isDraining = false
                    compactPendingFragmentsLocked(force: true)
                    return false
                }
                if shouldContinue {
                    continue
                }
                return
            }

            let submitResult = await packetProcessor.submit(
                fragment.bytes,
                receivedAtMonotonicNs: fragment.receivedAtMonotonicNs
            )
            if submitResult == .overflow {
                lock.withLock { isFinishing = true }
                onIngressStop()
                await onOverflow()
            }
        }
    }

    private func nextFragment() -> QueuedPacketFragment? {
        lock.withLock {
            while pendingHeadIndex < pendingFragments.count {
                let fragment = pendingFragments[pendingHeadIndex]
                pendingHeadIndex += 1
                compactPendingFragmentsLocked(force: false)
                if fragment.generation == generation {
                    return fragment
                }
            }
            return nil
        }
    }

    private func waitForDrain() async {
        while lock.withLock({ isDraining }) {
            await Task.yield()
        }
    }

    private func pendingQueueDepthLocked() -> Int {
        max(pendingFragments.count - pendingHeadIndex, 0)
    }

    private func compactPendingFragmentsLocked(force: Bool) {
        guard pendingHeadIndex > 0 else { return }
        guard force || pendingHeadIndex >= 128 else { return }
        pendingFragments.removeSubrange(0..<pendingHeadIndex)
        pendingHeadIndex = 0
    }

    private struct QueuedPacketFragment {
        let generation: UInt64
        let bytes: [UInt8]
        let receivedAtMonotonicNs: UInt64?
    }

    private enum EnqueueAction {
        case none
        case startDrain
        case overflow(Bool)
    }
}

private final class PacketIngressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false

    func start() {
        lock.withLock {
            active = true
        }
    }

    func stop() { lock.withLock { active = false } }

    func timestampIfActive() -> UInt64? {
        lock.withLock {
            guard active else { return nil }
            let timestamp = HostClock.nowNanoseconds()
            return timestamp
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

enum ChartWindowPreset: String, CaseIterable, Equatable, Sendable {
    case thirtySeconds = "30s"
    case sixtySeconds = "60s"
    case fiveMinutes = "5m"
    case fifteenMinutes = "15m"

    var durationMillis: UInt64 {
        switch self {
        case .thirtySeconds:
            30_000
        case .sixtySeconds:
            60_000
        case .fiveMinutes:
            300_000
        case .fifteenMinutes:
            900_000
        }
    }
}

struct ChartUiState: Equatable {
    let points: [ChartPoint]
    let windowPreset: ChartWindowPreset
    let isFollowingLive: Bool
    let canPanLeft: Bool
    let canPanRight: Bool
    let canZoomIn: Bool
    let canZoomOut: Bool
    let yAxisAbsRange: Float
    let yAxisCenter: Float
    let viewportStartMillis: UInt64?
    let viewportEndMillis: UInt64?
    let sessionStartMillis: UInt64?
    let latestPointMillis: UInt64?

    init(
        points: [ChartPoint] = [],
        windowPreset: ChartWindowPreset = .thirtySeconds,
        isFollowingLive: Bool = true,
        canPanLeft: Bool = false,
        canPanRight: Bool = false,
        canZoomIn: Bool = true,
        canZoomOut: Bool = false,
        yAxisAbsRange: Float = 32_768,
        yAxisCenter: Float = 0,
        viewportStartMillis: UInt64? = nil,
        viewportEndMillis: UInt64? = nil,
        sessionStartMillis: UInt64? = nil,
        latestPointMillis: UInt64? = nil
    ) {
        self.points = points
        self.windowPreset = windowPreset
        self.isFollowingLive = isFollowingLive
        self.canPanLeft = canPanLeft
        self.canPanRight = canPanRight
        self.canZoomIn = canZoomIn
        self.canZoomOut = canZoomOut
        self.yAxisAbsRange = yAxisAbsRange
        self.yAxisCenter = yAxisCenter
        self.viewportStartMillis = viewportStartMillis
        self.viewportEndMillis = viewportEndMillis
        self.sessionStartMillis = sessionStartMillis
        self.latestPointMillis = latestPointMillis
    }
}

enum AppThemeMode: String, CaseIterable, Equatable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
}

enum AppLanguage: String, CaseIterable, Equatable {
    case english = "English"
    case russian = "Russian"
}

enum AppTextKey {
    case overview
    case charts
    case settings
    case session
    case status
    case replay
    case packets
    case lost
    case rejected
    case fragments
    case rawBytes
    case timerRegressions
    case lastIssue
    case rejects
    case none
    case captureControls
    case scan
    case stopScan
    case uploadBinary
    case stopReplay
    case disconnect
    case devices
    case noDevices
    case export
    case diagnostics
    case noDiagnosticEvents
    case sensor
    case channel
    case window
    case follow
    case yReset
    case noChartData
    case waitingForData
    case live
    case history
    case bleTransport
    case profile
    case transportAdvisory
    case appearance
    case theme
    case language

    func localized(language: AppLanguage) -> String {
        switch language {
        case .english:
            english
        case .russian:
            russian
        }
    }

    private var english: String {
        switch self {
        case .overview: "Overview"
        case .charts: "Charts"
        case .settings: "Settings"
        case .session: "Session"
        case .status: "Status"
        case .replay: "Replay"
        case .packets: "Packets"
        case .lost: "Lost"
        case .rejected: "Rejected"
        case .fragments: "Fragments"
        case .rawBytes: "Raw bytes"
        case .timerRegressions: "Timer regressions"
        case .lastIssue: "Last issue"
        case .rejects: "Rejects"
        case .none: "None"
        case .captureControls: "Capture Controls"
        case .scan: "Scan"
        case .stopScan: "Stop Scan"
        case .uploadBinary: "Upload Binary"
        case .stopReplay: "Stop Replay"
        case .disconnect: "Disconnect"
        case .devices: "Devices"
        case .noDevices: "No devices found"
        case .export: "Export"
        case .diagnostics: "Diagnostics"
        case .noDiagnosticEvents: "No diagnostic events"
        case .sensor: "Sensor"
        case .channel: "Channel"
        case .window: "Window"
        case .follow: "Follow"
        case .yReset: "Y Reset"
        case .noChartData: "No Chart Data"
        case .waitingForData: "Waiting for data"
        case .live: "Live"
        case .history: "History"
        case .bleTransport: "BLE Transport"
        case .profile: "Profile"
        case .transportAdvisory: "iOS manages connection priority, MTU, and PHY automatically. Device-side connection parameters control sustained reliability."
        case .appearance: "Appearance"
        case .theme: "Theme"
        case .language: "Language"
        }
    }

    private var russian: String {
        switch self {
        case .overview: "Обзор"
        case .charts: "Графики"
        case .settings: "Настройки"
        case .session: "Сессия"
        case .status: "Статус"
        case .replay: "Повтор"
        case .packets: "Пакеты"
        case .lost: "Потеряно"
        case .rejected: "Отклонено"
        case .fragments: "Фрагменты"
        case .rawBytes: "Сырые байты"
        case .timerRegressions: "Регрессии таймера"
        case .lastIssue: "Последняя проблема"
        case .rejects: "Отклонения"
        case .none: "Нет"
        case .captureControls: "Управление захватом"
        case .scan: "Сканировать"
        case .stopScan: "Стоп скан"
        case .uploadBinary: "Загрузить бинарник"
        case .stopReplay: "Остановить повтор"
        case .disconnect: "Отключиться"
        case .devices: "Устройства"
        case .noDevices: "Устройства не найдены"
        case .export: "Экспорт"
        case .diagnostics: "Диагностика"
        case .noDiagnosticEvents: "Нет событий диагностики"
        case .sensor: "Сенсор"
        case .channel: "Канал"
        case .window: "Окно"
        case .follow: "Следить"
        case .yReset: "Сброс Y"
        case .noChartData: "Нет данных графика"
        case .waitingForData: "Ожидание данных"
        case .live: "Вживую"
        case .history: "История"
        case .bleTransport: "BLE транспорт"
        case .profile: "Профиль"
        case .transportAdvisory: "iOS управляет приоритетом соединения, MTU и PHY автоматически. Надежность длительной передачи задается параметрами устройства."
        case .appearance: "Внешний вид"
        case .theme: "Тема"
        case .language: "Язык"
        }
    }
}

enum ExportPhase: String, Equatable {
    case preparingSnapshots = "Preparing files"
    case generatingCsv = "Generating CSV"
    case openingShareSheet = "Opening share sheet"
}

enum ExportKind: String, CaseIterable, Identifiable, Equatable {
    case all
    case packetDump
    case channelCsv
    case rawFragments
    case diagnosticLog

    var id: String { rawValue }

    var title: String {
        localizedTitle(language: .english)
    }

    func localizedTitle(language: AppLanguage) -> String {
        switch language {
        case .english:
            englishTitle
        case .russian:
            russianTitle
        }
    }

    private var englishTitle: String {
        switch self {
        case .all:
            "Session ZIP (all files)"
        case .packetDump:
            "Packet dump"
        case .channelCsv:
            "Channel CSV"
        case .rawFragments:
            "Raw fragments"
        case .diagnosticLog:
            "Diagnostic log"
        }
    }

    private var russianTitle: String {
        switch self {
        case .all:
            "ZIP сессии (все файлы)"
        case .packetDump:
            "Дамп пакетов"
        case .channelCsv:
            "CSV канала"
        case .rawFragments:
            "Сырые фрагменты"
        case .diagnosticLog:
            "Диагностический лог"
        }
    }
}

struct PreparedExport: Identifiable, Equatable {
    let id = UUID()
    let kind: ExportKind
    let urls: [URL]
}

private struct ExportArtifactSnapshot {
    let directory: URL
    let packetFile: URL?
    let rawFile: URL?
    let logFile: URL?
}
