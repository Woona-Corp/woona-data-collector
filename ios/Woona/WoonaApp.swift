import SwiftUI
import UIKit

@main
struct WoonaApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var appState: AppViewModel

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("WoonaUITests-" + UUID().uuidString)
            let store = try? WoonaStore(rootDirectory: root)
            for index in 1...2 {
                var questionnaire = DogQuestionnaire()
                questionnaire.schemaVersion = 2
                questionnaire.animalId = "ui-dog-\(index)"
                questionnaire.numberOrName = "UI Dog \(index)"
                questionnaire.species = "собака"
                _ = try? store?.saveProfile(questionnaire)
            }
            let model = AppViewModel(store: store, uiTesting: true)
            if ProcessInfo.processInfo.arguments.contains("--ui-language=ru") { model.selectedLanguage = .russian }
            if ProcessInfo.processInfo.arguments.contains("--ui-theme=dark") { model.selectedThemeMode = .dark }
            _appState = StateObject(wrappedValue: model)
            return
        }
        #endif
        _appState = StateObject(wrappedValue: AppViewModel())
    }

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
