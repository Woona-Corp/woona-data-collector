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
            var historyFixtureError: String?
            if ProcessInfo.processInfo.arguments.contains("--ui-testing-history") {
                do {
                    guard let store, let dog = try store.profiles().first(where: { $0.numberOrName == "UI Dog 1" }) else {
                        throw WoonaStoreError.invalidData("The synthetic UI history profile was not created")
                    }
                    var questionnaire = SessionQuestionnaire()
                    questionnaire.schemaVersion = 2
                    questionnaire.sessionLabel = "5"
                    questionnaire.sessionKind = "activity"
                    questionnaire.plannedActivities = ["Аллюр/движение"]
                    questionnaire.videoRequested = false
                    let recording = try store.createRecording(profile: dog, source: "live", questionnaire: questionnaire)
                    let file = store.directory(for: recording).appendingPathComponent("packets.bin")
                    let bytes = Data("Synthetic UI history fixture".utf8)
                    try bytes.write(to: file)
                    try store.finalize(recording: recording, status: "failed", files: [("packet", file, "packets.bin", "application/octet-stream")],
                                       syncJSON: Data(#"{"captureErrorCode":"gatt_error","captureErrorMessage":"GATT status 8"}"#.utf8))
                    let artifacts = try store.artifacts(recordingID: recording.id)
                    guard artifacts.count == 2, try WoonaStore.sha256File(file) == WoonaStore.sha256(bytes) else {
                        throw WoonaStoreError.invalidData("Synthetic history packet/sync artifacts were not preserved")
                    }
                    for artifact in artifacts {
                        try store.updateArtifactProgress(artifact.id, uploadedBytes: artifact.sizeBytes, state: "available")
                    }
                    try store.updateRecordingSync(recording.id, state: "synced")
                    guard let persisted = try store.recording(id: recording.id), persisted.status == "failed",
                          persisted.captureErrorCode == "gatt_error", persisted.captureErrorMessage == "GATT status 8",
                          persisted.serverSyncState == "synced", persisted.profileVersionID == dog.profileVersionID,
                          try store.artifacts(recordingID: recording.id).allSatisfy({ $0.uploadState == "available" && $0.uploadedBytes == $0.sizeBytes }) else {
                        throw WoonaStoreError.invalidData("Synthetic history failed to persist its capture reason or confirmed upload state")
                    }
                } catch {
                    historyFixtureError = "Synthetic UI history fixture failed: " + error.localizedDescription
                    NSLog("%@", historyFixtureError!)
                }
            }
            let model = AppViewModel(store: store, uiTesting: true)
            if let historyFixtureError { model.errorMessage = historyFixtureError }
            if ProcessInfo.processInfo.arguments.contains("--ui-language=ru") { model.selectedLanguage = .russian }
            if ProcessInfo.processInfo.arguments.contains("--ui-theme=dark") { model.selectedThemeMode = .dark }
            _appState = StateObject(wrappedValue: model)
            return
        }
        #endif
        let model = AppViewModel()
        model.registerBackgroundSync()
        _appState = StateObject(wrappedValue: model)
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
