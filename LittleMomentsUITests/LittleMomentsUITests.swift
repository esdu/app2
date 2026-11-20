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
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "Accessibility hierarchy"; tree.lifetime = .keepAlways; add(tree)
        app.terminate()
    }
    private func launch() {
        app.launch(); XCTAssertTrue(app.buttons["bufferButton"].waitForExistence(timeout: 10))
    }
    private func reveal(_ element: XCUIElement) {
        // isHittable can be true for a clipped button at the bottom of a small
        // screen. Keep the entire control away from system gesture areas.
        let viewport = app.frame.insetBy(dx: 0, dy: 44)
        for _ in 0..<5 {
            if element.isHittable && viewport.contains(element.frame) { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable && viewport.contains(element.frame),
                      "Control must be fully visible before tapping")
    }
    private func start() {
        let button = app.buttons["bufferButton"]; reveal(button)
        // A paused label can appear before foreground activation and the previous
        // stop have finished. A tap on a disabled control is silently ignored.
        let ready = NSPredicate(format: "enabled == true AND label == %@", "Start Buffer")
        expectation(for: ready, evaluatedWith: button)
        waitForExpectations(timeout: 20)
        button.tap()
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
        XCTAssertTrue(app.descendants(matching: .any)["saveStatus"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        let savedOnce = NSPredicate(format: "enabled == true")
        expectation(for: savedOnce, evaluatedWith: save); waitForExpectations(timeout: 30)
        reveal(save); save.tap()
        let libraryCount = app.buttons["libraryButton"]
        let savedTwice = NSPredicate(format: "value == %@", "2 saved")
        expectation(for: savedTwice, evaluatedWith: libraryCount); waitForExpectations(timeout: 30)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        let library = app.buttons["libraryButton"]
        for _ in 0..<5 { if library.isHittable { break }; app.swipeDown() }
        library.tap()
        XCTAssertTrue(app.buttons["clipRow"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons.matching(identifier: "clipRow").count, 2)
        app.buttons["clipRow"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10)); app.buttons["Done"].tap()
        app.buttons["deleteClip"].firstMatch.tap(); app.buttons["Delete Moment"].tap()
        XCTAssertEqual(app.buttons.matching(identifier: "clipRow").count, 1)
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
