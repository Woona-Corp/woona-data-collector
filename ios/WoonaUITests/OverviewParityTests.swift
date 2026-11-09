import XCTest

final class OverviewParityTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        if name.contains("testServerEditorLandscapeKeyboardKeepsDraftAndReachableActions") || name.contains("testIdentityAndRecordingGroupsReflowWithLargeTextInLandscape") {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        if name.contains("testV2PreviewKeepsTheSameChartSelectionWindowPanZoomAndFullscreenControls") {
            app.launchArguments.append("--ui-testing-v2-charts")
        }
        if name.contains("testSelectingDogDoesNotAutomaticallyOpenPreexistingHeartQuestionnaire") || name.contains("testNewHeartCaptureOpensOneQuestionnaireAndDismissalDoesNotReopenHistory") || name.contains("testIdentityAndRecordingGroupsReflowWithLargeTextInLandscape") {
            app.launchArguments.append("--ui-testing-preexisting-heart")
        }
        if name.contains("testNewHeartCaptureOpensOneQuestionnaireAndDismissalDoesNotReopenHistory") {
            app.launchArguments.append("--ui-testing-heart-capture")
        }
        app.launch()
        XCTAssertTrue(app.textFields["account.input"].waitForExistence(timeout: 15))
        // Running V2 intentionally locks animal actions; that scenario waits for
        // its own session/chart controls rather than requiring New to be enabled.
        if app.launchArguments.contains("--ui-testing-v2-charts") { return }
        // The account field can render before the animal controls are actionable.
        // Check the actual control instead of treating field existence as readiness.
        // At accessibility XXXL the animal actions are below the initial
        // viewport (CI: New dog y=1026 on an 874-point portrait screen).
        // Scrolling is required; waiting alone cannot make it hittable.
        for _ in 0..<12 where !app.buttons["dog.new"].isHittable { app.swipeUp() }
        let newDogReady = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let button = object as? XCUIElement else { return false }
                return button.exists && button.isEnabled && button.isHittable
            },
            object: app.buttons["dog.new"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [newDogReady], timeout: 15), .completed,
                       "New dog must become enabled and hittable after launch")
    }

    func testIdentityAndRecordingGroupsReflowWithLargeTextInLandscape() {
        defer { XCUIDevice.shared.orientation = .portrait }
        for _ in 0..<12 where !app.staticTexts["Data account"].isHittable { app.swipeDown() }
        XCTAssertTrue(app.staticTexts["Data account"].isHittable)
        XCTAssertTrue(app.buttons["account.apply"].exists)
        let dog = app.buttons["UI Dog 2"]
        for _ in 0..<12 where !dog.isHittable { app.swipeUp() }
        XCTAssertTrue(dog.isHittable)
        dog.tap()
        let identity = app.staticTexts["identity.status"]
        for _ in 0..<12 where !identity.isHittable { app.swipeUp() }
        XCTAssertTrue(identity.exists)
        XCTAssertTrue(identity.isHittable, "Identity status remains reachable at accessibility size")
        XCTAssertNotEqual(identity.label, "Server confirmed", "Synthetic local fixtures have no exact-version server receipt")
        attachScreen("Identity-LargeText-EnglishLight")
        app.buttons["tab.recordings"].tap()
        XCUIDevice.shared.orientation = .landscapeRight
        let capture = app.staticTexts["Local capture"].firstMatch
        XCTAssertTrue(revealOverviewElement(capture), "Local capture must be fully visible above the custom tabs")
        XCTAssertTrue(capture.isHittable)
        attachScreen("Recording-Capture-LargeText-Landscape-EnglishLight", fullDevice: true)
        let delivery = app.staticTexts["Server delivery"].firstMatch
        XCTAssertTrue(revealOverviewElement(delivery), "Server delivery must be fully visible above the custom tabs")
        XCTAssertTrue(delivery.isHittable)
        attachScreen("Recording-Delivery-LargeText-Landscape-EnglishLight", fullDevice: true)
        let share = app.buttons["Share session ZIP"].firstMatch
        XCTAssertTrue(revealOverviewElement(share), "Share must be fully visible above the custom tabs")
        XCTAssertTrue(share.isHittable, "Existing actions remain reachable after the grouped summaries at accessibility size")
        attachScreen("Recording-Groups-LargeText-Landscape-EnglishLight", fullDevice: true)
    }

    func testServerEditorLandscapeKeyboardKeepsDraftAndReachableActions() {
        defer { XCUIDevice.shared.orientation = .portrait }
        app.buttons["tab.settings"].tap()
        let configure = app.buttons["server.configure"]
        for _ in 0..<12 where !configure.isHittable { app.swipeUp() }
        XCTAssertTrue(configure.isHittable)
        configure.tap()
        let url = app.textFields["server.url"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.tap(); url.typeText("not-a-valid-server-url")
        let token = app.secureTextFields["server.token"]
        token.tap(); token.typeText("synthetic-memory-only-token")
        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(app.buttons["server.save"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Landscape actions must remain reachable with the software keyboard open")
        let editorApp: XCUIApplication = app
        let stableActions = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let window = editorApp.frame
            let keyboard = editorApp.keyboards.firstMatch.frame
            let save = editorApp.buttons["server.save"]
            let cancel = editorApp.buttons["server.cancel"]
            return window.width > window.height && keyboard.width > keyboard.height &&
                save.isHittable && cancel.isHittable &&
                window.contains(save.frame) && window.contains(cancel.frame) &&
                save.frame.maxY <= keyboard.minY && cancel.frame.maxY <= keyboard.minY
        }, object: nil)
        let stableResult = XCTWaiter.wait(for: [stableActions], timeout: 10)
        // App-cropped screenshots during rotation can be clipped/black. Preserve
        // the actual device frame and native hierarchy, not only click success.
        attachScreen("ServerEditor-Landscape-Keyboard-Draft", fullDevice: true)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "ServerEditor-Landscape-Keyboard-NativeBounds"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTAssertEqual(stableResult, .completed, "Both actions must be fully on-screen above the real landscape keyboard")
        XCTAssertTrue(app.buttons["server.save"].isHittable)
        XCTAssertTrue(app.buttons["server.cancel"].isHittable)
        XCTAssertGreaterThan(app.buttons["server.save"].frame.height, 20)
        XCTAssertEqual(url.value as? String, "not-a-valid-server-url")
        // Validation is local: malformed URL cannot persist or initiate requests.
        app.buttons["server.save"].tap()
        XCTAssertTrue(app.navigationBars["Server connection"].exists)
        XCTAssertEqual(url.value as? String, "not-a-valid-server-url")
        app.buttons["server.cancel"].tap()
        XCTAssertTrue(configure.waitForExistence(timeout: 5))
        configure.tap()
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        XCTAssertNotEqual(url.value as? String, "not-a-valid-server-url")
        app.buttons["server.cancel"].tap()
    }

    func testSelectingDogDoesNotAutomaticallyOpenPreexistingHeartQuestionnaire() {
        let otherDog = app.buttons["UI Dog 2"]
        XCTAssertTrue(otherDog.waitForExistence(timeout: 5))
        otherDog.tap()
        let automaticallyOpened = app.navigationBars["Activity and heart questionnaire"].waitForExistence(timeout: 5)
        attachScreen("PreexistingHeart-AfterAnimalSelection")
        XCTAssertFalse(automaticallyOpened, "Selecting an animal is history browsing, not a new capture-stop event; its preexisting incomplete-heart questionnaire must remain available for manual opening")
        app.buttons["tab.recordings"].tap()
        XCTAssertTrue(app.navigationBars["Recordings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Preexisting incomplete heart"].waitForExistence(timeout: 5), "The test must actually load the persisted old record")
        XCTAssertTrue(app.buttons["Complete heart questionnaire"].exists)
        XCTAssertFalse(app.navigationBars["Activity and heart questionnaire"].waitForExistence(timeout: 5), "Accepted history data must remain browsable without reopening its old questionnaire")
        app.buttons["Complete heart questionnaire"].tap()
        XCTAssertTrue(app.navigationBars["Activity and heart questionnaire"].waitForExistence(timeout: 5), "Manual editing remains available through the central presenter")
        app.buttons["Later"].tap()
        XCTAssertTrue(app.navigationBars["Recordings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Activity and heart questionnaire"].waitForExistence(timeout: 5))
    }

    func testNewHeartCaptureOpensOneQuestionnaireAndDismissalDoesNotReopenHistory() {
        app.buttons["UI Dog 2"].tap()
        let capture = app.buttons["heart.capture.fixture"]
        XCTAssertTrue(capture.waitForExistence(timeout: 5))
        capture.tap()
        XCTAssertTrue(app.navigationBars["Session questionnaire"].waitForExistence(timeout: 5))
        let heartbeat = app.segmentedControls.buttons["Heartbeat"]
        XCTAssertTrue(heartbeat.waitForExistence(timeout: 5))
        XCTAssertTrue(heartbeat.isEnabled && heartbeat.isHittable)
        heartbeat.tap()
        let number = app.textFields["Session number *"]
        XCTAssertTrue(number.waitForExistence(timeout: 5))
        number.tap(); number.typeText("314159")
        let proceed = app.buttons["Continue"]
        XCTAssertTrue(proceed.waitForExistence(timeout: 5))
        XCTAssertTrue(proceed.isEnabled && proceed.isHittable)
        proceed.tap()
        let editor = app.navigationBars["Activity and heart questionnaire"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15), "A newly finalized heart capture must open its own questionnaire")
        attachScreen("NewHeartCapture-PostFinalizationQuestionnaire")
        app.buttons["Later"].tap()
        XCTAssertTrue(app.navigationBars["Animals"].waitForExistence(timeout: 5), "Empty replay fails before entering Session; dismissing the questionnaire must preserve its Animals origin")
        XCTAssertTrue(app.buttons["tab.overview"].isSelected)
        app.buttons["tab.recordings"].tap()
        XCTAssertTrue(app.navigationBars["Recordings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["314159"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Preexisting incomplete heart"].exists)
        XCTAssertFalse(editor.waitForExistence(timeout: 5), "Dismissing the capture prompt must not reopen either old or new incomplete forms during history browsing")
    }

    func testEnglishLongDogFormPresentsTranslatedOptionsAndRetainsCanonicalAnswersAcrossLanguageChange() {
        app.buttons["dog.new"].tap()
        XCTAssertTrue(app.navigationBars["Dog questionnaire"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["ID and name are required. Leave unknown answers blank."].exists)
        let size = app.buttons["questionnaire.choice.Size"]
        XCTAssertTrue(size.waitForExistence(timeout: 5))
        size.tap(); app.buttons["Small"].tap()
        app.textFields["dog.editor.animalID"].tap(); app.textFields["dog.editor.animalID"].typeText("english-sheet-fixture")
        app.textFields["dog.editor.name"].tap(); app.textFields["dog.editor.name"].typeText("English fixture")
        app.buttons["dog.editor.save"].tap()
        XCTAssertTrue(app.buttons["dog.edit"].waitForExistence(timeout: 5))
        app.buttons["dog.edit"].tap()
        XCTAssertTrue(app.buttons["questionnaire.choice.Size"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["questionnaire.choice.Size"].label.contains("Small"))
        attachScreen("Questionnaire-English-CanonicalOption")
        app.buttons["dog.editor.cancel"].tap()
        app.buttons["tab.settings"].tap()
        let russian = app.buttons["language.ru"]
        if !russian.isHittable { app.swipeUp() }
        russian.tap()
        app.buttons["tab.overview"].tap()
        app.buttons["dog.edit"].tap()
        XCTAssertTrue(app.navigationBars["Анкета собаки"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["questionnaire.choice.Size"].label.contains("мелкий"), "Changing presentation language must not store the translated answer")
        attachScreen("Questionnaire-Russian-CanonicalOption")
        app.buttons["dog.editor.cancel"].tap()
    }

    func testV2PreviewKeepsTheSameChartSelectionWindowPanZoomAndFullscreenControls() {
        XCTAssertTrue(app.textFields["account.input"].waitForExistence(timeout: 15))
        app.buttons["tab.session"].tap()
        XCTAssertTrue(app.navigationBars["Session"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["tab.session"].isSelected)
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
        attachScreen("V2-Charts-Fullscreen-EnglishLight")
        app.buttons["chart.fullscreen.close"].tap()
        attachScreen("V2-Charts-EnglishLight")
        sensor.buttons["T2"].tap()
        XCTAssertTrue(app.segmentedControls["chart.channel"].buttons["Channel 1"].isSelected)
        XCTAssertFalse(app.segmentedControls["chart.channel"].buttons["Channel 2"].exists)
        XCTAssertFalse(app.navigationBars.buttons["Export"].isEnabled)
        attachScreen("V2-Charts-T2-EnglishLight")
    }

    func testV2PickerIsExplicitAndReturnsToRecordAfterClosingWithoutConnecting() {
        app.buttons["tab.session"].tap()
        XCTAssertTrue(app.navigationBars["Session"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["tab.session"].isSelected)
        let newConnection = app.buttons["devices.newConnection"]
        let connectionReady = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let button = object as? XCUIElement else { return false }
                return button.exists && button.isEnabled && button.isHittable
            },
            object: newConnection
        )
        XCTAssertEqual(XCTWaiter.wait(for: [connectionReady], timeout: 5), .completed)
        let readyState = XCTAttachment(string: app.debugDescription)
        readyState.name = "ConnectionPicker-Ready-BeforeTap-Hierarchy"
        readyState.lifetime = .keepAlways
        add(readyState)
        newConnection.tap()
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
        let details = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recording.error.")).firstMatch
        let rawCause = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "GATT status 8")).firstMatch
        XCTAssertFalse(rawCause.exists, "Raw capture diagnostics stay collapsed by default")
        for _ in 0..<4 where !details.isHittable { app.swipeUp() }
        XCTAssertTrue(details.isHittable)
        details.tap()
        XCTAssertTrue(rawCause.waitForExistence(timeout: 5), "Expanding recording details exposes the saved raw capture failure")
        let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "recording.removeLocal.")).firstMatch
        XCTAssertTrue(revealOverviewElement(remove, maxSwipes: 4),
                      "Remove must be fully visible above the custom navigation tabs before tapping")
        XCTAssertTrue(remove.isEnabled)
        XCTAssertTrue(remove.isHittable)
        XCTAssertLessThanOrEqual(remove.frame.maxY, app.buttons["tab.recordings"].frame.minY,
                                 "Remove must be visibly above the custom navigation tabs before tapping")
        attachScreen("Remove-local-action-visible-EnglishLight")
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
        XCTAssertTrue(["", "Name *"].contains(name.value as? String ?? "unexpected"))
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
        let readyState = XCTAttachment(string: app.debugDescription)
        readyState.name = "NewDog-Ready-BeforeTap-Hierarchy"
        readyState.lifetime = .keepAlways
        add(readyState)
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
        // TEMPORARY DIAGNOSTIC BRANCH ONLY: keep original assertions and one tap.
        defer {
            if (testRun?.failureCount ?? 0) > 0 {
                attachScreen("FiveTabs-failure-full-device", fullDevice: true)
                attachNavigationTrace("FiveTabs-failure-hierarchy")
            }
        }
        let tabs = ["overview", "session", "video", "recordings", "settings"]
        for tab in tabs { XCTAssertTrue(app.buttons["tab." + tab].exists) }
        XCTAssertFalse(app.navigationBars.buttons["Export"].exists)
        attachScreen("Animals-EnglishLight")
        attachNavigationTrace("FiveTabs-before-video-tap")
        app.buttons["tab.video"].tap()
        attachNavigationTrace("FiveTabs-after-video-tap")
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
    // App-wide swipes start over the custom tabs in landscape, so they do not
    // scroll history. Also, XCTest can call offscreen SwiftUI leaves hittable.
    // Use the real unobscured viewport for both the gesture and visibility check.
    private func revealOverviewElement(_ element: XCUIElement, maxSwipes: Int = 16) -> Bool {
        for attempt in 0...maxSwipes {
            let scroll = app.scrollViews.firstMatch
            let navigation = app.navigationBars.firstMatch
            let tabs = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "tab."))
            guard scroll.exists, navigation.exists, tabs.count == 5,
                  let tabsTop = tabs.allElementsBoundByIndex.map({ $0.frame.minY }).min() else { return false }
            let viewport = scroll.frame.intersection(app.frame).intersection(CGRect(
                x: app.frame.minX, y: navigation.frame.maxY,
                width: app.frame.width, height: max(0, tabsTop - navigation.frame.maxY)
            ))
            guard !viewport.isEmpty else { return false }
            if element.exists && element.isHittable && viewport.contains(element.frame) { return true }
            guard attempt < maxSwipes else { break }
            // Center the target with a bounded drag, not a flick. CI's default
            // 500pt/s release moved ~336pt in this 218pt landscape viewport,
            // repeatedly throwing the same heading above then below the screen.
            let maximumDrag = viewport.height * 0.6
            let offset = element.exists ? element.frame.midY - viewport.midY : maximumDrag
            let distance = min(abs(offset), maximumDrag)
            let startY = viewport.minY + viewport.height * (offset < 0 ? 0.2 : 0.8)
            let endY = startY + (offset < 0 ? distance : -distance)
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: viewport.midX, dy: startY))
            let end = origin.withOffset(CGVector(dx: viewport.midX, dy: endY))
            // Holding the finger at the destination stops inertial scrolling;
            // this is part of the gesture, not a delay/retry after releasing it.
            start.press(forDuration: 0, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        attachScreen("Overview-unreachable-element", fullDevice: true)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Overview-unreachable-element-native-bounds"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        return false
    }

    private func attachNavigationTrace(_ name: String) {
        var lines = ["WOONA_CI_NAV wall=\(Date().timeIntervalSince1970) uptime=\(ProcessInfo.processInfo.systemUptime) phase=\(name)"]
        print(lines[0])
        for tab in ["overview", "session", "video", "recordings", "settings"] {
            let button = app.buttons["tab." + tab]
            lines.append("tab=\(tab) exists=\(button.exists) selected=\(button.isSelected) enabled=\(button.isEnabled) hittable=\(button.isHittable) frame=\(button.frame)")
        }
        print("WOONA_CI_NAV wall=\(Date().timeIntervalSince1970) phase=\(name) fields.completed")
        lines.append(app.debugDescription)
        print("WOONA_CI_NAV wall=\(Date().timeIntervalSince1970) phase=\(name) hierarchy.completed")
        let attachment = XCTAttachment(string: lines.joined(separator: "\n"))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachScreen(_ name: String, fullDevice: Bool = false) {
        let screenshot = XCTAttachment(screenshot: fullDevice ? XCUIScreen.main.screenshot() : app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

}
