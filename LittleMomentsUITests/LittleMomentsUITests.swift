import XCTest

final class LittleMomentsUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(); app.launchArguments = ["--uitesting"]
    }
    override func tearDownWithError() throws {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        app.terminate()
    }
    private func launch() {
        app.launch(); XCTAssertTrue(app.buttons["bufferButton"].waitForExistence(timeout: 10))
    }
    private func reveal(_ element: XCUIElement) {
        for _ in 0..<5 { if element.isHittable { return }; app.swipeUp() }
    }
    private func start() {
        let button = app.buttons["bufferButton"]; reveal(button); button.tap()
        let active = NSPredicate(format: "label == %@", "Stop Buffer")
        expectation(for: active, evaluatedWith: button)
        waitForExpectations(timeout: 20)
    }
    func testLaunchAndDurationSelection() {
        launch()
        XCTAssertTrue(app.staticTexts["Little Moments"].exists)
        let picker = app.segmentedControls["durationPicker"]; reveal(picker)
        picker.buttons["15s"].tap(); XCTAssertTrue(picker.buttons["15s"].isSelected)
        picker.buttons["120s"].tap(); XCTAssertTrue(picker.buttons["120s"].isSelected)
        XCTAssertEqual(app.buttons["bufferButton"].label, "Start Buffer")
    }
    func testStartAndStop() {
        launch(); start()
        app.buttons["bufferButton"].tap()
        XCTAssertEqual(app.buttons["bufferButton"].label, "Start Buffer")
        XCTAssertFalse(app.buttons["saveButton"].isEnabled)
    }
    func testSavePlaybackDeleteAndNavigation() {
        launch(); start()
        let save = app.buttons["saveButton"]; reveal(save)
        XCTAssertTrue(save.isEnabled); save.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(app.alerts.staticTexts["Moment saved to your library."].exists)
        app.alerts.buttons["OK"].tap()
        let library = app.buttons["libraryButton"]
        for _ in 0..<5 { if library.isHittable { break }; app.swipeDown() }
        library.tap()
        XCTAssertTrue(app.buttons["clipRow"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["clipRow"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10)); app.buttons["Done"].tap()
        app.buttons["deleteClip"].firstMatch.tap(); app.buttons["Delete Moment"].tap()
        XCTAssertFalse(app.buttons["clipRow"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["bufferButton"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["bufferButton"].label, "Start Buffer")
    }
    func testPermissionDenied() {
        app.launchArguments.append("--deny-camera"); launch()
        let button = app.buttons["bufferButton"]; reveal(button); button.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10)); app.alerts.buttons["OK"].tap()
        let settings = app.buttons["settingsButton"]; reveal(settings); XCTAssertTrue(settings.exists)
        XCTAssertFalse(app.buttons["saveButton"].isEnabled)
    }
    func testBackgroundPausesUntilExplicitRestart() {
        launch(); start()
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["bufferButton"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["bufferButton"].label, "Start Buffer")
        XCTAssertFalse(app.buttons["saveButton"].isEnabled)
        start()
    }
}
