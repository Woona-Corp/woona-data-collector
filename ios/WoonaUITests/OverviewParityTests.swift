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
        app.tabBars.buttons["Settings"].tap()
        XCTAssertFalse(account.exists)
        app.tabBars.buttons["Overview"].tap()
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

    func testFullscreenKeepsChartSelection() {
        app.tabBars.buttons["Charts"].tap()
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
