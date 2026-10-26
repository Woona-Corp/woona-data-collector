import XCTest
@testable import Woona

@MainActor
final class AppShellTests: XCTestCase {
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

    func testInitialTabIsOverview() {
        let viewModel = AppViewModel()

        XCTAssertEqual(viewModel.selectedTab, .overview)
    }

    func testCanSelectEachTopLevelTab() {
        let viewModel = AppViewModel()

        viewModel.selectedTab = .charts
        XCTAssertEqual(viewModel.selectedTab, .charts)

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
        XCTAssertEqual(viewModel.selectedTab, .overview)
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
