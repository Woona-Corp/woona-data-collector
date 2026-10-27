import XCTest

final class OverviewParityTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.textFields["account.input"].waitForExistence(timeout: 15))
    }

    func testV2PreviewKeepsTheSameChartSelectionWindowPanZoomAndFullscreenControls() {
        app.terminate(); app.launchArguments += ["--ui-testing-v2-charts"]; app.launch()
        XCTAssertTrue(app.textFields["account.input"].waitForExistence(timeout: 15))
        app.buttons["tab.session"].tap()
        XCTAssertTrue(app.staticTexts["v2.stage"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Start session"].exists)
        attachScreen("V2-Session-EnglishLight")
        app.segmentedControls["session.section"].buttons["Charts"].tap()
        let sensor = app.segmentedControls["chart.sensor"]
        XCTAssertTrue(sensor.waitForExistence(timeout: 5))
        for title in ["AXL", "GIR", "MIC", "AMB", "PZ", "T1", "T2"] { XCTAssertTrue(sensor.buttons[title].exists) }
        sensor.buttons["GIR"].tap()
        app.segmentedControls["chart.channel"].buttons["Channel 2"].tap()
        app.segmentedControls["chart.window"].buttons["60s"].tap()
        XCTAssertTrue(app.buttons["chart.panLeft"].isEnabled); app.buttons["chart.panLeft"].tap()
        app.buttons["chart.zoomIn"].tap()
        XCTAssertTrue(app.buttons["chart.panRight"].isEnabled); XCTAssertTrue(app.buttons["chart.zoomOut"].isEnabled)
        app.buttons["chart.fullscreen.open"].tap()
        let fullscreen = app.otherElements["chart.fullscreen"]
        XCTAssertTrue(app.buttons["chart.fullscreen.close"].waitForExistence(timeout: 5))
        XCTAssertTrue(fullscreen.segmentedControls["chart.sensor"].buttons["GIR"].isSelected)
        XCTAssertTrue(fullscreen.segmentedControls["chart.channel"].buttons["Channel 2"].isSelected)
        XCTAssertTrue(fullscreen.segmentedControls["chart.window"].buttons["60s"].isSelected)
        app.buttons["chart.fullscreen.close"].tap()
        attachScreen("V2-Charts-EnglishLight")
        sensor.buttons["T2"].tap()
        XCTAssertTrue(app.segmentedControls["chart.channel"].buttons["Channel 1"].isSelected)
        XCTAssertFalse(app.segmentedControls["chart.channel"].buttons["Channel 2"].exists)
        XCTAssertFalse(app.navigationBars.buttons["Export"].isEnabled)
    }

    func testV2PickerIsExplicitAndReturnsToRecordAfterClosingWithoutConnecting() {
        app.buttons["tab.session"].tap()
        app.buttons["devices.newConnection"].tap()
        let purpose = app.segmentedControls["devices.purpose"]
        XCTAssertTrue(purpose.waitForExistence(timeout: 5))
        XCTAssertTrue(purpose.buttons["Record"].isSelected)
        XCTAssertTrue(app.buttons["devices.replay"].exists)
        purpose.buttons["V2 preview"].tap()
        XCTAssertTrue(purpose.buttons["V2 preview"].isSelected)
        XCTAssertTrue(app.staticTexts["A sensor test stream. Sessions and video are not saved or uploaded."].exists)
        XCTAssertTrue(app.staticTexts["Connect only to an idle sensor. With the current firmware, a Bluetooth disconnect can stop an SD-card recording."].exists)
        XCTAssertFalse(app.buttons["devices.replay"].exists)
        XCTAssertFalse(app.buttons["Start session"].exists)
        app.buttons["Close"].tap()
        app.buttons["devices.newConnection"].tap()
        XCTAssertTrue(purpose.waitForExistence(timeout: 5))
        XCTAssertTrue(purpose.buttons["Record"].isSelected)
        XCTAssertTrue(app.buttons["devices.replay"].exists)
        XCTAssertFalse(app.staticTexts["A sensor test stream. Sessions and video are not saved or uploaded."].exists)
        app.buttons["Close"].tap()
    }

    func testHistoryExplainsCaptureFailureSeparatelyAndRemovalCanBeCancelled() {
        app.terminate()
        app.launchArguments += ["--ui-testing-history"]
        app.launch()
        XCTAssertTrue(app.textFields["account.input"].waitForExistence(timeout: 15))
        app.buttons["tab.recordings"].tap()
        XCTAssertTrue(app.navigationBars["Recordings"].waitForExistence(timeout: 5), "The center of the Recordings tab must activate its full padded hit area")
        XCTAssertTrue(app.buttons["tab.recordings"].isSelected)
        let cause = app.staticTexts["Capture: interrupted — collar connection failed (GATT 8)"]
        for _ in 0..<4 {
            if cause.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(cause.exists)
        XCTAssertTrue(app.staticTexts["Upload: upload was confirmed; check the current server copy below"].exists)
        let details = app.buttons["Error details"]
        if !details.isHittable { app.swipeUp() }
        details.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "GATT status 8")).firstMatch.exists)
        let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recording.removeLocal.")).firstMatch
        for _ in 0..<4 {
            if remove.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(remove.isEnabled)
        remove.tap()
        let confirmation = app.alerts["Remove session files from this device?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
        XCTAssertTrue(confirmation.buttons["Remove from device"].exists)
        XCTAssertTrue(confirmation.buttons["Cancel"].exists)
        attachScreen("Remove-local-confirmation-EnglishLight")
        confirmation.buttons["Cancel"].tap()
        XCTAssertTrue(remove.exists)
        XCTAssertTrue(app.buttons["Share session ZIP"].isEnabled)
    }

    func testAccountPrecedesDogsAndStaysOnOverview() {
        let account = app.textFields["account.input"]
        let newDog = app.buttons["dog.new"]
        XCTAssertTrue(account.isHittable)
        XCTAssertTrue(newDog.isHittable)
        XCTAssertLessThan(account.frame.maxY, newDog.frame.minY)
        XCTAssertEqual(app.buttons["account.apply"].label, "Apply account")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Overview-account-and-dogs"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.buttons["tab.settings"].tap()
        XCTAssertFalse(account.exists)
        app.buttons["tab.overview"].tap()
        XCTAssertTrue(account.isHittable)
    }

    func testFirstEditNewAndReselectionUseCorrectProfile() {
        app.buttons["dog.edit"].tap()
        let name = app.textFields["dog.editor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "UI Dog 1")
        XCTAssertEqual(app.textFields["dog.editor.animalID"].value as? String, "ui-dog-1")
        app.buttons["dog.editor.cancel"].tap()
        app.buttons["dog.new"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        // Empty SwiftUI text fields expose their placeholder as their value.
        XCTAssertTrue(["", "Кличка *"].contains(name.value as? String ?? "unexpected"))
        XCTAssertNotEqual(app.textFields["dog.editor.animalID"].value as? String, "ui-dog-1")
        name.tap()
        name.typeText("New animal")
        app.buttons["dog.editor.cancel"].tap()
        app.buttons.matching(NSPredicate(format: "label == %@", "UI Dog 2")).firstMatch.tap()
        app.buttons["dog.edit"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "UI Dog 2")
        XCTAssertEqual(app.textFields["dog.editor.animalID"].value as? String, "ui-dog-2")
    }

    func testProfileSaveFailureKeepsEditorAndDraftUntilSuccessfulRetry() {
        app.terminate()
        app.launchArguments += ["--ui-testing-fail-profile-save"]
        app.launch()
        XCTAssertTrue(app.textFields["account.input"].waitForExistence(timeout: 15))
        app.buttons["dog.edit"].tap()
        let name = app.textFields["dog.editor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText(" retained")
        let draftName = name.value as? String
        app.buttons["dog.editor.save"].tap()
        XCTAssertTrue(app.staticTexts["dog.editor.saveError"].waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, draftName)
        XCTAssertTrue(app.buttons["dog.editor.save"].exists)
        XCTAssertFalse(app.buttons["dog.new"].isHittable)
        app.buttons["dog.editor.save"].tap()
        XCTAssertTrue(app.buttons["dog.new"].waitForExistence(timeout: 5))
        app.buttons["dog.edit"].tap()
        XCTAssertEqual(name.value as? String, draftName)
    }

    func testNewSavesSeparateDogAndKeepsExistingProfile() {
        app.buttons["dog.new"].tap()
        let id = app.textFields["dog.editor.animalID"]
        XCTAssertTrue(id.waitForExistence(timeout: 5))
        id.tap()
        id.typeText("ui-dog-3")
        let name = app.textFields["dog.editor.name"]
        name.tap()
        name.typeText("UI Dog 3")
        app.buttons["dog.editor.save"].tap()
        XCTAssertTrue(app.buttons["dog.new"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "UI Dog 3")).firstMatch.exists)
        app.buttons.matching(NSPredicate(format: "label == %@", "UI Dog 1")).firstMatch.tap()
        app.buttons["dog.edit"].tap()
        XCTAssertTrue(id.waitForExistence(timeout: 5))
        XCTAssertEqual(id.value as? String, "ui-dog-1")
        XCTAssertEqual(name.value as? String, "UI Dog 1")
    }

    func testRussianDarkOverviewHasSameActions() {
        app.terminate()
        app.launchArguments += ["--ui-language=ru", "--ui-theme=dark"]
        app.launch()
        XCTAssertTrue(app.textFields["account.input"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["account.apply"].label, "Применить аккаунт")
        XCTAssertEqual(app.buttons["dog.new"].label, "Новая собака")
        XCTAssertEqual(app.buttons["dog.edit"].label, "Изменить")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Overview-Russian-dark"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        for (tab, name) in [("overview", "Animals"), ("session", "Session"), ("video", "Video"), ("recordings", "Recordings"), ("settings", "Settings")] {
            app.buttons["tab." + tab].tap()
            attachScreen(name + "-RussianDark")
        }
    }

    func testLanguageChangeUpdatesNavigationAndThemeLabels() {
        app.buttons["tab.settings"].tap()
        let russian = app.buttons["language.ru"]
        if !russian.isHittable { app.swipeUp() }
        russian.tap()
        XCTAssertEqual(app.buttons["tab.overview"].label, "Животные")
        XCTAssertEqual(app.buttons["tab.settings"].label, "Настройки")
        if !app.segmentedControls.buttons["Светлая"].isHittable { app.swipeDown() }
        XCTAssertTrue(app.segmentedControls.buttons["Светлая"].isSelected)
        app.buttons["tab.overview"].tap()
        XCTAssertEqual(app.buttons["account.apply"].label, "Применить аккаунт")
    }

    func testServerConnectionRequiresTokenAndCancelDoesNotConfigure() {
        app.buttons["tab.settings"].tap()
        let configure = app.buttons["server.configure"]
        if !configure.isHittable { app.swipeUp() }
        configure.tap()
        XCTAssertTrue(app.textFields["server.url"].waitForExistence(timeout: 5))
        app.buttons["server.save"].tap()
        XCTAssertTrue(app.staticTexts["Enter token"].exists)
        app.buttons["server.cancel"].tap()
        XCTAssertTrue(configure.waitForExistence(timeout: 5))
        XCTAssertEqual(configure.label, "Connect")
    }

    func testIdleDiscoveryActionsAppearTogether() {
        app.buttons["tab.session"].tap()
        app.buttons["devices.newConnection"].tap()
        let scan = app.buttons["devices.scan"]
        let replay = app.buttons["devices.replay"]
        for _ in 0..<4 {
            if scan.isHittable && replay.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(scan.isHittable)
        XCTAssertEqual(scan.label, "START SCAN")
        XCTAssertTrue(replay.isHittable)
        XCTAssertEqual(replay.label, "Replay local file (debug)")
        XCTAssertLessThan(scan.frame.minY, replay.frame.minY)
        XCTAssertFalse(app.buttons["DISCONNECT"].exists)
    }

    func testFiveTabsPreserveSelectionAndSeparateFunctions() {
        let tabs = ["overview", "session", "video", "recordings", "settings"]
        for tab in tabs { XCTAssertTrue(app.buttons["tab." + tab].exists) }
        XCTAssertFalse(app.navigationBars.buttons["Export"].exists)
        attachScreen("Animals-EnglishLight")
        app.buttons["tab.video"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "No active video")).firstMatch.exists)
        XCTAssertFalse(app.textFields["account.input"].exists)
        XCTAssertFalse(app.navigationBars.buttons["Export"].exists)
        attachScreen("Video-EnglishLight")
        app.buttons["tab.recordings"].tap()
        XCTAssertTrue(app.staticTexts["No recordings for this dog"].exists)
        XCTAssertTrue(app.navigationBars.buttons["Export"].exists)
        XCTAssertFalse(app.navigationBars.buttons["Export"].isEnabled)
        attachScreen("Recordings-EnglishLight")
        app.buttons["tab.session"].tap()
        XCTAssertFalse(app.textFields["account.input"].exists)
        XCTAssertTrue(app.navigationBars.buttons["Export"].exists)
        XCTAssertFalse(app.navigationBars.buttons["Export"].isEnabled)
        XCTAssertTrue(app.navigationBars["Session"].exists)
        XCTAssertGreaterThanOrEqual(app.segmentedControls["session.section"].frame.minY, app.navigationBars["Session"].frame.maxY)
        attachScreen("Session-EnglishLight")
        app.buttons["tab.settings"].tap()
        XCTAssertTrue(app.buttons["server.configure"].exists)
        attachScreen("Settings-EnglishLight")
        app.buttons["tab.overview"].tap()
        app.buttons["dog.edit"].tap()
        XCTAssertEqual(app.textFields["dog.editor.name"].value as? String, "UI Dog 1")
    }

    func testFullscreenKeepsChartSelection() {
        app.buttons["tab.session"].tap()
        app.segmentedControls["session.section"].buttons["Charts"].tap()
        XCTAssertTrue(app.navigationBars["Session"].exists)
        XCTAssertTrue(app.navigationBars.buttons["Export"].exists)
        XCTAssertGreaterThanOrEqual(app.segmentedControls["session.section"].frame.minY, app.navigationBars["Session"].frame.maxY)
        app.segmentedControls.buttons["AXL"].tap()
        app.segmentedControls.buttons["Channel 2"].tap()
        app.buttons["chart.fullscreen.open"].tap()
        XCTAssertTrue(app.buttons["chart.fullscreen.close"].waitForExistence(timeout: 5))
        let fullscreen = app.otherElements["chart.fullscreen"]
        XCTAssertTrue(fullscreen.segmentedControls.buttons["AXL"].isSelected)
        XCTAssertTrue(fullscreen.segmentedControls.buttons["Channel 2"].isSelected)
        app.buttons["chart.fullscreen.close"].tap()
        XCTAssertTrue(app.buttons["chart.fullscreen.open"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls.buttons["Channel 2"].isSelected)
    }
    private func attachScreen(_ name: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

}
