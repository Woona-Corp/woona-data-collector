import SwiftUI
import UIKit

struct AppRootView: View {
    @EnvironmentObject private var appState: AppViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        ZStack {
            TabView(selection: $appState.selectedTab) {
                OverviewView(section: .animals)
                    .toolbar(.hidden, for: .tabBar)
                    .tag(AppViewModel.AppTab.overview)
                Group {
                    if appState.showingSessionCharts { ChartsView() }
                    else { OverviewView(section: .session) }
                }
                .toolbar(.hidden, for: .tabBar)
                .tag(AppViewModel.AppTab.session)
                OverviewView(section: .video)
                    .toolbar(.hidden, for: .tabBar)
                    .tag(AppViewModel.AppTab.video)
                OverviewView(section: .recordings)
                    .toolbar(.hidden, for: .tabBar)
                    .tag(AppViewModel.AppTab.recordings)

                SettingsView()
                    .tabItem {
                        Label(appState.text(.settings), systemImage: "gearshape")
                    }
                    .toolbar(.hidden, for: .tabBar)
                    .tag(AppViewModel.AppTab.settings)
            }
            .disabled(appState.isLocalRecoveryRunning)

            if appState.isLocalRecoveryRunning {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(appState.selectedLanguage == .russian ? "Восстанавливаем прерванную локальную работу…" : "Recovering interrupted local work…")
                    Text(appState.selectedLanguage == .russian ? "Исходные файлы сохраняются. Дождитесь окончания проверки перед новой записью." : "Original files are preserved. Wait for this check before starting another capture.")
                        .font(.footnote)
                }
                .padding(24).background(Color.woonaSurface, in: RoundedRectangle(cornerRadius: 12))
                .padding(20)
                .accessibilityIdentifier("startup.recovery")
            }

            if let exportPhase = appState.exportPhase, appState.preparedExport == nil {
                ExportProgressOverlay(phase: exportPhase)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let error = appState.localRecoveryError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(appState.selectedLanguage == .russian ? "Локальное восстановление не завершено" : "Local recovery is incomplete").font(.headline)
                    Text(error).font(.caption).textSelection(.enabled)
                    Text(appState.selectedLanguage == .russian ? "Исходные файлы сохранены. Можно экспортировать все данные в Настройках." : "Original files are preserved. You can export all data in Settings.").font(.footnote)
                    Button(appState.selectedLanguage == .russian ? "Повторить восстановление" : "Retry recovery") { appState.recoverLocalData() }
                        .disabled(!appState.canExportCompleteArchive)
                }.padding(12).background(Color.woonaSurface)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 8) {
                navigationItem(.overview, title: appState.selectedLanguage == .russian ? "Животные" : "Animals", symbol: "pawprint")
                navigationItem(.session, title: appState.selectedLanguage == .russian ? "Сессия" : "Session", symbol: "waveform.path.ecg")
                navigationItem(.video, title: appState.selectedLanguage == .russian ? "Видео" : "Video", symbol: "video")
                navigationItem(.recordings, title: appState.selectedLanguage == .russian ? "Записи" : "Recordings", symbol: "folder")
                navigationItem(.settings, title: appState.text(.settings), symbol: "gearshape")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.woonaSurface)
        }
        .tint(usesDarkPalette ? WoonaPalette.color(0x7ACCC5) : WoonaPalette.color(0x146B74))
        .preferredColorScheme(preferredColorScheme)
        .task(id: "\(appState.selectedTab)-\(appState.sessionExportAvailabilityRevision)") {
            await appState.refreshExportAvailability()
        }
        .sheet(item: Binding(
            get: { appState.preparedExport },
            set: { _ in appState.clearPreparedExport() }
        )) { export in
            ActivityView(items: export.urls)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                appState.enterBackground()
            } else if newPhase == .active { appState.enterForeground() }
        }
    }

    private func navigationItem(_ tab: AppViewModel.AppTab, title: String, symbol: String) -> some View {
        let selected = appState.selectedTab == tab
        return Button { appState.selectedTab = tab } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 20))
                Text(title).font(.system(size: 10, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .foregroundStyle(selected ? Color.woonaSelectionText : Color.woonaMuted)
            .background(selected ? Color.woonaSelection : .clear, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("tab.\(tab)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var usesDarkPalette: Bool {
        appState.selectedThemeMode == .dark || (appState.selectedThemeMode == .system && systemColorScheme == .dark)
    }

    private var preferredColorScheme: ColorScheme? {
        switch appState.selectedThemeMode {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

struct SessionSectionPicker: View {
    @EnvironmentObject private var appState: AppViewModel

    var body: some View {
        Picker(appState.selectedLanguage == .russian ? "Сессия" : "Session", selection: $appState.showingSessionCharts) {
            Text(appState.selectedLanguage == .russian ? "Сессия" : "Session").tag(false)
            Text(appState.text(.charts)).tag(true)
        }
        .pickerStyle(.segmented).padding(.horizontal, 12).padding(.vertical, 8)
        .accessibilityIdentifier("session.section")
    }
}


private struct ExportProgressOverlay: View {
    @EnvironmentObject private var appState: AppViewModel
    let phase: ExportPhase

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                ProgressView()
                Text(phase.rawValue)
                    .font(.headline)
                if appState.isCompleteArchiveExporting {
                    if let progress = appState.completeArchiveProgress {
                        Text("\(progress.completedFiles) / \(progress.totalFiles)").font(.footnote)
                        ProgressView(value: Double(progress.completedBytes), total: max(1, Double(progress.totalBytes)))
                    }
                    Button(appState.selectedLanguage == .russian ? "Отменить экспорт" : "Cancel export") { appState.cancelCompleteDataArchive() }
                }
            }
            .padding(24)
            .frame(maxWidth: 260)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(radius: 12)
        }
        .transition(.opacity)
    }
}

/// The same fixed palette as Android and the approved HTML prototype.
enum WoonaPalette {
    static func color(_ rgb: UInt32) -> Color { Color(uiColor: uiColor(rgb)) }
    static func uiColor(_ rgb: UInt32) -> UIColor {
        UIColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in uiColor(traits.userInterfaceStyle == .dark ? dark : light) })
    }
}
extension Color {
    static var woonaOnPrimary: Color { WoonaPalette.adaptive(light: 0xFFFFFF, dark: 0x0B3B40) }
    static var woonaSurface: Color { WoonaPalette.adaptive(light: 0xFFFFFF, dark: 0x182C38) }
    static var woonaBackground: Color { WoonaPalette.adaptive(light: 0xF4F7FA, dark: 0x101E27) }
    static var woonaInk: Color { WoonaPalette.adaptive(light: 0x172B3C, dark: 0xE3EDF1) }
    static var woonaMuted: Color { WoonaPalette.adaptive(light: 0x65778A, dark: 0xB1C6D0) }
    static var woonaSelection: Color { WoonaPalette.adaptive(light: 0xE3F4F1, dark: 0x204D50) }
    static var woonaSelectionText: Color { WoonaPalette.adaptive(light: 0x10555E, dark: 0xBDEFE8) }
}
