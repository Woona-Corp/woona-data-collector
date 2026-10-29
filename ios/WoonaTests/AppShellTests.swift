import XCTest
import SQLite3
import UIKit
import SwiftUI
@testable import Woona

@MainActor
final class AppShellTests: XCTestCase {
    func testSheetPresentationUsesEnglishWithoutChangingCanonicalQuestionnaireData() throws {
        var dog = DogQuestionnaire()
        dog.schemaVersion = 2; dog.animalId = "presentation-fixture"
        dog.numberOrName = "Fixture"; dog.species = "собака"; dog.size = "мелкий"; dog.sex = "самец"
        let original = try WoonaStore.dogQuestionnaireData(dog)
        for (canonical, english) in englishQuestionnaireText {
            XCTAssertEqual(questionnaireDisplayText(canonical, language: .russian), canonical)
            XCTAssertEqual(questionnaireDisplayText(canonical, language: .english), english)
            XCTAssertNil(english.range(of: "[А-Яа-яЁё]", options: .regularExpression), canonical)
        }
        XCTAssertEqual(questionnaireDisplayText(dog.size, language: .english), "Small")
        XCTAssertEqual(questionnaireDisplayText(dog.sex, language: .english), "Male")
        XCTAssertEqual(dog.size, "мелкий"); XCTAssertEqual(dog.sex, "самец")
        XCTAssertEqual(try WoonaStore.dogQuestionnaireData(dog), original)
        XCTAssertEqual(questionnaireDisplayText("Unrecognized operator note", language: .english), "Unrecognized operator note")
    }

    func testSheetAndHeartValidationMessagesAreLocalizedIncludingDynamicLimitsAndFormats() {
        var dog = DogQuestionnaire(); dog.schemaVersion = 2
        var session = SessionQuestionnaire(); session.schemaVersion = 2
        let errors = Array(dog.validate().errors.values) + Array(session.validate().errors.values)
            + Array(HeartQuestionnaire().validate().errors.values) + Array(ReferenceMetadata().validate().errors.values)
        XCTAssertFalse(errors.isEmpty)
        for error in errors {
            let presented = questionnaireValidationError(error, language: .english)
            XCTAssertNil(presented.range(of: "[А-Яа-яЁё]", options: .regularExpression), error)
        }
        XCTAssertEqual(questionnaireDisplayText("Максимум 157 символов", language: .english), "Maximum 157 characters")
        XCTAssertEqual(questionnaireDisplayText("Формат: yyyy-MM-dd", language: .english), "Format: yyyy-MM-dd")
        XCTAssertEqual(questionnaireValidationError("Maximum 157 characters", language: .russian), "Максимум 157 символов")
        XCTAssertEqual(questionnaireFieldTitle("animalId", language: .english), "Animal number/ID *")
        XCTAssertEqual(questionnaireFieldTitle("not-a-public-field", language: .english), "Questionnaire")
    }

    func testAccountPromptPaletteKeepsReadableContrastInBothThemes() {
        func luminance(_ color: UIColor) -> Double {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
            func linear(_ component: CGFloat) -> Double {
                let value = Double(component)
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        }
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let text = luminance(UIColor(Color.woonaMuted).resolvedColor(with: traits))
            let surface = luminance(UIColor(Color.woonaSurface).resolvedColor(with: traits))
            XCTAssertGreaterThanOrEqual((max(text, surface) + 0.05) / (min(text, surface) + 0.05), 4.5)
        }
    }

    @MainActor
    func testCancelledQueuedV2ConnectCannotConnectOrOverwriteTheCancelledPreview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WoonaStore(rootDirectory: root)
        let model = AppViewModel(store: store, uiTesting: true)
        model.connectV2Preview(to: BleDevice(id: UUID(), name: "Synthetic queued preview"))
        model.disconnectV2Preview()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while model.v2Preview.snapshot.stage != .stopped, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        XCTAssertFalse(model.isV2PreviewActive)
        XCTAssertFalse(model.isConnectionActive)
        XCTAssertNil(model.v2Preview.snapshot.reason)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try store.localInventory().recordings, 0)
    }

    func testBuiltAppAdvertisesBackgroundProcessingWithTypedPlistArrays() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String], ["com.woona.apps.sync"])
        XCTAssertTrue((Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("processing") == true)
        XCTAssertEqual((Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any])?["NSAllowsLocalNetworking"] as? Bool, true)
    }

    func testBackgroundRegistrationIsOncePerCoordinatorAndUpdatesOnlyItsWeakOwner() {
        let registration = BackgroundSyncRegistration()
        var calls = 0
        var first: AppViewModel? = AppViewModel(store: nil, uiTesting: true)
        var second: AppViewModel? = AppViewModel(store: nil, uiTesting: true)
        XCTAssertTrue(registration.register(owner: first!) { calls += 1; return true })
        XCTAssertTrue(registration.register(owner: second!) { calls += 1; return false })
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(registration.owner === second)
        first = nil
        second = nil
        XCTAssertNil(registration.owner)
    }

    func testRejectedBackgroundRegistrationDoesNotAttemptASecondOSRegistration() {
        let registration = BackgroundSyncRegistration()
        let model = AppViewModel(store: nil, uiTesting: true)
        var calls = 0
        XCTAssertFalse(registration.register(owner: model) { calls += 1; return false })
        XCTAssertFalse(registration.register(owner: model) { calls += 1; return true })
        XCTAssertEqual(calls, 1)
        model.registerBackgroundSync()
        model.scheduleBackgroundSync()
        XCTAssertEqual(model.backgroundSyncStatus, "disabled")
    }

    func testBackgroundCompletionAwaitsItsWorkAndCancellationCannotReportSuccess() async {
        var finish: CheckedContinuation<Void, Never>?
        var results: [Bool] = []
        let operation = BackgroundSyncExecution.start(work: {
            await withCheckedContinuation { finish = $0 }
            return true
        }, completion: { results.append($0) })
        while finish == nil { await Task.yield() }
        XCTAssertTrue(results.isEmpty)
        operation.cancel() // Same handle used by BGTask.expirationHandler.
        finish?.resume()
        await operation.value
        XCTAssertEqual(results, [false])
    }

    func testBackgroundCompletionReportsFalseFromFailedWorkAndAwaitsSuccess() async {
        var finish: CheckedContinuation<Void, Never>?
        var results: [Bool] = []
        let operation = BackgroundSyncExecution.start(work: {
            await withCheckedContinuation { finish = $0 }
            return true
        }, completion: { results.append($0) })
        while finish == nil { await Task.yield() }
        XCTAssertTrue(results.isEmpty)
        finish?.resume()
        await operation.value
        XCTAssertEqual(results, [true])
        let failed = BackgroundSyncExecution.start(work: { false }, completion: { results.append($0) })
        await failed.value
        XCTAssertEqual(results, [true, false])
    }

    func testBackgroundSubmissionFailureIsVisibleAndAcceptanceDoesNotClaimExecution() {
        let model = AppViewModel(store: nil, uiTesting: true)
        model.selectedLanguage = .english
        model.recordBackgroundSubmission { throw NSError(domain: "synthetic.background", code: 7, userInfo: [NSLocalizedDescriptionKey: "Synthetic scheduling denied"]) }
        XCTAssertEqual(model.backgroundSyncStatus, "failed")
        XCTAssertEqual(model.backgroundSyncError, "Synthetic scheduling denied")
        XCTAssertTrue(model.backgroundSyncExplanation.contains("keep the app open"))
        model.recordBackgroundSubmission { }
        XCTAssertEqual(model.backgroundSyncStatus, "scheduled")
        XCTAssertNil(model.backgroundSyncError)
        XCTAssertTrue(model.backgroundSyncExplanation.contains("execution is not yet confirmed"))
    }

    func testFirstBackgroundPathWaitIsBoundedCancellableAndNeverInventsConnectivity() async {
        let model = AppViewModel(store: nil, uiTesting: true)
        let timedOut = await model.awaitFirstTransferNetwork(timeout: 0.01)
        XCTAssertFalse(timedOut)
        XCTAssertNil(model.networkAvailable)
        let cancelled = Task { await model.awaitFirstTransferNetwork(timeout: 24) }
        await Task.yield()
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        XCTAssertFalse(cancelledResult)
        let waiting = Task { await model.awaitFirstTransferNetwork(timeout: 1) }
        await Task.yield()
        model.updateTransferNetworkPath(available: true, unmetered: true)
        let allowed = await waiting.value
        XCTAssertTrue(allowed)
        model.serverWifiOnly = true
        model.updateTransferNetworkPath(available: true, unmetered: false)
        let restricted = await model.awaitFirstTransferNetwork(timeout: 1)
        XCTAssertFalse(restricted)
    }

    func testCaptureCauseIsIndependentOfSuccessfulUpload() {
        XCTAssertEqual(recordingCaptureText(status: "failed", code: "gatt_error", message: "Ошибка GATT-подключения: 8", language: .russian),
                       "Запись: прервана — сбой связи с ошейником (GATT 8)")
        XCTAssertEqual(recordingCaptureText(status: "failed", code: "gatt_error", message: "GATT status 133", language: .english),
                       "Capture: interrupted — collar connection failed (GATT 133)")
        XCTAssertEqual(recordingUploadText(state: "synced", message: nil, language: .russian), "Загрузка: загрузка была подтверждена; актуальную копию проверьте ниже")
        XCTAssertTrue(recordingCaptureText(status: "completed", code: "camera_failed", message: "Broken pipe", language: .russian).contains("завершена с проблемой"))
    }

    func testUnknownCaptureReasonIsExplicitAndNeverInvented() {
        XCTAssertTrue(recordingCaptureText(status: "failed", code: nil, message: nil, language: .russian).contains("причина не сохранена"))
        XCTAssertFalse(recordingCaptureText(status: "interrupted", code: nil, message: nil, language: .english).contains("collar"))
        let future = recordingCaptureText(status: "failed", code: "new_firmware_error", message: "Specific future error", language: .english)
        XCTAssertTrue(future.contains("new_firmware_error"))
        XCTAssertTrue(future.contains("Specific future error"))
    }

    func testUploadErrorsExposeCauseAndRetryPolicy() {
        let retry = recordingUploadText(state: "retryable_error", message: "Server returned 503: unavailable", language: .russian)
        XCTAssertTrue(retry.contains("запланирован повтор"))
        XCTAssertTrue(retry.contains("HTTP 503"))
        let forbidden = recordingUploadText(state: "permanent_error", message: "Server returned 403: forbidden", language: .english)
        XCTAssertTrue(forbidden.contains("action is required"))
        XCTAssertTrue(forbidden.contains("Permission was denied"))
        XCTAssertTrue(recordingUploadErrorText("invalid_bearer_token", language: .russian).contains("Токен"))
        XCTAssertTrue(recordingUploadErrorText("artifact_hash_mismatch", language: .russian).contains("Контрольная сумма"))
        XCTAssertTrue(recordingUploadErrorText("HTTP 409: profile_content_already_exists", language: .russian).contains("Восстановите профили"))
        XCTAssertTrue(recordingUploadErrorText("profile_content_already_exists", language: .english).contains("do not create it again"))
        XCTAssertTrue(recordingUploadErrorText("local_copy_changed", language: .russian).contains("Удаление отменено"))
        XCTAssertTrue(recordingUploadErrorText("Server token is missing", language: .russian).contains("токен"))
        let unknown = recordingUploadErrorText("Unexpected future failure", language: .english)
        XCTAssertTrue(unknown.contains("outcome is not confirmed"))
        XCTAssertTrue(unknown.contains("complete archive"))
        XCTAssertTrue(unknown.contains("Unexpected future failure"))
    }

    func testHTTPFailuresExplainSafeNextActions() {
        XCTAssertTrue(recordingUploadErrorText("HTTP 403", language: .english).contains("permission change"))
        XCTAssertTrue(recordingUploadErrorText("HTTP 409", language: .russian).contains("сравните их с черновиком"))
        XCTAssertTrue(recordingUploadErrorText("HTTP 422", language: .english).contains("indicated fields"))
        XCTAssertTrue(recordingUploadErrorText("HTTP 503", language: .russian).contains("повторите позже"))
        XCTAssertTrue(recordingUploadErrorText("HTTP 404", language: .english).contains("Preserve local originals"))
    }

    func testServerErrorDecodingRetainsBothCodeAndMessage() {
        let payload = Data(#"{"detail":{"code":"questionnaire_revision_conflict","message":"Changed on server"}}"#.utf8)
        let error = ServerSyncError.responseError(status: 409, data: payload)
        XCTAssertTrue(error.localizedDescription.contains("questionnaire_revision_conflict"))
        XCTAssertTrue(error.localizedDescription.contains("Changed on server"))
    }

    func testTransferFailureDescriptionsDistinguishServerRepairRetryAndPreservedLocalConflict() {
        XCTAssertTrue(recordingUploadErrorText("upload_offset_invalid: details", language: .russian).contains("Проверьте сервер"))
        XCTAssertTrue(recordingUploadErrorText("upload_conflict_stalled: details", language: .russian).contains("повтор продолжит"))
        XCTAssertTrue(recordingUploadErrorText("local_artifact_conflict: details", language: .russian).contains("не перезаписан"))
        XCTAssertTrue(recordingUploadErrorText("orphaned_upload_recovered: details", language: .russian).contains("Очередь восстановлена"))
    }

    func testTransferPolicyWaitsForFirstRealPathAndWifiPermissionWithoutInventingConnectivity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppViewModel(store: try WoonaStore(rootDirectory: root), uiTesting: true)
        XCTAssertNil(model.networkAvailable)
        XCTAssertNil(model.networkUnmetered)
        XCTAssertFalse(model.transferNetworkAllowsWork)
        model.serverWifiOnly = true
        model.updateTransferNetworkPath(available: false, unmetered: false)
        XCTAssertFalse(model.transferNetworkAllowsWork)
        model.updateTransferNetworkPath(available: true, unmetered: false)
        XCTAssertFalse(model.transferNetworkAllowsWork)
        model.updateTransferNetworkPath(available: true, unmetered: true)
        XCTAssertTrue(model.transferNetworkAllowsWork)
        // The first allowed callback schedules pending work, but UI-test configuration
        // has no token and therefore never sends a network request.
        await Task.yield()
        model.serverWifiOnly = false
        model.updateTransferNetworkPath(available: true, unmetered: false)
        XCTAssertTrue(model.transferNetworkAllowsWork)
    }

    func testRecordingTimeMatchesAndroidFormatAcrossISOInputs() {
        let zone = TimeZone(secondsFromGMT: 3 * 3600)!
        XCTAssertEqual(recordingDisplayTime("2026-10-26T11:32:00Z", timeZone: zone), "26.10.2026 14:32")
        XCTAssertEqual(recordingDisplayTime("2026-10-26T11:32:00.123Z", timeZone: zone), "26.10.2026 14:32")
        // PostgreSQL/FastAPI dates retain six fractional digits. Exercise Apple
        // Foundation through the actual card formatter, including a UTC offset
        // and a local-calendar date rollover rather than just parsing a Date.
        XCTAssertEqual(recordingDisplayTime("2026-10-27T13:49:03.123456Z", timeZone: zone), "27.10.2026 16:49")
        XCTAssertEqual(recordingDisplayTime("2026-10-27T16:49:03.123456+03:00", timeZone: zone), "27.10.2026 16:49")
        XCTAssertEqual(recordingDisplayTime("2026-10-27T23:59:59.123456Z", timeZone: zone), "28.10.2026 02:59")
        XCTAssertNotNil(ReferenceMetadata.date("2026-10-27T13:49:03.123456Z"))
        XCTAssertEqual(recordingDisplayTime("unknown", timeZone: zone), "unknown")
    }

    func testDisconnectRemovesOnlyCredentialsAndPreservesQueuedRecordingBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WoonaStore(rootDirectory: root)
        var animal = DogQuestionnaire(); animal.schemaVersion = 2; animal.animalId = "disconnect-fixture"; animal.numberOrName = "Synthetic animal"
        let profile = try store.saveProfile(animal)
        var answers = SessionQuestionnaire(); answers.schemaVersion = 2; answers.sessionLabel = "Keep offline data"; answers.plannedActivities = ["Покой"]
        let recording = try store.createRecording(profile: profile, source: "live", questionnaire: answers)
        let original = root.appendingPathComponent("source.bin")
        try Data("preserved capture bytes".utf8).write(to: original)
        try store.finalize(recording: recording, status: "completed", files: [("packet", original, "packets.bin", "application/octet-stream")], syncJSON: Data("{}".utf8))
        let before = try store.artifacts(recordingID: recording.id)
        var written: [String] = []
        let model = AppViewModel(store: store, uiTesting: true, serverTokenWriter: { written.append($0) })
        model.serverBaseURL = "https://example.test"; model.serverToken = "synthetic-device-credential"
        XCTAssertTrue(model.disconnectServer())
        XCTAssertEqual(written, [""])
        XCTAssertEqual(model.serverToken, "")
        XCTAssertEqual(model.serverBaseURL, "https://example.test")
        XCTAssertEqual(try store.recording(id: recording.id)?.serverSyncState, "pending")
        XCTAssertEqual(try store.artifacts(recordingID: recording.id).map(\.sha256), before.map(\.sha256))
        XCTAssertEqual(try store.artifacts(recordingID: recording.id).map(\.id), before.map(\.id))
        for artifact in before {
            XCTAssertEqual(try WoonaStore.sha256File(root.appendingPathComponent(artifact.relativePath)), artifact.sha256)
        }
    }

    func testDisconnectDoesNotClearInMemoryCredentialWhenKeychainRemovalFails() {
        let model = AppViewModel(store: nil, uiTesting: true, serverTokenWriter: { _ in
            throw WoonaStoreError.invalidData("Synthetic keychain removal denied")
        })
        model.serverToken = "synthetic-device-credential"
        XCTAssertFalse(model.disconnectServer())
        XCTAssertEqual(model.serverToken, "synthetic-device-credential")
        XCTAssertTrue(model.errorMessage?.contains("Synthetic keychain removal denied") == true)
    }

    func testProfileDatabaseFailureIsThrownAndRetryKeepsOriginalDraft() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        func exerciseFixture() async throws {
            let store = try WoonaStore(rootDirectory: directory)
            let model = AppViewModel(store: store, uiTesting: true)
            var draft = DogQuestionnaire()
            draft.schemaVersion = 2; draft.animalId = "retained-draft"; draft.numberOrName = "Unsaved animal"
            var database: OpaquePointer?
            XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("woona.sqlite").path, &database), SQLITE_OK)
            defer { sqlite3_close(database) }
            XCTAssertEqual(sqlite3_exec(database, "CREATE TRIGGER fail_profile_save BEFORE INSERT ON dogs BEGIN SELECT RAISE(ABORT, 'Injected database save failure'); END", nil, nil, nil), SQLITE_OK)
            XCTAssertThrowsError(try model.saveDogProfile(draft)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Injected database save failure"))
                XCTAssertTrue(questionnaireSaveError(error, language: .english).contains("Your draft remains open"))
            }
            XCTAssertEqual(draft.numberOrName, "Unsaved animal")
            XCTAssertTrue(try store.profiles().isEmpty)
            XCTAssertEqual(sqlite3_exec(database, "DROP TRIGGER fail_profile_save", nil, nil, nil), SQLITE_OK)
            try model.saveDogProfile(draft)
            XCTAssertEqual(try store.profiles().first?.questionnaire.animalId, "retained-draft")
            XCTAssertEqual(model.selectedDogProfile?.numberOrName, "Unsaved animal")
            // saveDogProfile owns an asynchronous upload attempt even without a
            // configured network. Finish it and the accepted history read before
            // releasing handles and unlinking this fixture's SQLite files.
            try await waitUntil("profile save and history housekeeping to finish", timeout: 10) {
                model.canChangeAccount && !model.isHistoryLoading
            }
        }
        try await exerciseFixture()
    }

    func testReplaySourceCannotBePresentedAsLiveSensorCapture() {
        XCTAssertEqual(recordingSourceText("live", language: .russian), "Источник: запись с датчика")
        XCTAssertEqual(recordingSourceText("replay", language: .english), "Source: local file replay")
        XCTAssertTrue(recordingSourceText("future_source", language: .russian).contains("неизвестен (future_source)"))
    }

    func testUnavailableDatabaseCannotReportProfileSaveSuccess() {
        let model = AppViewModel(store: nil, uiTesting: true)
        XCTAssertThrowsError(try model.saveDogProfile(DogQuestionnaire())) { error in
            XCTAssertTrue(error.localizedDescription.contains("database is unavailable"))
        }
    }

    func testAsyncFormSaveStatePropagatesFailureAndOnlyReportsSuccessAfterCompletion() async {
        let state = QuestionnaireSaveState()
        var draft = SessionQuestionnaire(); draft.sessionLabel = "Retained session draft"
        let failed = await state.save(language: .english) {
            XCTAssertTrue(state.isSaving)
            throw WoonaStoreError.invalidData("database unavailable")
        }
        XCTAssertFalse(failed); XCTAssertFalse(state.isSaving)
        XCTAssertTrue(state.error?.contains("database unavailable") == true)
        XCTAssertTrue(state.error?.contains("Your draft remains open") == true)
        XCTAssertEqual(draft.sessionLabel, "Retained session draft")
        let succeeded = await state.save(language: .english) { XCTAssertTrue(state.isSaving) }
        XCTAssertTrue(succeeded); XCTAssertNil(state.error)
        let conflicted = await state.save(language: .english) { throw QuestionnaireRevisionConflict(questionnaire: draft, revision: 3) }
        XCTAssertFalse(conflicted); XCTAssertEqual(state.conflict?.revision, 3)
        XCTAssertNil(state.expectedRevision, "A conflict must never silently rebase the draft")
    }

    func testSessionDatabaseFailureRetainsDraftAndTerminalUnknownEndIsSavable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        @MainActor func exerciseFixture() async throws {
            let store = try WoonaStore(rootDirectory: directory)
            var animal = DogQuestionnaire(); animal.schemaVersion = 2; animal.animalId = "fixture"; animal.numberOrName = "Synthetic animal"
            let profile = try store.saveProfile(animal)
            var original = SessionQuestionnaire(); original.schemaVersion = 2; original.sessionLabel = "Original"; original.plannedActivities = ["Покой"]
            let created = try store.createRecording(profile: profile, source: "replay", questionnaire: original)
            try store.markRecording(created.id, status: "completed")
            let recording = try XCTUnwrap(store.recording(id: created.id))
            XCTAssertNil(recording.endedAtUTC)
            let model = AppViewModel(store: store, uiTesting: true)
            XCTAssertTrue(model.canEditQuestionnaire(recording))
            var draft = try XCTUnwrap(recording.questionnaire); draft.sessionLabel = "Unsaved session draft"
            var database: OpaquePointer?
            XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("woona.sqlite").path, &database), SQLITE_OK)
            defer { sqlite3_close(database) }
            XCTAssertEqual(sqlite3_exec(database, "CREATE TRIGGER fail_session_save BEFORE UPDATE OF questionnaire_json ON recordings BEGIN SELECT RAISE(ABORT, 'Injected session save failure'); END", nil, nil, nil), SQLITE_OK)
            do { try await model.saveSessionQuestionnaire(draft, displayedRecording: recording); XCTFail("Database failure must reach the form") }
            catch { XCTAssertTrue(error.localizedDescription.contains("Injected session save failure")) }
            XCTAssertEqual(try store.recording(id: recording.id)?.questionnaire?.sessionLabel, "Original")
            XCTAssertEqual(draft.sessionLabel, "Unsaved session draft")
            XCTAssertEqual(sqlite3_exec(database, "DROP TRIGGER fail_session_save", nil, nil, nil), SQLITE_OK)
            try await model.saveSessionQuestionnaire(draft, displayedRecording: recording)
            XCTAssertEqual(try store.recording(id: recording.id)?.questionnaire?.sessionLabel, draft.sessionLabel)
            XCTAssertNil(try store.recording(id: recording.id)?.endedAtUTC, "Editing must not invent a capture end time")
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while !model.canEditQuestionnaire(recording), clock.now < deadline { await Task.yield() }
            XCTAssertTrue(model.canEditQuestionnaire(recording), "Queued housekeeping must release the model before fixture cleanup")
        }
        try await exerciseFixture()
    }

    func testCaptureFinalizationReleasesNextSessionBeforeAnyNetworkRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        @MainActor func exerciseFixture() async throws {
            let store = try WoonaStore(rootDirectory: directory)
            var animal = DogQuestionnaire(); animal.schemaVersion = 2; animal.animalId = "finalize-fixture"; animal.numberOrName = "Synthetic finalize animal"
            let profile = try store.saveProfile(animal)
            try store.markProfileAccepted(dogID: profile.id, versionID: profile.profileVersionID)
            var networkObserved = false
            var captureStarted = false
            weak var observedModel: AppViewModel?
            let model = AppViewModel(store: store, uiTesting: true, syncClientFactory: { _ in
                guard captureStarted else { throw WoonaStoreError.invalidData("Synthetic startup retirement probe; no capture exists yet") }
                let owner = try XCTUnwrap(observedModel)
                XCTAssertNil(owner.activeRecording, "Capture must already be durable before upload")
                XCTAssertTrue(owner.canStartNewSession, "Network latency must not keep capture finalization busy")
                networkObserved = true
                throw WoonaStoreError.invalidData("Synthetic network stop after checking durable completion")
            })
            observedModel = model
            model.serverToken = "fixture"; model.serverWifiOnly = false
            model.updateTransferNetworkPath(available: true, unmetered: true)
            try await waitUntil("startup queue to finish") { model.canChangeAccount }
            // Invalid replay also has to finalize locally and upload its diagnostics.
            // The test uses no camera, Bluetooth device or real network.
            let source = directory.appendingPathComponent("empty-replay.bin")
            try Data().write(to: source)
            var questionnaire = SessionQuestionnaire(); questionnaire.schemaVersion = 2
            questionnaire.sessionLabel = "Finalize ordering"; questionnaire.plannedActivities = ["Покой"]; questionnaire.videoRequested = false
            try model.startReplay(from: source, questionnaire: questionnaire)
            captureStarted = true
            let recording = try XCTUnwrap(model.activeRecording)
            try await waitUntil("upload to start after local finalization", timeout: 15) { networkObserved }
            XCTAssertTrue(networkObserved, "status=\(model.statusText), error=\(model.errorMessage ?? "none"), active=\(model.activeRecording?.id.uuidString ?? "none")")
            try await waitUntil("owned upload housekeeping to finish") { model.canChangeAccount }
            XCTAssertTrue(["failed", "interrupted", "completed"].contains(try XCTUnwrap(store.recording(id: recording.id)).status))
            XCTAssertTrue(model.canStartNewSession)
        }
        try await exerciseFixture()
    }

    func testHeartCapturePromptOwnsFreshFinalizedRecordAndDoesNotReopenAfterDismissal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try WoonaStore(rootDirectory: root)
        let profile = try makeHeartPromptProfile(store, name: "owner")
        let old = try makeOldHeartPromptRecord(store, profile: profile)
        let model = AppViewModel(store: store, uiTesting: true)
        defer { cleanupHeartPromptFixture(root, model: model) }
        try await waitUntil("initial heart history") { !model.isHistoryLoading }
        XCTAssertNil(model.pendingPostCaptureHeartQuestionnaire)
        XCTAssertNil(model.heartQuestionnairePresentation)
        let id = try beginHeartPromptReplay(model, root: root, label: "New owned heart")
        try await waitForHeartPromptLocalIdle(model)
        let fresh = try XCTUnwrap(store.recording(id: id))
        XCTAssertTrue(["completed", "failed", "interrupted"].contains(fresh.status))
        XCTAssertEqual(fresh.questionnaire?.readyForSync, false)
        XCTAssertEqual(model.pendingPostCaptureHeartQuestionnaire?.id, id)
        XCTAssertNotEqual(id, old.id)
        var updatedAnimal = profile.questionnaire
        updatedAnimal.numberOrName = "Updated animal while heart prompt is pending"
        try model.saveDogProfile(updatedAnimal, replacing: profile)
        try await waitForHeartPromptLocalIdle(model)
        XCTAssertEqual(model.selectedDogProfile?.id, profile.id)
        XCTAssertNotEqual(model.selectedDogProfile?.profileVersionID, fresh.profileVersionID)
        XCTAssertEqual(model.pendingPostCaptureHeartQuestionnaire?.id, id)
        XCTAssertEqual(model.pendingPostCaptureHeartQuestionnaire?.profileVersionID, fresh.profileVersionID, "The capture owns its immutable version even when the selected animal has a newer version")
        model.presentPendingHeartQuestionnaire()
        XCTAssertEqual(model.heartQuestionnairePresentation?.id, id)
        XCTAssertEqual(model.heartQuestionnairePresentation?.profileVersionID, fresh.profileVersionID)
        XCTAssertNil(model.pendingPostCaptureHeartQuestionnaire)
        model.presentPendingHeartQuestionnaire()
        XCTAssertEqual(model.heartQuestionnairePresentation?.id, id)
        model.dismissHeartQuestionnaire()
        model.stopActiveCapture() // A duplicate stop callback has no new event owner.
        model.refreshRecordingHistory()
        try await waitForHeartPromptLocalIdle(model)
        model.presentPendingHeartQuestionnaire()
        XCTAssertNil(model.pendingPostCaptureHeartQuestionnaire)
        XCTAssertNil(model.heartQuestionnairePresentation)
        XCTAssertEqual(try store.recording(id: old.id)?.questionnaire?.readyForSync, false)
        try await waitUntil("owned heart queue release") { model.canChangeAccount }
    }

    func testHeartCapturePromptClearsPresentedAndQueuedOwnersOnScopeChange() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try WoonaStore(rootDirectory: root)
        let first = try makeHeartPromptProfile(store, name: "scope-a")
        let second = try makeHeartPromptProfile(store, name: "scope-b")
        let model = AppViewModel(store: store, uiTesting: true)
        defer { cleanupHeartPromptFixture(root, model: model) }
        try await waitUntil("scope fixture startup") { !model.isHistoryLoading && model.canChangeAccount }
        model.selectDogProfile(first)
        let firstID = try beginHeartPromptReplay(model, root: root, label: "First scope heart")
        try await waitForHeartPromptLocalIdle(model)
        model.presentPendingHeartQuestionnaire()
        XCTAssertEqual(model.heartQuestionnairePresentation?.id, firstID)
        model.selectDogProfile(second)
        XCTAssertNil(model.heartQuestionnairePresentation)
        XCTAssertNil(model.pendingPostCaptureHeartQuestionnaire)
        try await waitUntil("second animal history") { !model.isHistoryLoading }
        model.selectDogProfile(first)
        let secondID = try beginHeartPromptReplay(model, root: root, label: "Queued account heart")
        try await waitForHeartPromptLocalIdle(model)
        XCTAssertEqual(model.pendingPostCaptureHeartQuestionnaire?.id, secondID)
        try await waitUntil("account operation availability") { model.canChangeAccount }
        model.accountInput = "heart-other-workspace"; model.applyAccount()
        XCTAssertEqual(model.selectedAccountID, "heart-other-workspace")
        XCTAssertNil(model.pendingPostCaptureHeartQuestionnaire)
        XCTAssertNil(model.heartQuestionnairePresentation)
        model.presentHeartQuestionnaire(for: try XCTUnwrap(store.recording(id: secondID)))
        XCTAssertNil(model.heartQuestionnairePresentation)
        try await waitUntil("changed account history") { !model.isHistoryLoading && model.canChangeAccount }
    }

    func testHeartPresenterRechecksCompletedAnswersAndManualOpeningUsesFreshRecord() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try WoonaStore(rootDirectory: root)
        _ = try makeHeartPromptProfile(store, name: "fresh")
        let model = AppViewModel(store: store, uiTesting: true)
        defer { cleanupHeartPromptFixture(root, model: model) }
        try await waitUntil("fresh fixture startup") { !model.isHistoryLoading }
        let id = try beginHeartPromptReplay(model, root: root, label: "Completed before presentation")
        try await waitForHeartPromptLocalIdle(model)
        let displayed = try XCTUnwrap(store.recording(id: id))
        let answers = validUnknownHeartAnswers()
        try store.saveHeartQuestionnaire(recordingID: id, heart: answers)
        model.presentPendingHeartQuestionnaire()
        XCTAssertNil(model.pendingPostCaptureHeartQuestionnaire)
        XCTAssertNil(model.heartQuestionnairePresentation, "A now-complete form must not be opened from a stale pending snapshot")
        try await waitUntil("fresh manual editor availability") { model.canChangeAccount }
        model.presentHeartQuestionnaire(for: displayed)
        XCTAssertEqual(model.heartQuestionnairePresentation?.questionnaire?.heartQuestionnaire, answers)
        model.dismissHeartQuestionnaire()
        model.refreshRecordingHistory()
        try await waitForHeartPromptLocalIdle(model)
        XCTAssertNil(model.heartQuestionnairePresentation)
    }

    func testRetiredHeartCaptureNeverPromptsIncludingDeferredRetirementSQLFailure() async throws {
        for failRetirement in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let store = try WoonaStore(rootDirectory: root)
            let profile = try makeHeartPromptProfile(store, name: "retired")
            let old = try makeOldHeartPromptRecord(store, profile: profile)
            let model = AppViewModel(store: store, uiTesting: true)
            defer { cleanupHeartPromptFixture(root, model: model) }
            try await waitUntil("retirement fixture startup") { !model.isHistoryLoading }
            if failRetirement {
                try executeHeartPromptSQL(root, "CREATE TRIGGER fail_heart_retirement BEFORE DELETE ON recordings BEGIN SELECT RAISE(ABORT, 'Injected heart retirement failure'); END")
            }
            let id = try beginHeartPromptReplay(model, root: root, label: "Retired capture")
            let marker = ServerDeletion(kind: "recording", id_sha256: WoonaStore.sha256(Data(id.uuidString.lowercased().utf8)))
            _ = try store.applyServerDeletions([marker])
            XCTAssertNotNil(try store.recording(id: id), "Active capture is deferred until safe finalization")
            try await waitForHeartPromptLocalIdle(model)
            XCTAssertNil(model.pendingPostCaptureHeartQuestionnaire)
            model.presentPendingHeartQuestionnaire()
            XCTAssertNil(model.heartQuestionnairePresentation)
            if failRetirement {
                let retained = try XCTUnwrap(store.recording(id: id), "The failed retirement transaction must preserve its durable recording")
                XCTAssertTrue(model.errorMessage?.contains("Injected heart retirement failure") == true)
                try await waitUntil("retired row manual eligibility fence settled") { model.canChangeAccount }
                XCTAssertTrue(model.canEditQuestionnaire(retained), "This refusal must come from the exact retirement marker, not an unrelated busy gate")
                let originalError = model.errorMessage
                let artifacts = try store.artifacts(recordingID: id)
                let originalHashes = try artifacts.map { try WoonaStore.sha256File(root.appendingPathComponent($0.relativePath)) }
                model.presentHeartQuestionnaire(for: retained)
                XCTAssertNil(model.heartQuestionnairePresentation)
                XCTAssertEqual(model.errorMessage, originalError, "The specific cleanup failure remains visible after manual refusal")
                XCTAssertEqual(try store.recording(id: id), retained)
                XCTAssertEqual(try artifacts.map { try WoonaStore.sha256File(root.appendingPathComponent($0.relativePath)) }, originalHashes)
                try executeHeartPromptSQL(root, "DROP TRIGGER fail_heart_retirement")
                _ = try store.applyDeferredServerDeletions()
            }
            XCTAssertNil(try store.recording(id: id))
            XCTAssertNotNil(try store.recording(id: old.id), "No unrelated old incomplete heart may be substituted")
            model.refreshRecordingHistory()
            try await waitUntil("retirement fixture queue release") { !model.isHistoryLoading && model.canChangeAccount }
        }
    }

    func testHeartPromptWaitsForDurableFinalizationAndFailedWriteCanBeRetried() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try WoonaStore(rootDirectory: root)
        _ = try makeHeartPromptProfile(store, name: "failed-finalizer")
        try executeHeartPromptSQL(root, "CREATE TRIGGER fail_heart_finalization BEFORE UPDATE OF status ON recordings WHEN NEW.status IN ('completed','failed','interrupted') BEGIN SELECT RAISE(ABORT, 'Injected heart finalization failure'); END")
        let model = AppViewModel(store: store, uiTesting: true)
        defer { cleanupHeartPromptFixture(root, model: model) }
        try await waitUntil("failed finalizer fixture startup") { !model.isHistoryLoading }
        let id = try beginHeartPromptReplay(model, root: root, label: "Retry finalization")
        try await waitUntil("explicit durable finalization failure", timeout: 15) {
            model.errorMessage?.contains("Injected heart finalization failure") == true
        }
        XCTAssertNotNil(model.activeRecording)
        XCTAssertNil(model.pendingPostCaptureHeartQuestionnaire)
        XCTAssertNil(model.heartQuestionnairePresentation)
        XCTAssertTrue(["preparing", "recording"].contains(try XCTUnwrap(store.recording(id: id)).status))
        try executeHeartPromptSQL(root, "DROP TRIGGER fail_heart_finalization")
        model.stopActiveCapture(status: "interrupted")
        try await waitForHeartPromptLocalIdle(model)
        XCTAssertEqual(model.pendingPostCaptureHeartQuestionnaire?.id, id)
        XCTAssertEqual(try store.recording(id: id)?.status, "interrupted")
        model.dismissHeartQuestionnaire()
        try await waitUntil("retried finalizer queue release") { model.canChangeAccount }
    }

    func testNewHeartPromptAndLocalSaveDoNotWaitForUnrelatedPendingNetworkWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try WoonaStore(rootDirectory: root)
        let profile = try makeHeartPromptProfile(store, name: "held-network")
        try store.markProfileAccepted(dogID: profile.id, versionID: profile.profileVersionID)
        let host = UUID().uuidString.lowercased() + ".heart-prompt.test"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeartPromptHoldingProtocol.self]
        defer { HeartPromptHoldingProtocol.release(host) }
        let client = try WoonaServerClient(configuration: ServerConfiguration(baseURL: "https://" + host, wifiOnly: false), token: "synthetic", sessionConfiguration: configuration)
        let model = AppViewModel(store: store, uiTesting: true, syncClientFactory: { _ in client })
        defer { cleanupHeartPromptFixture(root, model: model) }
        model.serverBaseURL = "https://" + host; model.serverToken = "synthetic"; model.serverWifiOnly = false
        model.updateTransferNetworkPath(available: true, unmetered: true)
        var capturedError: Error?
        do {
            try await waitUntil("unrelated queued network request actually started", timeout: 5) { HeartPromptHoldingProtocol.hasStarted(host) }
            XCTAssertFalse(model.canChangeAccount)
            let id = try beginHeartPromptReplay(model, root: root, label: "Heart while network is held")
            try await waitForHeartPromptLocalIdle(model)
            XCTAssertTrue(HeartPromptHoldingProtocol.activeCount(host) > 0)
            XCTAssertTrue(model.canPresentPendingHeartQuestionnaire, "Unrelated queued networking cannot prevent local post-capture editing")
            model.presentPendingHeartQuestionnaire()
            let displayed = try XCTUnwrap(model.heartQuestionnairePresentation)
            XCTAssertEqual(displayed.id, id)
            try await model.saveHeartQuestionnaire(validUnknownHeartAnswers(), displayedRecording: displayed)
            XCTAssertEqual(try store.recording(id: id)?.questionnaire?.readyForSync, true)
            XCTAssertFalse(model.canEditQuestionnaire(displayed), "The target's own queued or running transfer remains fenced")
        } catch { capturedError = error }
        model.serverToken = ""
        HeartPromptHoldingProtocol.release(host)
        try await waitUntil("all owned network and history work released", timeout: 5) {
            model.canChangeAccount && !model.isHistoryLoading && HeartPromptHoldingProtocol.activeCount(host) == 0
        }
        model.dismissHeartQuestionnaire()
        if let capturedError { throw capturedError }
    }

    func testCaptureFinalizationRunsFileWorkOffMainActorAndLeavesMainActorResponsive() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WoonaStore(rootDirectory: root)
        var animal = DogQuestionnaire(); animal.schemaVersion = 2; animal.animalId = "worker-fixture"; animal.numberOrName = "Synthetic worker animal"
        let profile = try store.saveProfile(animal)
        var answers = SessionQuestionnaire(); answers.schemaVersion = 2; answers.sessionLabel = "Off-main finalization"; answers.plannedActivities = ["Покой"]
        let recording = try store.createRecording(profile: profile, source: "live", questionnaire: answers)
        let source = root.appendingPathComponent("capture.bin")
        try Data(repeating: 0x5a, count: 1024 * 1024).write(to: source)
        let started = expectation(description: "worker started")
        let release = DispatchSemaphore(value: 0)
        let operation = Task {
            try await CaptureFinalizer.run(root: root, recordingID: recording.id, status: "completed",
                files: [("packet", source, "packets.bin", "application/octet-stream")], syncJSON: Data("{}".utf8), onWorkerStart: {
                    XCTAssertFalse(Thread.isMainThread)
                    started.fulfill()
                    _ = release.wait(timeout: .now() + 10)
                })
        }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertTrue(Thread.isMainThread, "The main actor must remain available while the worker is paused")
        XCTAssertEqual(try store.recording(id: recording.id)?.status, "preparing")
        release.signal()
        _ = try await operation.value
        XCTAssertEqual(try store.recording(id: recording.id)?.status, "completed")
        let packet = try XCTUnwrap(store.artifacts(recordingID: recording.id).first { $0.type == "packet" })
        XCTAssertEqual(try WoonaStore.sha256File(root.appendingPathComponent(packet.relativePath)), packet.sha256)
    }

    func testCaptureFinalizationBackgroundTimeEndsExactlyOnceAndIgnoresAnOldExpiration() async throws {
        var expires: (() -> Void)?
        var starts = 0, ended = 0, cancelled = 0
        let lease = CaptureFinalizationBackgroundTime(enabled: true, begin: { callback in
            starts += 1; expires = callback
            return UIBackgroundTaskIdentifier(rawValue: starts)
        }, end: { _ in ended += 1 })
        lease.begin { cancelled += 1 }
        lease.begin { cancelled += 1 }
        XCTAssertEqual(starts, 1)
        let staleExpiration = expires
        lease.end(); lease.end()
        XCTAssertEqual(ended, 1)
        lease.begin { cancelled += 1 }
        staleExpiration?()
        await Task.yield()
        XCTAssertEqual(cancelled, 0)
        expires?()
        try await waitUntil("finite background expiration") { cancelled == 1 }
        lease.end()
        XCTAssertEqual(ended, 2)
    }

    func testSessionExportAvailabilityUsesLocalFilesAfterRestartDownloadAndRemoval() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        @MainActor func exerciseFixture() async throws {
            let store = try WoonaStore(rootDirectory: directory)
            var animal = DogQuestionnaire(); animal.schemaVersion = 2; animal.animalId = "export-fixture"; animal.numberOrName = "Synthetic export animal"
            let profile = try store.saveProfile(animal)
            var questionnaire = SessionQuestionnaire(); questionnaire.schemaVersion = 2; questionnaire.sessionLabel = "Raw-only session"; questionnaire.plannedActivities = ["Покой"]; questionnaire.videoRequested = false
            let recording = try store.createRecording(profile: profile, source: "replay", questionnaire: questionnaire)
            let raw = store.directory(for: recording).appendingPathComponent("raw_fragments.binlog")
            try Data("synthetic raw bytes".utf8).write(to: raw)
            try store.finalize(recording: recording, status: "failed", files: [("raw", raw, "raw_fragments.binlog", "application/octet-stream")], syncJSON: Data("{}".utf8))
            let model = AppViewModel(store: store, uiTesting: true)
            await model.refreshExportAvailability()
            XCTAssertEqual(model.packetsReceived, 0, "Historical files need no current packet counters")
            XCTAssertTrue(model.canOpenSessionExport)
            XCTAssertTrue(model.canExportSessionFile(.all))
            XCTAssertTrue(model.canExportSessionFile(.rawFragments))
            XCTAssertFalse(model.canExportSessionFile(.packetDump))
            XCTAssertFalse(model.canExportSessionFile(.channelCsv))
            for file in try store.artifacts(recordingID: recording.id) {
                try FileManager.default.removeItem(at: directory.appendingPathComponent(file.relativePath))
            }
            await model.refreshExportAvailability()
            XCTAssertFalse(model.canOpenSessionExport, "Stale DB artifact metadata cannot enable an empty export")
            XCTAssertTrue(model.availableSessionExportKinds.isEmpty)
            // A successfully downloaded file may exist without new sensor packets.
            try Data("synthetic raw bytes".utf8).write(to: raw)
            await model.refreshExportAvailability()
            XCTAssertTrue(model.canExportSessionFile(.rawFragments))
            XCTAssertTrue(model.canExportSessionFile(.all))
            var second = animal; second.animalId = "other-export-animal"; second.numberOrName = "No local sessions"
            let other = try store.saveProfile(second)
            model.selectDogProfile(other)
            await model.refreshExportAvailability()
            XCTAssertFalse(model.canOpenSessionExport, "Changing the animal must invalidate the previous files")
            model.selectDogProfile(profile)
            await model.refreshExportAvailability()
            XCTAssertTrue(model.canExportSessionFile(.rawFragments))
        }
        try await exerciseFixture()
    }

    func testApplyingAccountWithoutServerFiltersLocalDogs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WoonaStore(rootDirectory: directory)
        var questionnaire = DogQuestionnaire()
        questionnaire.schemaVersion = 2
        questionnaire.animalId = "local-1"
        questionnaire.numberOrName = "Local dog"
        questionnaire.species = "собака"
        let dog = try store.saveProfile(questionnaire)
        let model = AppViewModel(store: store, uiTesting: true)
        XCTAssertEqual(model.selectedDogProfile?.id, dog.id)
        model.accountInput = "operator-1"
        model.applyAccount()
        XCTAssertEqual(model.selectedAccountID, "operator-1")
        XCTAssertTrue(model.dogProfiles.isEmpty)
        XCTAssertEqual(model.unassignedDogProfiles.map(\.id), [dog.id])
        model.accountInput = ""
        model.applyAccount()
        XCTAssertEqual(model.selectedDogProfile?.id, dog.id)
    }

    func testFirstEditAfterReloadPreservesProfileAndUpdatesExistingDog() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var questionnaire = DogQuestionnaire()
        questionnaire.schemaVersion = 2
        questionnaire.animalId = "martin-1"
        questionnaire.numberOrName = "Мартин"
        questionnaire.species = "собака"
        let original: DogProfile
        do {
            let store = try WoonaStore(rootDirectory: directory)
            original = try store.saveProfile(questionnaire)
        }

        let store = try WoonaStore(rootDirectory: directory)
        let restored = try XCTUnwrap(store.profiles().first)
        let presentation = DogProfileEditorPresentation(profile: restored)
        var draft = try XCTUnwrap(presentation.profile?.questionnaire)
        XCTAssertEqual(draft, questionnaire)
        draft.numberOrName = "Мартин Тест"

        let saved = try store.saveProfile(draft, replacing: presentation.profile)
        XCTAssertEqual(saved.id, original.id)
        XCTAssertNotEqual(saved.profileVersionID, original.profileVersionID)
        XCTAssertEqual(saved.numberOrName, "Мартин Тест")
        XCTAssertEqual(try store.profiles().count, 1)
        XCTAssertEqual(try store.profile(dogID: original.id, versionID: original.profileVersionID)?.questionnaire, questionnaire)
    }

    func testNewAfterEditCreatesAnotherDogWithoutReplacingExistingProfile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try WoonaStore(rootDirectory: directory)
        var questionnaire = DogQuestionnaire()
        questionnaire.schemaVersion = 2
        questionnaire.animalId = "martin-1"
        questionnaire.numberOrName = "Мартин"
        questionnaire.species = "собака"
        let original = try store.saveProfile(questionnaire)
        var presentation: DogProfileEditorPresentation? = DogProfileEditorPresentation(profile: original)
        let editID = try XCTUnwrap(presentation?.id)
        presentation = nil
        presentation = DogProfileEditorPresentation(profile: nil)
        let newPresentation = try XCTUnwrap(presentation)
        XCTAssertNotEqual(newPresentation.id, editID)
        XCTAssertNil(newPresentation.profile)
        questionnaire.animalId = "finnik-1"
        questionnaire.numberOrName = "Финик"

        let created = try store.saveProfile(questionnaire, replacing: newPresentation.profile)
        XCTAssertNotEqual(created.id, original.id)
        XCTAssertEqual(try store.profiles().count, 2)
        XCTAssertEqual(try store.profile(dogID: original.id, versionID: original.profileVersionID), original)
    }

    func testIdentityConflictParsesCodeAndPreservesOther409Errors() throws {
        for body in [#"{"code":"animal_id_already_exists","dogId":"unavailable"}"#,
                     #"{"detail":{"code":"animal_id_already_exists"}}"#] {
            guard case .animalIDConflict = ServerSyncError.responseError(status: 409, data: Data(body.utf8)) else {
                return XCTFail("Identity conflict must provide recovery guidance")
            }
        }
        let body = Data(#"{"code":"revision_conflict","message":"Reload revision"}"#.utf8)
        guard case .requestFailed(let status, let message) = ServerSyncError.responseError(status: 409, data: body) else {
            return XCTFail("Revision conflicts must retain their own recovery path")
        }
        XCTAssertEqual(status, 409)
        XCTAssertEqual(message, "revision_conflict: Reload revision")
        guard case .requestFailed(500, _) = ServerSyncError.responseError(status: 500,
                data: Data(#"{"code":"animal_id_already_exists"}"#.utf8)) else {
            return XCTFail("Server failures must not be treated as identity conflicts")
        }
    }

    func testServerQueueDoesNotTreatNoPendingWorkAsServerHealth() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppViewModel(store: try WoonaStore(rootDirectory: root), uiTesting: true)
        model.serverToken = "synthetic-test-only"
        XCTAssertTrue(model.uploadQueueExplanation.contains("does not verify server"))
        XCTAssertTrue(model.uploadQueueExplanation.contains("Label Studio"))
        XCTAssertEqual(model.connectionCheck, "not_checked")
    }

    func testOldServerTransferStatusRemainsReadable() throws {
        let value = try JSONDecoder().decode(ServerTransferStatus.self, from: Data(#"{"ingestStatus":"uploading"}"#.utf8))
        XCTAssertEqual(value.ingestStatus, "uploading")
        XCTAssertNil(value.transfer)
        XCTAssertNil(value.labeling)
        XCTAssertFalse(value.confirmsCurrentServerCopy)
    }

    func testMetadataReceiptDoesNotPermitRemovalWithoutCurrentFileVerification() throws {
        let data = Data(#"{"ingestStatus":"complete","transfer":{"status":"verified","totalBytes":1,"uploadedBytes":1,"verifiedBytes":1,"totalFiles":1,"verifiedFiles":1,"receiptVerified":true,"retryable":false,"nextAction":"none"},"artifacts":[{"id":"11111111-1111-1111-1111-111111111111","fileName":"packets.bin","storageStatus":"available","verified":false,"sizeBytes":1,"uploadedBytes":1,"nextAction":"none"}]}"#.utf8)
        let value = try JSONDecoder().decode(ServerTransferStatus.self, from: data)
        XCTAssertFalse(value.confirmsCurrentServerCopy)
    }

    func testV2PreviewUsesExistingChartControlsAndRetainsRawIntegerTimesAcrossUpdatesAndNavigation() throws {
        let model = AppViewModel(store: nil, uiTesting: true)
        let base: UInt64 = 9_007_199_254_741_000
        model.installSyntheticV2ChartFixtureForTesting(timestampBaseUs: base)
        XCTAssertEqual(model.chartSensors.map { $0.type }, Array(2...8))
        XCTAssertEqual(model.chart.latestPointMillis, (base + 200_000_000) / 1000)
        XCTAssertLessThanOrEqual(model.chart.points.count, 1200)
        model.selectSensorType(3); model.selectChannel(2); model.selectChartWindow(.sixtySeconds)
        model.panChartLeft(); model.zoomChartIn()
        XCTAssertFalse(model.chart.isFollowingLive)
        XCTAssertTrue(model.chart.canPanRight); XCTAssertTrue(model.chart.canZoomOut)
        let end = model.chart.viewportEndMillis
        model.selectedTab = .settings; model.selectedTab = .session
        model.showingSessionCharts = true
        model.installV2PreviewSnapshotForTesting(model.v2Preview.snapshot)
        XCTAssertEqual(model.selectedSensorType, 3); XCTAssertEqual(model.selectedChannel, 2)
        XCTAssertEqual(model.chart.windowPreset, .sixtySeconds); XCTAssertEqual(model.chart.viewportEndMillis, end)
        XCTAssertFalse(model.chart.isFollowingLive); XCTAssertTrue(model.chart.canZoomOut)
        model.selectSensorType(8)
        XCTAssertEqual(model.selectedChannel, 1)
        XCTAssertFalse(model.chart.points.isEmpty)
        model.jumpToLive(); model.resetChartY()
        XCTAssertTrue(model.chart.isFollowingLive); XCTAssertFalse(model.chart.canZoomOut)
        XCTAssertFalse(model.canOpenSessionExport, "Preview controls never offer a false recording export")
    }

    // These shell/chart/packet tests do not use the recording database. Keep
    // persistent SQLite, NWPathMonitor and automatic recovery out of their setup.
    func testInitialTabIsOverview() {
        let viewModel = AppViewModel(store: nil, uiTesting: true)

        XCTAssertEqual(viewModel.selectedTab, .overview)
    }

    func testCanSelectEachTopLevelTab() {
        let viewModel = AppViewModel(store: nil, uiTesting: true)

        for tab in [AppViewModel.AppTab.overview, .session, .video, .recordings, .settings] {
            viewModel.selectedTab = tab
            XCTAssertEqual(viewModel.selectedTab, tab)
        }

        viewModel.selectedTab = .settings
        XCTAssertEqual(viewModel.selectedTab, .settings)

        viewModel.selectedTab = .overview
        XCTAssertEqual(viewModel.selectedTab, .overview)
    }

    func testReplaySessionDoesNotMarkBleAsConnected() {
        let viewModel = AppViewModel(store: nil, uiTesting: true)

        viewModel.applyConnectionState(isConnected: true)
        viewModel.addFoundDevice(BleDevice(id: UUID(), name: "Woona Sensor"))
        XCTAssertTrue(viewModel.isConnected)
        XCTAssertTrue(viewModel.isConnectionActive)
        XCTAssertEqual(viewModel.foundDevices.count, 1)

        viewModel.startReplaySession()
        viewModel.applyConnectionState(isConnected: true)

        XCTAssertTrue(viewModel.isReplayRunning)
        XCTAssertFalse(viewModel.isConnected)
        XCTAssertFalse(viewModel.isConnectionActive)
        XCTAssertTrue(viewModel.foundDevices.isEmpty)
        XCTAssertEqual(viewModel.selectedTab, .session)
    }

    func testFoundDevicesDeduplicateByIdentifier() {
        let viewModel = AppViewModel(store: nil, uiTesting: true)
        let identifier = UUID()

        viewModel.addFoundDevice(BleDevice(id: identifier, name: "Original"))
        viewModel.addFoundDevice(BleDevice(id: identifier, name: "Updated"))

        XCTAssertEqual(viewModel.foundDevices, [BleDevice(id: identifier, name: "Updated")])
    }

    func testSettingsSelectionsUpdateState() {
        let viewModel = AppViewModel(store: nil, uiTesting: true)

        viewModel.selectedThemeMode = .dark
        viewModel.selectedLanguage = .russian

        XCTAssertEqual(viewModel.selectedTransportProfile, .iosManaged)
        XCTAssertEqual(viewModel.currentTransportProfileTitle, "iOS managed")
        XCTAssertEqual(viewModel.selectedThemeMode, .dark)
        XCTAssertEqual(viewModel.selectedLanguage, .russian)
    }

    func testRussianLocalizationResolverUpdatesVisibleShellText() {
        let viewModel = AppViewModel(store: nil, uiTesting: true)

        XCTAssertEqual(viewModel.text(.overview), "Overview")
        XCTAssertEqual(viewModel.text(.live), "Live")
        XCTAssertEqual(viewModel.title(for: .channelCsv), "Channel CSV")

        viewModel.selectedLanguage = .russian

        XCTAssertEqual(viewModel.text(.overview), "Обзор")
        XCTAssertEqual(viewModel.text(.settings), "Настройки")
        XCTAssertEqual(viewModel.text(.live), "Вживую")
        XCTAssertEqual(viewModel.title(for: .channelCsv), "CSV канала")
    }

    func testInvalidReplayFileDoesNotResetCurrentSession() async throws {
        let viewModel = AppViewModel(store: nil, uiTesting: true)
        let key = ChartStreamKey(sensorType: 2, channel: 1)
        let point = ChartPoint(timeMillis: 1_000, value: 12)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("woona-empty-replay-\(UUID().uuidString).bin")
        try Data().write(to: fileURL)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        viewModel.applyPacketUpdateForTesting(
            PacketProcessingUpdate(
                packetsReceived: 7,
                packetsLost: 1,
                packetsRejected: 2,
                timerRegressionRejects: 0,
                chartSamplesByStream: [key: [point]]
            )
        )

        viewModel.startReplay(from: fileURL)
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(viewModel.packetsReceived, 7)
        XCTAssertEqual(viewModel.packetsLost, 1)
        XCTAssertEqual(viewModel.packetsRejected, 2)
        XCTAssertEqual(viewModel.chart.points, [point])
        XCTAssertEqual(viewModel.errorMessage, PacketReplayMessage.emptyFile)
    }

    func testFinishCaptureProcessingDrainsAppQueuedBleFragments() async throws {
        let viewModel = AppViewModel(store: nil, uiTesting: true)
        let packet = makeTestPacket(
            counter: 10,
            timerMillis: 50,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 1, channelSamples: [[]])]
        )

        viewModel.submitPacketFragmentForTesting(packet)
        await viewModel.finishCaptureProcessingForTesting()

        let packetFileURL = await viewModel.currentPacketFileForTesting()
        let packetFile = try XCTUnwrap(packetFileURL)
        let writtenBytes = try [UInt8](Data(contentsOf: packetFile))
        XCTAssertEqual(Array(writtenBytes.suffix(packet.count)), packet)
    }

    func testFailedBleStateFinishesOpenCaptureProcessing() async throws {
        let viewModel = AppViewModel(store: nil, uiTesting: true)
        let packet = makeTestPacket(
            counter: 11,
            timerMillis: 55,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 1, channelSamples: [[]])]
        )

        await viewModel.beginCaptureDiagnosticsForTesting()
        viewModel.submitPacketFragmentForTesting(packet)

        try await waitUntil("capture output files to open") {
            await viewModel.hasOpenOutputFilesForTesting()
        }

        viewModel.applyBleStateForTesting(.failed)

        try await waitUntil("capture output files to close after BLE failure") {
            await !viewModel.hasOpenOutputFilesForTesting()
        }
        XCTAssertEqual(viewModel.statusText, "Error")
    }

    func testRestartingCaptureAfterFailureAcceptsNewFragments() async throws {
        let viewModel = AppViewModel(store: nil, uiTesting: true)
        let firstPacket = makeTestPacket(
            counter: 21,
            timerMillis: 100,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 1, channelSamples: [[1]])]
        )
        let secondPacket = makeTestPacket(
            counter: 22,
            timerMillis: 200,
            measurementCount: 1,
            blocks: [makeSensorBlock(sensorType: 1, channelSamples: [[2]])]
        )

        await viewModel.beginCaptureDiagnosticsForTesting()
        viewModel.submitPacketFragmentForTesting(firstPacket)
        try await waitUntil("first capture output files to open") {
            await viewModel.hasOpenOutputFilesForTesting()
        }

        viewModel.applyBleStateForTesting(.failed)
        await viewModel.beginCaptureDiagnosticsForTesting()
        viewModel.submitPacketFragmentForTesting(secondPacket)
        await viewModel.finishCaptureProcessingForTesting()

        let packetFileURL = await viewModel.currentPacketFileForTesting()
        let packetFile = try XCTUnwrap(packetFileURL)
        let writtenBytes = try [UInt8](Data(contentsOf: packetFile))
        XCTAssertEqual(Array(writtenBytes.suffix(secondPacket.count)), secondPacket)
    }

    func testChartSelectionPanZoomAndReset() {
        let viewModel = AppViewModel(store: nil, uiTesting: true)
        let key = ChartStreamKey(sensorType: 2, channel: 1)
        let points = (0..<2_000).map { index in
            ChartPoint(timeMillis: UInt64(index * 1_000), value: Float(index % 200) - 100)
        }

        viewModel.applyPacketUpdateForTesting(
            PacketProcessingUpdate(
                packetsReceived: 1,
                packetsLost: 0,
                packetsRejected: 0,
                timerRegressionRejects: 0,
                chartSamplesByStream: [key: points]
            )
        )

        XCTAssertEqual(viewModel.chart.windowPreset, .thirtySeconds)
        XCTAssertLessThanOrEqual(viewModel.chart.points.count, 1_200)
        XCTAssertTrue(viewModel.chart.isFollowingLive)

        viewModel.selectChartWindow(.sixtySeconds)
        XCTAssertEqual(viewModel.chart.windowPreset, .sixtySeconds)

        viewModel.panChartLeft()
        XCTAssertFalse(viewModel.chart.isFollowingLive)
        XCTAssertTrue(viewModel.chart.canPanRight)
        for _ in 0..<100 where viewModel.chart.canPanLeft {
            viewModel.panChartLeft()
        }
        XCTAssertNotNil(viewModel.chart.viewportStartMillis)
        XCTAssertNotNil(viewModel.chart.viewportEndMillis)
        XCTAssertLessThan(viewModel.chart.viewportStartMillis!, viewModel.chart.viewportEndMillis!)
        XCTAssertEqual(viewModel.chart.viewportStartMillis, viewModel.chart.sessionStartMillis)

        viewModel.zoomChartIn()
        XCTAssertLessThan(viewModel.chart.yAxisAbsRange, 32_768)
        XCTAssertTrue(viewModel.chart.canZoomOut)

        viewModel.resetChartY()
        XCTAssertEqual(viewModel.chart.yAxisAbsRange, 32_768)
        XCTAssertFalse(viewModel.chart.canZoomOut)

        viewModel.selectSensorType(3)
        XCTAssertEqual(viewModel.selectedSensorType, 3)
        XCTAssertEqual(viewModel.selectedChannel, 1)
    }

    func testChartStateRetainsRecentHighVolumeDataOnly() {
        let viewModel = AppViewModel(store: nil, uiTesting: true)
        let key = ChartStreamKey(sensorType: 2, channel: 1)
        let points = (0..<100_000).map { index in
            ChartPoint(timeMillis: UInt64(index * 20), value: Float(index % 512) - 256)
        }

        viewModel.applyPacketUpdateForTesting(
            PacketProcessingUpdate(
                packetsReceived: 1,
                packetsLost: 0,
                packetsRejected: 0,
                timerRegressionRejects: 0,
                chartSamplesByStream: [key: points]
            )
        )

        XCTAssertLessThanOrEqual(viewModel.chart.points.count, 1_200)
        XCTAssertEqual(viewModel.chart.windowPreset, .thirtySeconds)
        XCTAssertEqual(viewModel.chart.latestPointMillis, 1_999_980)
        XCTAssertEqual(viewModel.chart.sessionStartMillis, 1_099_980)
        XCTAssertEqual(viewModel.chart.viewportStartMillis, 1_969_980)
        XCTAssertEqual(viewModel.chart.viewportEndMillis, 1_999_980)
    }
    private func cleanupHeartPromptFixture(_ root: URL, model: AppViewModel) {
        guard model.activeRecording == nil, model.canChangeAccount, !model.isHistoryLoading, model.canStartNewSession else {
            NSLog("Synthetic heart fixture retained because owned work has not finished: %@", root.lastPathComponent)
            return
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func makeHeartPromptProfile(_ store: WoonaStore, name: String) throws -> DogProfile {
        var questionnaire = DogQuestionnaire()
        questionnaire.schemaVersion = 2; questionnaire.animalId = "heart-" + name; questionnaire.numberOrName = name
        return try store.saveProfile(questionnaire)
    }

    private func makeOldHeartPromptRecord(_ store: WoonaStore, profile: DogProfile) throws -> WoonaRecording {
        var questionnaire = SessionQuestionnaire()
        questionnaire.schemaVersion = 2; questionnaire.sessionKind = "heart"; questionnaire.sessionLabel = "Old incomplete heart"; questionnaire.videoRequested = false
        let recording = try store.createRecording(profile: profile, source: "live", questionnaire: questionnaire)
        try store.finalize(recording: recording, status: "completed", files: [], syncJSON: Data("{}".utf8))
        return try XCTUnwrap(store.recording(id: recording.id))
    }

    private func beginHeartPromptReplay(_ model: AppViewModel, root: URL, label: String) throws -> UUID {
        let source = root.appendingPathComponent("empty-heart-" + UUID().uuidString + ".bin")
        try Data().write(to: source)
        var questionnaire = SessionQuestionnaire()
        questionnaire.schemaVersion = 2; questionnaire.sessionKind = "heart"; questionnaire.sessionLabel = label; questionnaire.videoRequested = false
        try model.startReplay(from: source, questionnaire: questionnaire)
        return try XCTUnwrap(model.activeRecording).id
    }

    private func waitForHeartPromptLocalIdle(_ model: AppViewModel) async throws {
        try await waitUntil("durable heart finalization and owned history", timeout: 15) {
            model.activeRecording == nil && model.canStartNewSession && !model.isHistoryLoading &&
                (model.pendingPostCaptureHeartQuestionnaire == nil || model.canPresentPendingHeartQuestionnaire)
        }
    }

    private func validUnknownHeartAnswers() -> HeartQuestionnaire {
        func unknown(_ key: String) -> HeartAnswer { HeartQuestionnaire.options[key]!.first { $0.key == "unknown" }! }
        var heart = HeartQuestionnaire()
        heart.knownHeartCondition = unknown("knownHeartCondition")
        heart.heartRelevantMedication = unknown("heartRelevantMedication")
        heart.preRecordingState = unknown("preRecordingState")
        heart.actualActivity = unknown("actualActivity")
        heart.acuteHeartRateFactors = [unknown("acuteHeartRateFactors")]
        heart.referenceMethod = unknown("referenceMethod")
        return heart
    }

    private func executeHeartPromptSQL(_ root: URL, _ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent("woona.sqlite").path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw WoonaStoreError.invalidData("Synthetic heart SQL connection failed")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5_000)
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw WoonaStoreError.invalidData("Synthetic heart SQL statement failed")
        }
    }
}

private final class HeartPromptHoldingProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var started = Set<String>()
    nonisolated(unsafe) private static var active: [String: [ObjectIdentifier: HeartPromptHoldingProtocol]] = [:]
    nonisolated(unsafe) private static var released = Set<String>()

    static func hasStarted(_ host: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return started.contains(host)
    }

    static func activeCount(_ host: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return active[host]?.count ?? 0
    }

    static func release(_ host: String) {
        lock.lock()
        released.insert(host)
        let requests = active.removeValue(forKey: host).map { Array($0.values) } ?? []
        lock.unlock()
        for request in requests { request.client?.urlProtocol(request, didFailWithError: URLError(.cancelled)) }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".heart-prompt.test") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let host = request.url?.host else { return }
        Self.lock.lock()
        Self.started.insert(host)
        let alreadyReleased = Self.released.contains(host)
        if !alreadyReleased { Self.active[host, default: [:]][ObjectIdentifier(self)] = self }
        Self.lock.unlock()
        if alreadyReleased { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)) }
    }
    override func stopLoading() {
        guard let host = request.url?.host else { return }
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.active[host]?.removeValue(forKey: ObjectIdentifier(self))
        if Self.active[host]?.isEmpty == true { Self.active.removeValue(forKey: host) }
    }
}

private func waitUntil(
    _ description: String,
    timeout: TimeInterval = 1,
    condition: @escaping () async -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for \(description)")
}
