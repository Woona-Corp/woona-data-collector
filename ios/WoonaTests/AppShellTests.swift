import XCTest
import SQLite3
@testable import Woona

@MainActor
final class AppShellTests: XCTestCase {
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
        XCTAssertTrue(recordingUploadErrorText("local_copy_changed", language: .russian).contains("Удаление отменено"))
        XCTAssertTrue(recordingUploadErrorText("Server token is missing", language: .russian).contains("токен"))
        XCTAssertEqual(recordingUploadErrorText("Unexpected future failure", language: .english), "Unexpected future failure")
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
        XCTAssertEqual(recordingDisplayTime("unknown", timeZone: zone), "unknown")
    }

    func testProfileDatabaseFailureIsThrownAndRetryKeepsOriginalDraft() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
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

    func testInitialTabIsOverview() {
        let viewModel = AppViewModel()

        XCTAssertEqual(viewModel.selectedTab, .overview)
    }

    func testCanSelectEachTopLevelTab() {
        let viewModel = AppViewModel()

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
        let viewModel = AppViewModel()

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
        let viewModel = AppViewModel()
        let identifier = UUID()

        viewModel.addFoundDevice(BleDevice(id: identifier, name: "Original"))
        viewModel.addFoundDevice(BleDevice(id: identifier, name: "Updated"))

        XCTAssertEqual(viewModel.foundDevices, [BleDevice(id: identifier, name: "Updated")])
    }

    func testSettingsSelectionsUpdateState() {
        let viewModel = AppViewModel()

        viewModel.selectedThemeMode = .dark
        viewModel.selectedLanguage = .russian

        XCTAssertEqual(viewModel.selectedTransportProfile, .iosManaged)
        XCTAssertEqual(viewModel.currentTransportProfileTitle, "iOS managed")
        XCTAssertEqual(viewModel.selectedThemeMode, .dark)
        XCTAssertEqual(viewModel.selectedLanguage, .russian)
    }

    func testRussianLocalizationResolverUpdatesVisibleShellText() {
        let viewModel = AppViewModel()

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
        let viewModel = AppViewModel()
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
        let viewModel = AppViewModel()
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
        let viewModel = AppViewModel()
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
        let viewModel = AppViewModel()
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
        let viewModel = AppViewModel()
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
        let viewModel = AppViewModel()
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
