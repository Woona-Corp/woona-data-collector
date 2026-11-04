import Foundation

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
