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

    func testHistoryExplainsCaptureFailureSeparatelyAndRemovalCanBeCancelled() {
        app.terminate()
        app.launchArguments += ["--ui-testing-history"]
        app.launch()
        XCTAssertTrue(app.textFields["account.input"].waitForExistence(timeout: 15))
        app.buttons["tab.recordings"].tap()
        let cause = app.staticTexts["Capture: interrupted — collar connection failed (GATT 8)"]
        for _ in 0..<4 {
            if cause.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(cause.exists)
        XCTAssertTrue(app.staticTexts["Upload: files confirmed by the server"].exists)
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
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
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
        XCTAssertLessThan(scan.frame.minY, replay.frame.minY)
        XCTAssertFalse(app.buttons["DISCONNECT"].exists)
    }

    func testFiveTabsPreserveSelectionAndSeparateFunctions() {
        let tabs = ["overview", "session", "video", "recordings", "settings"]
        for tab in tabs { XCTAssertTrue(app.buttons["tab." + tab].exists) }
        app.buttons["tab.video"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "No active video")).firstMatch.exists)
        XCTAssertFalse(app.textFields["account.input"].exists)
        app.buttons["tab.recordings"].tap()
        XCTAssertTrue(app.staticTexts["No recordings for this dog"].exists)
        app.buttons["tab.overview"].tap()
        app.buttons["dog.edit"].tap()
        XCTAssertEqual(app.textFields["dog.editor.name"].value as? String, "UI Dog 1")
    }

    func testFullscreenKeepsChartSelection() {
        app.buttons["tab.session"].tap()
        app.segmentedControls["session.section"].buttons["Charts"].tap()
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
}
