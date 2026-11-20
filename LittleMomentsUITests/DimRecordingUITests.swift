import XCTest

final class DimRecordingUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(); app.launchArguments = ["--uitesting"]
    }
    override func tearDownWithError() throws {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.lifetime = .keepAlways; add(attachment)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Accessibility hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        app.terminate()
    }
    private func reveal(_ element: XCUIElement) {
        let viewport = app.frame.insetBy(dx: 0, dy: 44)
        for _ in 0..<8 {
            let frame = element.frame
            let hittable = element.isHittable
            print("Reveal \(element.identifier): frame=\(frame), hittable=\(hittable), viewport=\(viewport)")
            if hittable && viewport.contains(frame) { return }
            // A full upward swipe can skip a large-text control that was only
            // partially visible. Center it with a bounded drag, reversing when
            // it is above the viewport instead of scrolling farther past it.
            let limit = viewport.height * 0.45
            let distance = max(-limit, min(limit, frame.midY - viewport.midY))
            let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
            origin.press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: -distance)))
        }
        XCTAssertTrue(element.isHittable && viewport.contains(element.frame),
                      "Control must be fully visible and hittable: \(element.debugDescription); viewport=\(viewport)")
    }
    private func startAndDim() {
        app.launch()
        let start = app.buttons["bufferButton"]
        XCTAssertTrue(start.waitForExistence(timeout: 10)); reveal(start); start.tap()
        expectation(for: NSPredicate(format: "label == %@", "Stop Buffer"), evaluatedWith: start)
        waitForExpectations(timeout: 20)
        let dim = app.buttons["dimScreenButton"]; reveal(dim); XCTAssertTrue(dim.isEnabled); dim.tap()
        XCTAssertTrue(app.buttons["wakeScreenButton"].waitForExistence(timeout: 5))
    }
    func testDimTouchSaveAndWakeWithoutHardwareInput() {
        startAndDim()
        XCTAssertEqual(app.staticTexts["dimStatus"].label, "Buffering")
        XCTAssertTrue(app.staticTexts["dimReady"].exists)
        XCTAssertTrue(app.staticTexts["dimBattery"].exists)
        let save = app.buttons["dimSaveButton"]; reveal(save)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: save)
        waitForExpectations(timeout: 20); save.tap()
        XCTAssertTrue(app.staticTexts["dimSaveStatus"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["wakeScreenButton"].exists)
        let wake = app.buttons["wakeScreenButton"]; reveal(wake); wake.tap()
        XCTAssertFalse(app.buttons["wakeScreenButton"].exists)
        XCTAssertEqual(app.buttons["bufferButton"].label, "Stop Buffer")
    }
    func testBackgroundRestoresNormalUIAndPausedStatus() {
        startAndDim(); XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(app.buttons["bufferButton"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["wakeScreenButton"].exists)
        XCTAssertEqual(app.buttons["bufferButton"].label, "Start Buffer")
        XCTAssertEqual(app.staticTexts["bufferStatus"].label, "Paused · Tap Start to resume")
        XCTAssertFalse(app.buttons["dimScreenButton"].isEnabled)
    }
    func testAccessibleDimControlsAtLargestDynamicType() {
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        startAndDim()
        let save = app.buttons["dimSaveButton"]; reveal(save); XCTAssertTrue(save.isHittable)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: save)
        waitForExpectations(timeout: 20); save.tap()
        XCTAssertTrue(app.staticTexts["dimSaveStatus"].waitForExistence(timeout: 30))
        let wake = app.buttons["wakeScreenButton"]; reveal(wake); XCTAssertTrue(wake.isHittable)
        XCTAssertEqual(wake.label, "Wake screen"); wake.tap()
        XCTAssertFalse(app.buttons["wakeScreenButton"].exists)
        XCTAssertEqual(app.buttons["bufferButton"].label, "Stop Buffer")
    }
}
