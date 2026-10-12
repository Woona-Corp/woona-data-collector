import SwiftUI
import UIKit

@main
struct WoonaApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appState = AppViewModel()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environmentObject(appState)
        }
        .onChange(of: scenePhase, initial: true) { _, newPhase in
            UIApplication.shared.isIdleTimerDisabled = newPhase != .background
        }
    }
}
