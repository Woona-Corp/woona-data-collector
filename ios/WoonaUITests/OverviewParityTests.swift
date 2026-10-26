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
        XCTAssertNotEqual(name.value as? String, "UI Dog 1")
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
        let scan = app.buttons["devices.scan"]
        for _ in 0..<4 {
            if scan.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(scan.isHittable)
        XCTAssertEqual(scan.label, "START SCAN")
        let replay = app.buttons["devices.replay"]
        XCTAssertTrue(replay.isHittable)
        XCTAssertLessThan(scan.frame.minY, replay.frame.minY)
        XCTAssertFalse(app.buttons["DISCONNECT"].exists)
    }

    func testFullscreenKeepsChartSelection() {
        app.buttons["tab.charts"].tap()
        app.segmentedControls.buttons["AXL"].tap()
        app.segmentedControls.buttons["Channel 2"].tap()
        app.buttons["chart.fullscreen.open"].tap()
        XCTAssertTrue(app.buttons["chart.fullscreen.close"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls.buttons["AXL"].isSelected)
        XCTAssertTrue(app.segmentedControls.buttons["Channel 2"].isSelected)
        app.buttons["chart.fullscreen.close"].tap()
        XCTAssertTrue(app.buttons["chart.fullscreen.open"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls.buttons["Channel 2"].isSelected)
    }
}
