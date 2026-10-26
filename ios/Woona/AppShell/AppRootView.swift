import SwiftUI

struct AppRootView: View {
    @EnvironmentObject private var appState: AppViewModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            TabView(selection: $appState.selectedTab) {
                OverviewView(section: .animals)
                    .toolbar(.hidden, for: .tabBar)
                    .tag(AppViewModel.AppTab.overview)
                VStack(spacing: 0) {
                    Picker(appState.selectedLanguage == .russian ? "Сессия" : "Session", selection: $appState.showingSessionCharts) {
                        Text(appState.selectedLanguage == .russian ? "Сессия" : "Session").tag(false)
                        Text(appState.text(.charts)).tag(true)
                    }
                    .pickerStyle(.segmented).padding(.horizontal, 12).padding(.vertical, 8)
                    .accessibilityIdentifier("session.section")
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

            if let exportPhase = appState.exportPhase, appState.preparedExport == nil {
                ExportProgressOverlay(phase: exportPhase)
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
            .background(Color(uiColor: .secondarySystemGroupedBackground))
        }
        .tint(Color(red: 20.0 / 255, green: 107.0 / 255, blue: 116.0 / 255))
        .preferredColorScheme(preferredColorScheme)
        .sheet(item: Binding(
            get: { appState.preparedExport },
            set: { _ in appState.clearPreparedExport() }
        )) { export in
            ActivityView(items: export.urls)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                appState.enterBackground()
            }
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
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("tab.\(tab)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
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
