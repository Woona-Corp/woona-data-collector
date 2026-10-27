import BackgroundTasks
import Foundation
import Network
import UIKit

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
    @Published private(set) var availableSessionExportKinds: Set<ExportKind> = []
    @Published private(set) var sessionExportAvailabilityRevision: UInt64 = 0
    private var exportAvailabilityReadGeneration: UInt64 = 0
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
    @Published private(set) var isLocalRecoveryRunning = false
    @Published private(set) var localRecoveryError: String?
    @Published private(set) var retirementCleanupStatus = RetirementCleanupStatus(pendingCount: 0, lastError: nil)
    @Published private(set) var retirementCheckState = "not_checked"
    @Published private(set) var retirementCheckError: String?
    @Published private(set) var retirementCheckedAt: String?
    private var retirementCheckGeneration: UUID?
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
    @Published private(set) var profileUploadPending = 0
    @Published private(set) var profileUploadFailed = 0
    @Published private(set) var profileUploadLastError: String?
    private var syncingProfileVersionIDs: Set<UUID> = []
    @Published private(set) var networkAvailable: Bool?
    @Published private(set) var networkUnmetered: Bool?
    @Published private(set) var connectionCheck = "not_checked"
    @Published private(set) var connectionCheckedAt: String?
    @Published private(set) var connectionCheckError: String?
    @Published private(set) var serverTransferStatuses: [UUID: ServerTransferStatus] = [:]
    @Published private(set) var transferStatusErrors: [UUID: String] = [:]
    @Published private(set) var transferCheckedAt: [UUID: String] = [:]
    @Published private(set) var checkingTransferIDs: Set<UUID> = []
    private var networkMonitor: NWPathMonitor?
    private let backgroundSchedulingEnabled: Bool
    @Published private(set) var backgroundSyncStatus = "not_requested"
    @Published private(set) var isBackgroundSyncRunning = false
    @Published private(set) var backgroundSyncError: String?

    var backgroundSyncExplanation: String {
        let ru = selectedLanguage == .russian
        switch backgroundSyncStatus {
        case "scheduled": return ru ? "iOS приняла запрос фоновой выгрузки. Время запуска определяет система; запуск пока не подтверждён." : "iOS accepted the background upload request. The system chooses when it runs; execution is not yet confirmed."
        case "running": return ru ? "Выполняется фоновая выгрузка; завершение ещё не подтверждено." : "Background upload is running; completion is not yet confirmed."
        case "completed": return ru ? "Последний фоновый запуск завершил обработку своей очереди." : "The last background run finished processing its queue."
        case "incomplete": return ru ? "Фоновый запуск прерван или очередь не завершена. Сохранённые данные доступны; откройте приложение для продолжения." : "The background run was interrupted or its queue is incomplete. Saved data remains available; open the app to continue."
        case "failed": return ru ? "Фоновый запуск недоступен. Очередь сохранена; оставьте приложение открытым для отправки. Подробности ниже." : "Background scheduling is unavailable. The queue is saved; keep the app open to upload. Details follow."
        case "disabled": return ru ? "Фоновый планировщик отключён в тестовом запуске." : "Background scheduling is disabled for this test run."
        default: return ru ? "Фоновый запуск пока не запрошен. Отправка при открытом приложении работает отдельно; iOS определяет возможность и время фоновой работы." : "No background run has been requested. Foreground uploads operate separately; iOS decides background availability and timing."
        }
    }

    var uploadQueueExplanation: String {
        let ru = selectedLanguage == .russian
        if serverToken.isEmpty { return ru ? "Сервер не подключён. Данные сохраняются на телефоне; настройте адрес и токен." : "Server is not configured. Data stays on this phone; configure the address and token." }
        if isAccountOperationRunning { return ru ? "Выполняется операция с аккаунтом или восстановление. Существующие локальные файлы сохраняются." : "An account or restore operation is running. Existing local files are preserved." }
        if networkAvailable == false { return ru ? "Нет интернета. Очередь сохранена; отправка продолжится после подключения." : "No internet. The queue is saved and will resume when connected." }
        if serverWifiOnly && networkUnmetered == false { return ru ? "Отправка ждёт Wi-Fi или сети без тарификации. Подключите её либо отключите ограничение." : "Uploads are waiting for Wi-Fi or an unmetered network. Connect or disable the restriction." }
        if uploadFailed > 0 || profileUploadFailed > 0 { return ru ? "Есть ошибки доставки. Откройте причину в Настройках или карточке сессии; повторите отправку после устранения причины." : "Some transfers failed. Check its cause in Settings or the session details; retry after correcting it." }
        if !syncingRecordingIDs.isEmpty || uploadingProfileCount > 0 { return ru ? "Обрабатываем очередь: подготовка, передача и проверка целостности. Переданные байты ещё не подтверждают копию." : "Processing the queue: preparation, transfer and integrity checks. Transferred bytes alone do not confirm a verified copy." }
        if uploadRunning > 0 { return ru ? "Сохранены незавершённые передачи. Фоновая задача сейчас не выполняется; проверьте ограничения сети. Данные не считаются загруженными." : "Unfinished transfers are saved. No background job is currently running; check network restrictions. Data is not marked uploaded." }
        if uploadPending > 0 || profileUploadPending > 0 { return ru ? "Анкеты и сессии ожидают запуска или повтора. Нажмите «Повторить выгрузку». Незавершённая анкета сессии должна быть заполнена." : "Profiles and sessions are waiting to start or retry. Use Retry uploads. Complete any unfinished session questionnaire." }
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
        let configuration = ServerConfiguration(baseURL: serverBaseURL, wifiOnly: serverWifiOnly, accountID: selectedAccountID)
        let token = serverToken
        checkingTransferIDs.insert(id)
        serverTransferStatuses[id] = nil; transferStatusErrors[id] = nil; transferCheckedAt[id] = nil
        Task {
            defer { checkingTransferIDs.remove(id) }
            do {
                let status = try await WoonaServerClient(configuration: configuration, token: token).syncStatus(id)
                guard configuration == ServerConfiguration(baseURL: serverBaseURL, wifiOnly: serverWifiOnly, accountID: selectedAccountID), token == serverToken else { return }
                serverTransferStatuses[id] = status
                transferCheckedAt[id] = WoonaStore.iso8601(Date())
            } catch {
                guard configuration == ServerConfiguration(baseURL: serverBaseURL, wifiOnly: serverWifiOnly, accountID: selectedAccountID), token == serverToken else { return }
                serverTransferStatuses[id] = nil
                transferStatusErrors[id] = recordingUploadErrorText(error.localizedDescription, language: selectedLanguage) + "\n" + error.localizedDescription
            }
        }
    }

    @Published private(set) var isV2PreviewActive = false
    @Published var bleConnectionPurpose = BleConnectionPurpose.record
    let v2Preview = V2PreviewController()
    private var hasOpenBLETransport: Bool { hasInitializedBleSessionManager && bleSessionManager.currentPeripheralIdentifier() != nil }
    var canOpenBLEPicker: Bool { !hasOpenBLETransport && !isLocalRecoveryRunning && localRecoveryError == nil && activeRecording == nil && !captureStopInProgress && !isConnectionActive && !isV2PreviewActive && !isReplayRunning && !isAccountOperationRunning }

    var canStartNewSession: Bool { !hasOpenBLETransport && !isV2PreviewActive && !isLocalRecoveryRunning && localRecoveryError == nil && activeRecording == nil && !captureStopInProgress }
    var canSelectAnimal: Bool { !isV2PreviewActive && !isLocalRecoveryRunning && localRecoveryError == nil && !isBackgroundSyncRunning && activeRecording == nil && !isRecording && !isAccountOperationRunning && completeArchiveTask == nil }
    var transferNetworkAllowsWork: Bool {
        !isLocalRecoveryRunning && localRecoveryError == nil && networkAvailable == true && (!serverWifiOnly || networkUnmetered == true) && !isCompleteArchiveExporting
    }

    // BG launch can precede the first NWPathMonitor callback. Waiting is bounded,
    // cancellable and never turns an unknown path into an invented connection.
    func awaitFirstTransferNetwork(timeout: TimeInterval = 24) async -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while networkAvailable == nil || (serverWifiOnly && networkUnmetered == nil) {
            guard !Task.isCancelled, Date() < deadline else { return false }
            do { try await Task.sleep(nanoseconds: 50_000_000) }
            catch { return false }
        }
        return !Task.isCancelled && transferNetworkAllowsWork
    }

    func updateTransferNetworkPath(available: Bool, unmetered: Bool) {
        let wasAllowed = transferNetworkAllowsWork
        networkAvailable = available
        networkUnmetered = unmetered
        if !wasAllowed && transferNetworkAllowsWork && !isBackgroundSyncRunning { schedulePendingSync() }
    }

    private var hasExclusiveLocalDataAccess: Bool {
        !isLocalRecoveryRunning && !isBackgroundSyncRunning && completeArchiveTask == nil && !isAccountOperationRunning && !isConnectionActive && !isReplayRunning && !isRecording &&
        !captureStopInProgress && activeRecording == nil && syncingRecordingIDs.isEmpty &&
        uploadingProfileCount == 0 && scheduledSyncCount == 0 && downloadingRecordingID == nil && removingLocalRecordingID == nil
    }
    var canChangeAccount: Bool { hasExclusiveLocalDataAccess && localRecoveryError == nil }
    var canExportCompleteArchive: Bool { hasExclusiveLocalDataAccess }

    // Disconnect can cancel a waiting upload. Requiring the entire queue to be
    // idle here would prevent removing credentials when connectivity is lost.
    var canDisconnectServer: Bool {
        !isLocalRecoveryRunning && !serverToken.isEmpty && completeArchiveTask == nil && exportPhase == nil &&
        !isAccountOperationRunning && activeRecording == nil && !captureStopInProgress && !isRecording
    }

    var canChangeNetworkPolicy: Bool {
        !isLocalRecoveryRunning && localRecoveryError == nil && !isBackgroundSyncRunning && completeArchiveTask == nil && !isAccountOperationRunning && !isRecording && activeRecording == nil &&
        !captureStopInProgress && !isReplayRunning && syncingRecordingIDs.isEmpty && uploadingProfileCount == 0 &&
        downloadingRecordingID == nil && removingLocalRecordingID == nil
    }

    @discardableResult
    func updateNetworkPolicy(wifiOnly: Bool) -> Bool {
        guard canChangeNetworkPolicy else {
            errorMessage = selectedLanguage == .russian ? "Дождитесь завершения текущей записи, передачи или операции с данными перед изменением ограничения сети." : "Wait for the current recording, transfer or data operation before changing the network restriction."
            return false
        }
        serverWifiOnly = wifiOnly
        UserDefaults.standard.set(wifiOnly, forKey: "serverWifiOnly")
        if networkAvailable == true && (!serverWifiOnly || networkUnmetered == true) && !isCompleteArchiveExporting { schedulePendingSync() }
        return true
    }

    var serverMutationBlockedReason: String? {
        guard !canChangeAccount else { return nil }
        let ru = selectedLanguage == .russian
        if isLocalRecoveryRunning { return ru ? "Восстанавливаем прерванную локальную работу. Исходные файлы сохраняются." : "Recovering interrupted local work. Original files are preserved." }
        if localRecoveryError != nil { return ru ? "Локальное восстановление не завершено. Повторите его или экспортируйте все данные для проверки." : "Local recovery is incomplete. Retry it or export all data for review." }
        if completeArchiveTask != nil { return ru ? "Дождитесь завершения экспорта архива или отмените его." : "Wait for the archive export to finish or cancel it." }
        if isRecording || activeRecording != nil || captureStopInProgress { return ru ? "Завершите текущую сессию и сохранение файлов перед изменением сервера." : "Finish the current session and file finalization before changing server data." }
        if isConnectionActive || isReplayRunning { return ru ? "Отключите устройство или завершите воспроизведение перед изменением сервера." : "Disconnect the device or finish replay before changing server data." }
        return ru ? "Дождитесь завершения текущей выгрузки, восстановления или операции с аккаунтом." : "Wait for the current upload, restore or account operation to finish."
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
    #if DEBUG
    private var didInjectProfileSaveFailure = false
    #endif
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
    private var captureStopTask: Task<Void, Never>?
    private lazy var captureFinalizationBackgroundTime = CaptureFinalizationBackgroundTime(enabled: backgroundSchedulingEnabled)
    private var hasPreparedActiveCapture = false
    @Published private var syncingRecordingIDs = Set<UUID>()

    private let questionnaireClientFactory: ((String?) throws -> WoonaServerClient)?
    private let syncClientFactory: ((String?) throws -> WoonaServerClient)?
    private let serverTokenWriter: ((String) throws -> Void)?

    init(store: WoonaStore? = try? WoonaStore(), uiTesting: Bool = false,
         questionnaireClientFactory: ((String?) throws -> WoonaServerClient)? = nil,
         syncClientFactory: ((String?) throws -> WoonaServerClient)? = nil,
         serverTokenWriter: ((String) throws -> Void)? = nil) {
        self.questionnaireClientFactory = questionnaireClientFactory
        self.syncClientFactory = syncClientFactory
        self.serverTokenWriter = serverTokenWriter
        self.backgroundSchedulingEnabled = !uiTesting &&
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil && NSClassFromString("XCTestCase") == nil
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
        if uiTesting, let store {
            do {
                let recovered = try store.recoverInterruptedUploads(excluding: WoonaServerClient.liveRecordingUploadIDs(root: store.rootDirectory))
                if recovered > 0 { appendDiagnostic("Recovered \(recovered) interrupted upload states; local files and confirmed progress are preserved") }
            } catch { errorMessage = "Unable to recover interrupted upload queue: \(error.localizedDescription)" }
        }
        reloadProfiles(selecting: defaults.string(forKey: "selectedDogID").flatMap(UUID.init(uuidString:)))
        if uiTesting, let profile = dogProfiles.first(where: { $0.numberOrName == "UI Dog 1" }) { selectDogProfile(profile) }
        if store == nil { errorMessage = "Unable to open local Woona database" }
        if !uiTesting {
            recoverLocalData()
            let monitor = NWPathMonitor()
            networkMonitor = monitor
            monitor.pathUpdateHandler = { [weak self] path in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.updateTransferNetworkPath(available: path.status == .satisfied, unmetered: !path.isExpensive)
                }
            }
            monitor.start(queue: DispatchQueue(label: "woona.network-status"))
        }
    }

    func recoverLocalData() {
        guard hasExclusiveLocalDataAccess, let store else { return }
        isLocalRecoveryRunning = true; localRecoveryError = nil
        let root = store.rootDirectory
        let activeUploads = WoonaServerClient.liveRecordingUploadIDs(root: root)
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let backgroundStore = try WoonaStore(rootDirectory: root)
                    let captures = try backgroundStore.recoverUnfinishedCaptures()
                    _ = try backgroundStore.recoverInterruptedUploads(excluding: activeUploads)
                    _ = try backgroundStore.applyDeferredServerDeletions()
                    let cleanup = try backgroundStore.drainLocalDeletionOutbox()
                    return (captures, cleanup)
                }.value
                retirementCleanupStatus = result.1
                if result.0 > 0 { appendDiagnostic("Recovered \(result.0) interrupted captures. Source files are preserved; unknown timing and legacy working files require review before upload.") }
                isLocalRecoveryRunning = false
                reloadProfiles(selecting: selectedDogProfile?.id)
                schedulePendingSync()
            } catch {
                isLocalRecoveryRunning = false
                localRecoveryError = error.localizedDescription
                showError(selectedLanguage == .russian ? "Локальное восстановление не завершено; исходные файлы сохранены" : "Local recovery is incomplete; original files are preserved", error: error)
            }
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

    func saveDogProfile(_ questionnaire: DogQuestionnaire, replacing profile: DogProfile? = nil) throws {
        guard canSelectAnimal else { throw WoonaStoreError.invalidData("Finish the active recording, archive or account operation before saving a profile") }
        guard let store else { throw WoonaStoreError.invalidData("The local Woona database is unavailable") }
        guard profile == nil || profile?.accountID == selectedAccountID else {
            throw WoonaStoreError.invalidData("The profile belongs to another account; select its account before editing")
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
           ProcessInfo.processInfo.arguments.contains("--ui-testing-fail-profile-save"), !didInjectProfileSaveFailure {
            didInjectProfileSaveFailure = true
            throw WoonaStoreError.invalidData("Injected local database write failure")
        }
        #endif
        let saved = try store.saveProfile(questionnaire, replacing: profile, accountID: selectedAccountID)
        reloadProfiles(selecting: saved.id)
        uploadingProfileCount += 1
        Task {
            defer { uploadingProfileCount -= 1 }
            await uploadProfile(saved)
        }
    }

    func selectDogProfile(_ profile: DogProfile) {
        guard canSelectAnimal, profile.accountID == selectedAccountID else { return }
        serverRecordings = []
        selectedDogProfile = profile
        showingAllRecordings = false
        UserDefaults.standard.set(profile.id.uuidString, forKey: "selectedDogID")
        reloadRecentRecordings()
        Task { await reloadServerRecordings() }
    }

    @discardableResult
    func saveServerSettings() -> Bool {
        guard canChangeAccount else { errorMessage = serverMutationBlockedReason; return false }
        connectionCheck = "not_checked"; connectionCheckedAt = nil; connectionCheckError = nil
        serverTransferStatuses = [:]; transferStatusErrors = [:]; transferCheckedAt = [:]
        serverBaseURL = serverBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        serverToken = serverToken.trimmingCharacters(in: .whitespacesAndNewlines)
        do { try persistServerToken(serverToken) }
        catch { showError("Failed to store server token", error: error); return false }
        UserDefaults.standard.set(serverBaseURL, forKey: "serverBaseURL")
        UserDefaults.standard.set(serverWifiOnly, forKey: "serverWifiOnly")
        if networkAvailable == true && (!serverWifiOnly || networkUnmetered == true) && !isCompleteArchiveExporting { schedulePendingSync() }
        return true
    }

    private func persistServerToken(_ value: String) throws {
        if let serverTokenWriter { try serverTokenWriter(value) }
        else { try keychainTokenStore.save(value) }
    }

    @discardableResult
    func disconnectServer() -> Bool {
        guard canDisconnectServer else {
            errorMessage = selectedLanguage == .russian
                ? "Завершите запись, экспорт или операцию с аккаунтом перед отключением сервера."
                : "Finish capture, export or the account operation before disconnecting the server."
            return false
        }
        do { try persistServerToken("") }
        catch { showError("Server token could not be removed; connection settings are unchanged", error: error); return false }
        serverToken = ""
        WoonaServerClient.cancelAllTransfers()
        retirementCheckGeneration = nil
        retirementCheckState = "not_checked"; retirementCheckError = nil; retirementCheckedAt = nil
        if backgroundSchedulingEnabled { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundSyncIdentifier) }
        connectionCheck = "not_checked"; connectionCheckedAt = nil; connectionCheckError = nil
        serverTransferStatuses = [:]; transferStatusErrors = [:]; transferCheckedAt = [:]
        backgroundSyncStatus = "not_requested"; backgroundSyncError = nil
        appendDiagnostic(selectedLanguage == .russian
            ? "Сервер отключён на этом устройстве. Токен удалён; файлы, анкеты и очередь сохранены."
            : "Server disconnected on this device. Token removed; files, questionnaires and queue preserved.")
        return true
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
        guard !isBackgroundSyncRunning else { return }
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

    @discardableResult
    func resumePendingSync() async -> Bool {
        guard !Task.isCancelled, transferNetworkAllowsWork, !serverToken.isEmpty, let store else { return false }
        let generation = UUID()
        let configuration = ServerConfiguration(baseURL: serverBaseURL, wifiOnly: serverWifiOnly, accountID: selectedAccountID)
        let token = serverToken
        retirementCheckGeneration = generation
        retirementCheckState = "checking"; retirementCheckError = nil
        do {
            let client = try serverClient()
            // The client's own cancellation/generation guard runs immediately
            // before applying markers, so disconnect cannot apply a stale result.
            try await client.reconcileDeletions(into: store, acceptResult: { [weak self] in
                guard let self else { return false }
                return self.retirementCheckGeneration == generation && self.serverToken == token &&
                    configuration == ServerConfiguration(baseURL: self.serverBaseURL, wifiOnly: self.serverWifiOnly, accountID: self.selectedAccountID)
            })
            guard retirementCheckGeneration == generation, token == serverToken,
                  configuration == ServerConfiguration(baseURL: serverBaseURL, wifiOnly: serverWifiOnly, accountID: selectedAccountID) else { return false }
            retirementCheckState = "verified"; retirementCheckedAt = WoonaStore.iso8601(Date())
            retirementCleanupStatus = try store.retirementCleanupStatus()
            var success = true
            for profile in try store.pendingProfiles() {
                guard !Task.isCancelled else { return false }
                if !(await uploadProfile(profile)) { success = false }
            }
            for recording in try store.pendingRecordings() {
                guard !Task.isCancelled else { return false }
                if !(await sync(recording: recording)) { success = false }
            }
            reloadProfiles()
            return success && !Task.isCancelled
        } catch {
            if retirementCheckGeneration == generation && retirementCheckState == "checking" {
                retirementCheckState = serverToken.isEmpty ? "not_checked" : "failed"
                retirementCheckError = serverToken.isEmpty ? nil : error.localizedDescription
            }
            appendDiagnostic("Pending sync unavailable: \(error.localizedDescription)")
            return false
        }
    }

    func canRemoveLocalRecording(_ recording: WoonaRecording) -> Bool {
        canChangeAccount && exportPhase == nil && preparedExport == nil && recording.serverSyncState == "synced" &&
        !recording.questionnaireDirty && ["completed", "failed", "interrupted"].contains(recording.status) &&
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
            defer { downloadingRecordingID = nil; reloadRecentRecordings() }
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
                appendDiagnostic("Server files downloaded and verified")
            } catch { showError("Server download failed", error: error) }
        }
    }

    func retryFailedSync() {
        guard canChangeAccount else { errorMessage = serverMutationBlockedReason; return }
        guard let store else { return }
        do {
            try store.resetFailedSync()
            schedulePendingSync()
        } catch { showError("Failed to retry synchronization", error: error) }
    }

    func scheduleBackgroundSync() {
        guard backgroundSchedulingEnabled else { backgroundSyncStatus = "disabled"; return }
        guard BackgroundSyncRegistration.shared.registered else {
            backgroundSyncStatus = "failed"
            backgroundSyncError = "Background handler is not registered (com.woona.apps.sync). Foreground uploads remain available."
            return
        }
        guard !serverToken.isEmpty, let store else { return }
        do {
            let profiles = try store.pendingProfiles()
            let recordings = try store.pendingRecordings()
            guard !profiles.isEmpty || !recordings.isEmpty else { return }
        } catch {
            backgroundSyncStatus = "failed"
            backgroundSyncError = error.localizedDescription
            return
        }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundSyncIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        recordBackgroundSubmission { try BGTaskScheduler.shared.submit(request) }
    }

    // Kept injectable so error/success presentation is tested without OS scheduling.
    func recordBackgroundSubmission(_ submit: () throws -> Void) {
        do {
            try submit()
            backgroundSyncStatus = "scheduled"
            backgroundSyncError = nil
        } catch {
            backgroundSyncStatus = "failed"
            backgroundSyncError = error.localizedDescription
            appendDiagnostic("Background scheduling failed: \(error.localizedDescription)")
        }
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

    func connectV2Preview(to device: BleDevice) {
        guard canOpenBLEPicker else { return }
        isV2PreviewActive = true
        isCaptureReady = false
        v2Preview.prepare()
        Task {
            let accepted = await bleSessionManager.connect(to: device.id, purpose: .v2Preview)
            if !accepted { v2Preview.disconnected(reason: "V2 Bluetooth connection could not start. No session was created.") }
        }
    }

    // Called only after the UI's explicit firmware/SD disconnect confirmation.
    func disconnectV2Preview() {
        guard isV2PreviewActive else { return }
        v2Preview.disconnected()
        isV2PreviewActive = false
        bleConnectionPurpose = .record
        bleSessionManager.disconnect()
    }

    func enterForeground() { if isV2PreviewActive { v2Preview.setForeground(true) } }

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

    func connect(to device: BleDevice, questionnaire: SessionQuestionnaire) throws {
        guard !isAccountOperationRunning else { throw WoonaStoreError.invalidData("Дождитесь завершения операции аккаунта / Wait for the account operation") }
        guard canStartNewSession && !isConnectionActive else { throw WoonaStoreError.invalidData("Запись уже выполняется или останавливается / A capture is active or stopping") }
        guard let profile = selectedDogProfile, let store else {
            throw WoonaStoreError.invalidData("Выберите или создайте карточку животного / Select or create an animal profile")
        }
        activeRecording = try store.createRecording(profile: profile, source: "live", questionnaire: questionnaire)
        isCaptureReady = false
        isRecording = false
        isCameraDegraded = false
        cameraCaptureInfo = nil
        captureErrorCode = nil
        captureErrorMessage = nil
        captureStopInProgress = false
        hasPreparedActiveCapture = false
        invalidateSessionExportAvailability()
        resetCaptureClockAnchor()
        connect(to: device)
    }

    func disconnect() {
        // Preview disconnect requires the separate firmware/SD confirmation.
        guard !isV2PreviewActive else { return }
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
                invalidateSessionExportAvailability()
                packetUpdateBatcher.clearPending()
                await replayController.startReplay(bytes)
            } catch {
                await packetProcessor.resetSession()
                showError("Failed to load replay file", error: error)
                if activeRecording?.source == "replay" { stopActiveCapture(status: "failed") }
            }
        }
    }

    func startReplay(from fileURL: URL, questionnaire: SessionQuestionnaire) throws {
        guard !isAccountOperationRunning else { throw WoonaStoreError.invalidData("Дождитесь завершения операции аккаунта / Wait for the account operation") }
        guard canStartNewSession && !isConnectionActive else { throw WoonaStoreError.invalidData("Запись уже выполняется или останавливается / A capture is active or stopping") }
        guard let profile = selectedDogProfile, let store else {
            throw WoonaStoreError.invalidData("Выберите или создайте карточку животного / Select or create an animal profile")
        }
        activeRecording = try store.createRecording(profile: profile, source: "replay", questionnaire: questionnaire)
        cameraCaptureInfo = nil
        captureErrorCode = nil
        captureErrorMessage = nil
        captureStopInProgress = false
        hasPreparedActiveCapture = false
        invalidateSessionExportAvailability()
        resetCaptureClockAnchor()
        startReplay(from: fileURL)
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
        captureFinalizationBackgroundTime.begin { [weak self] in
            guard let self else { return }
            self.captureStopTask?.cancel()
            self.errorMessage = self.selectedLanguage == .russian
                ? "iOS завершает время сохранения в фоне. Исходные файлы сохранены; откройте приложение для восстановления прерванной сессии."
                : "iOS ended the background finalization time. Original files are preserved; open the app to recover the interrupted session."
        }
        packetIngressGate.stop()
        isRecording = false
        statusText = "Finalizing"
        captureStopTask = Task {
            defer { captureStopTask = nil; captureFinalizationBackgroundTime.end() }
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
        if activeRecording != nil {
            stopActiveCapture(status: packetsReceived > 0 ? "completed" : "failed")
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
        if isV2PreviewActive { v2Preview.setForeground(false); return }
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
        guard exportPhase == nil, canExportCompleteArchive else {
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
            if transferNetworkAllowsWork { schedulePendingSync() }
        }
    }

    func cancelCompleteDataArchive() {
        completeArchiveWorker?.cancel()
        completeArchiveTask?.cancel()
    }

    var canOpenSessionExport: Bool { ExportKind.allCases.contains { canExportSessionFile($0) } }

    func canExportSessionFile(_ kind: ExportKind) -> Bool {
        guard exportPhase == nil, removingLocalRecordingID == nil,
              availableSessionExportKinds.contains(kind) else { return false }
        if kind == .all { return activeRecording == nil && !captureStopInProgress }
        return activeRecording == nil || hasPreparedActiveCapture
    }

    private func invalidateSessionExportAvailability() {
        availableSessionExportKinds = []
        sessionExportAvailabilityRevision &+= 1
        exportAvailabilityReadGeneration &+= 1
    }

    // Public for lifecycle refresh and tests. File presence is checked directly;
    // packet counters and saved upload status never stand in for local bytes.
    func refreshExportAvailability() async {
        exportAvailabilityReadGeneration &+= 1
        let generation = exportAvailabilityReadGeneration
        let account = selectedAccountID; let animal = selectedDogProfile?.id
        let activeID = activeRecording?.id
        let saved: RecordingArchive?
        if activeID == nil, let recording = recentRecordings.first(where: { exportableRecordingIDs.contains($0.id) }) {
            saved = try? store?.recordingArchive(recordingID: recording.id)
        } else { saved = nil }
        let useCurrent = activeID == nil || hasPreparedActiveCapture
        let currentPacket = useCurrent ? await packetProcessor.currentPacketFile() : nil
        let currentRaw = useCurrent ? await packetProcessor.currentRawFile() : nil
        let currentLog = useCurrent ? await packetProcessor.currentLogFile() : nil
        guard !Task.isCancelled, generation == exportAvailabilityReadGeneration,
              selectedAccountID == account, selectedDogProfile?.id == animal,
              activeRecording?.id == activeID else { return }
        availableSessionExportKinds = sessionExportKinds(
            packetFile: saved == nil ? currentPacket : saved?.files.first { $0.url.lastPathComponent == "packets.bin" }?.url,
            rawFile: saved == nil ? currentRaw : saved?.files.first { $0.url.lastPathComponent == "raw_fragments.binlog" }?.url,
            logFile: saved == nil ? currentLog : saved?.files.first { $0.url.lastPathComponent == "diagnostics.log" }?.url,
            archiveFiles: activeID == nil && !captureStopInProgress ? saved?.files.map(\.url) ?? [] : [])
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

    func saveSessionQuestionnaire(_ questionnaire: SessionQuestionnaire, displayedRecording: WoonaRecording, expectedRevision: Int? = nil) async throws {
        guard canEditQuestionnaire(displayedRecording), let store,
              let profile = try store.profile(dogID: displayedRecording.dogID, versionID: displayedRecording.profileVersionID),
              profile.accountID == selectedAccountID else {
            throw WoonaStoreError.invalidData("Редактирование временно недоступно: проверьте аккаунт и дождитесь завершения записи/синхронизации / Editing is unavailable; check the account and wait for capture/synchronization")
        }
        if ["synced", "remote"].contains(displayedRecording.serverSyncState) {
            isAccountOperationRunning = true
            defer { isAccountOperationRunning = false; schedulePendingSync() }
            let client = try questionnaireClientFactory?(profile.accountID) ?? serverClient(accountID: profile.accountID)
            let canonical: SessionQuestionnaire
            let revision: Int
            do {
                let detail = try await client.updateQuestionnaire(recordingID: displayedRecording.id,
                    questionnaire: questionnaire, expectedRevision: expectedRevision ?? displayedRecording.questionnaireRevision)
                canonical = try JSONDecoder().decode(SessionQuestionnaire.self, from: JSONEncoder().encode(detail.sessionQuestionnaire))
                revision = detail.questionnaireRevision ?? 1
            } catch ServerSyncError.requestFailed(409, _) {
                // The previous timed-out PUT may already have committed. Read only;
                // a different answer set requires an explicit choice in the editor.
                let latest = try await client.recordingDetail(displayedRecording.id)
                let answers = try JSONDecoder().decode(SessionQuestionnaire.self, from: JSONEncoder().encode(latest.sessionQuestionnaire))
                guard questionnaireAnswersMatch(questionnaire, answers) else {
                    throw QuestionnaireRevisionConflict(questionnaire: answers, revision: latest.questionnaireRevision ?? 1)
                }
                canonical = answers; revision = latest.questionnaireRevision ?? 1
            }
            try store.saveSessionQuestionnaire(recordingID: displayedRecording.id, questionnaire: canonical, revision: revision)
            reloadRecentRecordings()
        } else {
            try store.saveSessionQuestionnaire(recordingID: displayedRecording.id, questionnaire: questionnaire)
            reloadRecentRecordings()
            if let updated = try store.recording(id: displayedRecording.id) { scheduleSync(updated) }
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
        removingLocalRecordingID == nil && !isAccountOperationRunning && scheduledSyncCount == 0 && !syncingRecordingIDs.contains(recording.id) && activeRecording == nil && !captureStopInProgress && ["completed", "failed", "interrupted"].contains(recording.status)
    }

    func saveHeartQuestionnaire(_ heart: HeartQuestionnaire, displayedRecording: WoonaRecording, expectedRevision: Int? = nil) async throws {
        guard var questionnaire = displayedRecording.questionnaire else {
            throw WoonaStoreError.invalidData("Исходная анкета сессии отсутствует / The original session questionnaire is missing")
        }
        if let expectedRevision {
            guard let store, let profile = try store.profile(dogID: displayedRecording.dogID, versionID: displayedRecording.profileVersionID),
                  profile.accountID == selectedAccountID else { throw WoonaStoreError.invalidData("Аккаунт записи изменился / Recording account changed") }
            let client = try questionnaireClientFactory?(profile.accountID) ?? serverClient(accountID: profile.accountID)
            let latest = try await client.recordingDetail(displayedRecording.id)
            let answers = try JSONDecoder().decode(SessionQuestionnaire.self, from: JSONEncoder().encode(latest.sessionQuestionnaire))
            guard latest.questionnaireRevision == expectedRevision else { throw QuestionnaireRevisionConflict(questionnaire: answers, revision: latest.questionnaireRevision ?? 1) }
            questionnaire = answers
        }
        questionnaire.heartQuestionnaire = heart.normalized()
        try await saveSessionQuestionnaire(questionnaire, displayedRecording: displayedRecording, expectedRevision: expectedRevision)
    }

    func heartQuestionnaireDraft(recordingID: UUID) -> HeartQuestionnaire {
        if let saved = try? store?.recording(id: recordingID)?.questionnaire?.heartQuestionnaire { return saved }
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

    func attachReference(recordingID: UUID, type: String, url: URL, metadata: ReferenceMetadata) async throws {
        guard let store, let recording = try store.recording(id: recordingID), canEditQuestionnaire(recording),
              let profile = try store.profile(dogID: recording.dogID, versionID: recording.profileVersionID),
              profile.accountID == selectedAccountID else {
            throw WoonaStoreError.invalidData("Контрольный файл пока нельзя добавить: проверьте аккаунт и завершите запись/синхронизацию / Cannot attach the reference yet; check account and finish capture/synchronization")
        }
        isAccountOperationRunning = true
        defer { isAccountOperationRunning = false; schedulePendingSync() }
        let root = store.rootDirectory
        try await Task.detached(priority: .userInitiated) {
            try WoonaStore(rootDirectory: root).attachReference(recordingID: recordingID, type: type, sourceURL: url, metadata: metadata)
        }.value
        // The local copy is durable. A later transport failure belongs to the upload
        // queue and must not make the operator attach the same file a second time.
        reloadRecentRecordings()
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
            let profileQueue = try store.profileSyncOverview()
            profileUploadPending = profileQueue.pending
            profileUploadFailed = profileQueue.failed
            profileUploadLastError = profileQueue.lastError
            let inventory = try store.localInventory()
            localProfileCount = inventory.profiles; localRecordingCount = inventory.recordings
            hiddenProfileCount = allProfiles.filter { $0.accountID != selectedAccountID }.count
            dogProfiles = allProfiles.filter { $0.accountID == selectedAccountID }
            unassignedDogProfiles = allProfiles.filter { $0.accountID == nil }
            let id = preferredID ?? selectedDogProfile?.id
            selectedDogProfile = id.flatMap { id in dogProfiles.first { $0.id == id } } ?? dogProfiles.first
            if previousDogID != selectedDogProfile?.id || previousAccountID != selectedDogProfile?.accountID {
                serverRecordings = []
                serverTransferStatuses = [:]; transferStatusErrors = [:]; transferCheckedAt = [:]
            }
            if let selectedDogProfile {
                UserDefaults.standard.set(selectedDogProfile.id.uuidString, forKey: "selectedDogID")
            }
            reloadRecentRecordings()
        } catch { errorMessage = "Failed to load profiles: \(error.localizedDescription)" }
    }

    private func reloadRecentRecordings() {
        defer { invalidateSessionExportAvailability() }
        if let cleanup = try? store?.retirementCleanupStatus() { retirementCleanupStatus = cleanup }
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
        if let syncClientFactory { return try syncClientFactory(accountID) }
        return try WoonaServerClient(
            configuration: ServerConfiguration(baseURL: serverBaseURL, wifiOnly: serverWifiOnly, accountID: accountID),
            token: serverToken
        )
    }

    @discardableResult
    private func uploadProfile(_ profile: DogProfile) async -> Bool {
        guard !Task.isCancelled, transferNetworkAllowsWork, !serverToken.isEmpty, let store,
              !syncingProfileVersionIDs.contains(profile.profileVersionID) else {
            if !Task.isCancelled { scheduleBackgroundSync() }
            return false
        }
        uploadingProfileCount += 1
        syncingProfileVersionIDs.insert(profile.profileVersionID)
        defer {
            uploadingProfileCount -= 1
            syncingProfileVersionIDs.remove(profile.profileVersionID)
            reloadProfiles()
            if !Task.isCancelled { scheduleBackgroundSync() }
        }
        do {
            _ = try await serverClient(accountID: profile.accountID).upload(profile: profile, store: store)
            let state = try store.profileSyncState(versionID: profile.profileVersionID)
            return !Task.isCancelled && state == "synced"
        } catch {
            if !Task.isCancelled {
                let explanation = recordingUploadErrorText(error.localizedDescription, language: selectedLanguage)
                showError(explanation == error.localizedDescription ? "Profile upload failed" : explanation, error: error)
            }
            return false
        }
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
            let finalization = try await CaptureFinalizer.run(root: store.rootDirectory, recordingID: recording.id, status: finalStatus, files: files, syncJSON: data)
            activeRecording = nil
            hasPreparedActiveCapture = false
            isCaptureReady = false
            isRecording = false
            statusText = finalization.retired ? (selectedLanguage == .russian ? "Удалено по команде сервера" : "Retired by server") : finalStatus.capitalized
            reloadProfiles(selecting: selectedDogProfile?.id)
            if let cleanupError = finalization.cleanupError {
                showError(selectedLanguage == .russian ? "Локальная финализация завершена; отложенная очистка требует повтора" : "Local finalization finished; deferred cleanup needs a retry", error: WoonaStoreError.invalidData(cleanupError))
            }
            if let finalized = try store.recording(id: recording.id) {
                // Durable capture completion releases the next session before network
                // transfer starts. The upload queue owns its own busy/error states.
                scheduleSync(finalized)
            }
        } catch is CancellationError {
            showError(selectedLanguage == .russian
                ? "Сохранение прервано до подтверждения локальной базы. Исходные файлы сохранены; повторите завершение или откройте приложение для восстановления."
                : "Finalization paused before local metadata was committed. Original files are preserved; retry finishing or reopen the app for recovery.", error: nil)
        } catch { showError("Failed to finalize recording", error: error) }
    }

    @discardableResult
    private func sync(recording: WoonaRecording) async -> Bool {
        guard !Task.isCancelled, transferNetworkAllowsWork, removingLocalRecordingID == nil, !isAccountOperationRunning, !serverToken.isEmpty, let store, recording.questionnaire?.readyForSync != false, !syncingRecordingIDs.contains(recording.id) else { return false }
        syncingRecordingIDs.insert(recording.id)
        reloadRecentRecordings()
        defer { syncingRecordingIDs.remove(recording.id); reloadRecentRecordings() }
        do {
            var current = recording
            // Await follow-up revisions in the same operation. A detached retry could
            // outlive BGTask expiration and falsely report the queue as complete.
            for _ in 0..<3 {
                try Task.checkCancellation()
                guard transferNetworkAllowsWork, current.questionnaire?.readyForSync != false else { return false }
                guard let profile = try store.profile(dogID: current.dogID, versionID: current.profileVersionID) else {
                    throw WoonaStoreError.invalidData("Recording profile version is missing")
                }
                try await serverClient(accountID: profile.accountID).upload(recording: current, profile: profile, store: store, onProgress: { [weak self] in self?.reloadRecentRecordings() })
                try Task.checkCancellation()
                reloadRecentRecordings()
                await reloadServerRecordings()
                guard let latest = try store.recording(id: recording.id) else { return false }
                if latest.serverSyncState != "pending" {
                    scheduleBackgroundSync()
                    return latest.serverSyncState == "synced" && !Task.isCancelled
                }
                current = latest
            }
        } catch {
            reloadRecentRecordings()
            if !Task.isCancelled { showError("Recording upload failed", error: error) }
        }
        if !Task.isCancelled { scheduleBackgroundSync() }
        return false
    }

    func performBackgroundSync(networkTimeout: TimeInterval = 24) async -> Bool {
        guard !isBackgroundSyncRunning else { return false }
        isBackgroundSyncRunning = true
        defer { isBackgroundSyncRunning = false }
        backgroundSyncStatus = "running"
        let networkAllowed = await awaitFirstTransferNetwork(timeout: networkTimeout)
        let canRun = networkAllowed && syncingRecordingIDs.isEmpty && uploadingProfileCount == 0 &&
            scheduledSyncCount == 0 && !isAccountOperationRunning
        let success: Bool
        if canRun { success = await resumePendingSync() }
        else { success = false }
        scheduleBackgroundSync()
        if backgroundSyncStatus != "failed" {
            backgroundSyncStatus = success && !Task.isCancelled ? "completed" : "incomplete"
        }
        return success && !Task.isCancelled
    }

    // Called once by the real app entry point, never by AppViewModel initialization.
    func registerBackgroundSync() {
        guard backgroundSchedulingEnabled else { backgroundSyncStatus = "disabled"; return }
        let registered = BackgroundSyncRegistration.shared.register(owner: self) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.backgroundSyncIdentifier, using: .main) { task in
                MainActor.assumeIsolated {
                    guard let task = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
                    let operation = BackgroundSyncExecution.start(work: {
                        guard let owner = BackgroundSyncRegistration.shared.owner else { return false }
                        return await owner.performBackgroundSync()
                    }, completion: { task.setTaskCompleted(success: $0) })
                    task.expirationHandler = { operation.cancel() }
                }
            }
        }
        if !registered {
            backgroundSyncStatus = "failed"
            backgroundSyncError = "iOS rejected background handler registration. Check BGTaskSchedulerPermittedIdentifiers in the built Info.plist."
            appendDiagnostic(backgroundSyncError!)
        }
    }

    private func makeBleSessionManager() -> BleSessionManager {
        hasInitializedBleSessionManager = true
        let submitter = packetFragmentSubmitter
        let processor = packetProcessor
        let ingressGate = packetIngressGate
        let previewWorker = v2Preview.worker
        v2Preview.send = { [weak self] wire, completion in
            guard let self, self.isV2PreviewActive else { completion(.failure(BleControlWriteError.disconnected)); return }
            self.bleSessionManager.writePreviewFrame(wire, completion: completion)
        }
        return BleSessionManager(
            onDeviceFound: { [weak self] device in
                self?.addFoundDevice(device)
            },
            onPacketReceived: { data in
                guard let timestamp = ingressGate.timestampIfActive() else { return }
                submitter.enqueue(data, receivedAtMonotonicNs: timestamp)
            },
            onDiagnosticMessage: { [weak self] message in
                guard let self else { return }
                if self.isV2PreviewActive { self.appendDiagnostic(message) }
                else { self.appendBleDiagnostic(message, packetProcessor: processor) }
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
                if self?.isV2PreviewActive == true {
                    self?.v2Preview.disconnected(reason: [message, error?.localizedDescription].compactMap { $0 }.joined(separator: ": "))
                }
                self?.showError(message, error: error)
            },
            onPreviewReady: { [weak self] in self?.v2Preview.ready() },
            onPreviewBytes: { bytes in previewWorker.receive(bytes) }
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
        if isV2PreviewActive {
            isScanning = state == .scanning
            isConnected = state == .connected
            isConnectionActive = state == .connecting || state == .connected
            statusText = "V2 preview"
            if state == .disconnected || state == .failed { v2Preview.disconnected(reason: state == .failed ? "V2 Bluetooth connection failed" : "Bluetooth disconnected. Preview was not saved.") }
            return
        }
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
        // Counters only trigger a fresh filesystem check when a writer may have
        // opened. They never determine whether an export action is enabled.
        if (update.packetsReceived > 0 && !availableSessionExportKinds.contains(.packetDump)) ||
           (update.fragmentsReceived > 0 && !availableSessionExportKinds.contains(.rawFragments)) ||
           (!update.diagnosticEvents.isEmpty && !availableSessionExportKinds.contains(.diagnosticLog)) {
            invalidateSessionExportAvailability()
        }
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
        invalidateSessionExportAvailability()
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
        case .uploadBinary: "Replay local file (debug)"
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
        case .uploadBinary: "Воспроизвести локальный файл (отладка)"
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

enum ExportKind: String, CaseIterable, Identifiable, Equatable, Hashable {
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

@MainActor
final class BackgroundSyncRegistration {
    static let shared = BackgroundSyncRegistration()
    private(set) var attempted = false
    private(set) var registered = false
    private(set) weak var owner: AppViewModel?

    func register(owner: AppViewModel, registrar: () -> Bool) -> Bool {
        self.owner = owner
        guard !attempted else { return registered }
        attempted = true
        registered = registrar()
        return registered
    }
}

@MainActor
enum BackgroundSyncExecution {
    static func start(work: @escaping @MainActor () async -> Bool,
                      completion: @escaping @MainActor (Bool) -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            guard !Task.isCancelled else { completion(false); return }
            let success = await work()
            completion(success && !Task.isCancelled)
        }
    }
}

func sessionExportKinds(packetFile: URL?, rawFile: URL?, logFile: URL?, archiveFiles: [URL]) -> Set<ExportKind> {
    func present(_ url: URL?) -> Bool {
        guard let url else { return false }
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) &&
            !directory.boolValue && FileManager.default.isReadableFile(atPath: url.path)
    }
    var kinds: Set<ExportKind> = []
    if present(packetFile) { kinds.formUnion([.packetDump, .channelCsv]) }
    if present(rawFile) { kinds.insert(.rawFragments) }
    if present(logFile) { kinds.insert(.diagnosticLog) }
    if archiveFiles.contains(where: { present($0) }) { kinds.insert(.all) }
    return kinds
}

/// Finite time to close writers and commit local capture metadata. This does
/// not enable background camera recording or promise unlimited background work.
@MainActor
final class CaptureFinalizationBackgroundTime {
    typealias Begin = (@escaping () -> Void) -> UIBackgroundTaskIdentifier
    private let enabled: Bool
    private let beginOperation: Begin
    private let endOperation: (UIBackgroundTaskIdentifier) -> Void
    private var identifier = UIBackgroundTaskIdentifier.invalid
    private var generation: UUID?

    init(enabled: Bool, begin: Begin? = nil, end: ((UIBackgroundTaskIdentifier) -> Void)? = nil) {
        self.enabled = enabled
        beginOperation = begin ?? { expiration in
            UIApplication.shared.beginBackgroundTask(withName: "Woona capture finalization", expirationHandler: expiration)
        }
        endOperation = end ?? { UIApplication.shared.endBackgroundTask($0) }
    }

    func begin(onExpiration: @escaping () -> Void) {
        guard enabled, generation == nil else { return }
        let token = UUID()
        generation = token
        identifier = beginOperation { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.end()
                onExpiration()
            }
        }
        if identifier == .invalid { generation = nil }
    }

    func end() {
        let completed = identifier
        identifier = .invalid; generation = nil
        if completed != .invalid { endOperation(completed) }
    }
}
