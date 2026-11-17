import XCTest

final class ThermalUITests: XCTestCase {
    func testCriticalLaunchExplainsBlockedStart() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--thermal-critical"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["bufferButton"].waitForExistence(timeout: 10))
        let warning = app.staticTexts["thermalWarning"]
        reveal(warning, in: app)
        XCTAssertTrue(warning.label.contains("too hot"))
        XCTAssertTrue(warning.label.contains("Let it cool"))
        let start = app.buttons["bufferButton"]
        reveal(start, in: app)
        XCTAssertEqual(start.label, "Start Buffer")
        XCTAssertFalse(start.isEnabled)
        XCTAssertFalse(app.buttons["saveButton"].isEnabled)
    }

    func testSeriousLaunchWarnsWithoutClaimingQualityReduction() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--thermal-serious"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["bufferButton"].waitForExistence(timeout: 10))
        let warning = app.staticTexts["thermalWarning"]
        reveal(warning, in: app)
        XCTAssertTrue(warning.label.contains("Capture continues at the selected resolution"))
        let start = app.buttons["bufferButton"]
        reveal(start, in: app)
        XCTAssertEqual(start.label, "Start Buffer")
        XCTAssertTrue(start.isEnabled)
        XCTAssertFalse(app.buttons["saveButton"].isEnabled)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let viewport = app.frame.insetBy(dx: 0, dy: 44)
        for _ in 0..<5 {
            if element.isHittable && viewport.contains(element.frame) { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable && viewport.contains(element.frame))
    }
}
