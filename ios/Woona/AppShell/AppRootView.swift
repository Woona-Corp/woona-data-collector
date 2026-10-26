import SwiftUI

struct AppRootView: View {
    @EnvironmentObject private var appState: AppViewModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            TabView(selection: $appState.selectedTab) {
                OverviewView()
                    .tabItem {
                        Label(appState.text(.overview), systemImage: "dot.radiowaves.left.and.right")
                    }
                    .toolbar(.hidden, for: .tabBar)
                    .tag(AppViewModel.AppTab.overview)

                ChartsView()
                    .tabItem {
                        Label(appState.text(.charts), systemImage: "chart.xyaxis.line")
                    }
                    .toolbar(.hidden, for: .tabBar)
                    .tag(AppViewModel.AppTab.charts)

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
                navigationItem(.overview, title: appState.text(.overview), symbol: "dot.radiowaves.left.and.right")
                navigationItem(.charts, title: appState.text(.charts), symbol: "chart.xyaxis.line")
                navigationItem(.settings, title: appState.text(.settings), symbol: "gearshape")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
        }
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
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
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
    let phase: ExportPhase

    var body: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                ProgressView()
                Text(phase.rawValue)
                    .font(.headline)
            }
            .padding(24)
            .frame(maxWidth: 260)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(radius: 12)
        }
        .transition(.opacity)
    }
}
