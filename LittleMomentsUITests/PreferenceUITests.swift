import XCTest

final class PreferenceUITests: XCTestCase {
    func testRelaunchRetainsOnlyChoicesAndResetLaunchIsIndependent() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // A unique disposable domain keeps this test independent of order and other test classes.
        let suite = "org.littlemoments.UITests." + UUID().uuidString
        let arguments = ["--uitesting", "--uitest-preferences-suite=" + suite]
        app.launchArguments = arguments + ["--reset-uitest-preferences"]
        app.launch()
        defer {
            app.terminate()
            app.launchArguments = arguments + ["--reset-uitest-preferences"]
            app.launch(); app.terminate()
        }
        XCTAssertTrue(app.buttons["bufferButton"].waitForExistence(timeout: 10))
        let picker = app.segmentedControls["durationPicker"]
        reveal(picker, in: app)
        XCTAssertTrue(picker.buttons["30s"].isSelected)
        picker.buttons["60s"].tap()
        let audio = app.buttons["audioToggle"]
        reveal(audio, in: app)
        XCTAssertEqual(audio.value as? String, "On")
        audio.tap()
        let camera = app.buttons["switchCameraButton"]
        reveal(camera, in: app); camera.tap()
        XCTAssertEqual(camera.value as? String, "Front")
        let start = app.buttons["bufferButton"]
        reveal(start, in: app); start.tap()
        expectation(for: NSPredicate(format: "label == %@", "Stop Buffer"), evaluatedWith: start)
        waitForExpectations(timeout: 20)

        app.terminate()
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertEqual(start.label, "Start Buffer")
        XCTAssertFalse(app.buttons["saveButton"].isEnabled)
        reveal(picker, in: app)
        XCTAssertTrue(picker.buttons["60s"].isSelected)
        reveal(audio, in: app)
        XCTAssertEqual(audio.value as? String, "Off")
        XCTAssertEqual(camera.value as? String, "Front")

        app.terminate()
        app.launchArguments = arguments + ["--reset-uitest-preferences"]
        app.launch()
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        reveal(picker, in: app)
        XCTAssertTrue(picker.buttons["30s"].isSelected)
        reveal(audio, in: app)
        XCTAssertEqual(audio.value as? String, "On")
        XCTAssertEqual(camera.value as? String, "Rear")
        XCTAssertEqual(start.label, "Start Buffer")
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
