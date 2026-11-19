import AVKit
import XCTest
import UIKit
@testable import LittleMoments

@MainActor final class CapturePressRouterTests: XCTestCase {
    func testOneSaveOnReleaseAndRapidCompletePresses() {
        let router = CapturePressRouter()
        var saves = 0
        router.update(enabled: true, canSave: { true }, save: { saves += 1 })
        let handler = router.makeHandler()
        for expected in 1...5 {
            handler(.began); XCTAssertEqual(saves, expected - 1)
            handler(.ended); XCTAssertEqual(saves, expected)
            handler(.ended); XCTAssertEqual(saves, expected)
        }
    }
    func testLongPressAndCancellationDoNotDuplicateOrSave() {
        let router = CapturePressRouter()
        var saves = 0
        router.update(enabled: true, canSave: { true }, save: { saves += 1 })
        let handler = router.makeHandler()
        handler(.began); handler(.began); handler(.began)
        XCTAssertEqual(saves, 0)
        handler(.ended); XCTAssertEqual(saves, 1)
        handler(.began); handler(.cancelled); handler(.ended)
        XCTAssertEqual(saves, 1)
    }
    func testReadinessMustHoldAtBothBeginningAndRelease() {
        let router = CapturePressRouter()
        var ready = false, saves = 0
        router.update(enabled: true, canSave: { ready }, save: { saves += 1 })
        let handler = router.makeHandler()
        handler(.ended) // A release without a beginning is never a save.
        handler(.began); ready = true; handler(.began); handler(.ended)
        XCTAssertEqual(saves, 0) // A repeated began cannot arm a rejected press.
        handler(.began); ready = false; handler(.ended)
        XCTAssertEqual(saves, 0)
        ready = true; handler(.began); handler(.ended)
        XCTAssertEqual(saves, 1)
    }
    func testDisableReenableRejectsOldCallbacksEvenDuringNewPress() {
        let router = CapturePressRouter()
        var saves = 0
        router.update(enabled: true, canSave: { true }, save: { saves += 1 })
        let old = router.makeHandler()
        old(.began)
        router.update(enabled: false, canSave: { true }, save: { saves += 1 })
        old(.ended)
        router.update(enabled: true, canSave: { true }, save: { saves += 1 })
        let current = router.makeHandler()
        current(.ended); old(.began); old(.ended)
        XCTAssertEqual(saves, 0)
        current(.began); old(.ended); old(.cancelled)
        XCTAssertEqual(saves, 0)
        current(.ended); XCTAssertEqual(saves, 1)
    }
    func testUpdatingCallbacksUsesLatestSaveAndGuardWithoutDroppingPress() {
        let router = CapturePressRouter()
        var oldSaves = 0, newSaves = 0, ready = true
        router.update(enabled: true, canSave: { true }, save: { oldSaves += 1 })
        let handler = router.makeHandler()
        handler(.began)
        router.update(enabled: true, canSave: { ready }, save: { newSaves += 1 })
        handler(.ended)
        XCTAssertEqual(oldSaves, 0); XCTAssertEqual(newSaves, 1)
        handler(.began); ready = false; handler(.ended)
        XCTAssertEqual(newSaves, 1)
    }
    func testDismantleInvalidatesRetainedHandlerAndReentrantRelease() {
        let router = CapturePressRouter()
        var saves = 0
        var handler: (@MainActor (CapturePressRouter.Phase) -> Void)?
        router.update(enabled: true, canSave: { true }, save: {
            saves += 1; handler?(.ended)
        })
        handler = router.makeHandler()
        handler?(.began); handler?(.ended)
        XCTAssertEqual(saves, 1)
        handler?(.began); router.invalidate(); handler?(.ended)
        handler?(.began); handler?(.ended)
        XCTAssertEqual(saves, 1)
        handler = nil
    }
    func testEveryHardwareAvailabilityGateIsRequired() {
        XCTAssertTrue(HardwareSaveAvailability.allows(testing: false, foreground: true,
            cameraScreenVisible: true, canSave: true, sessionRunning: true))
        for blockedGate in 0..<5 {
            XCTAssertFalse(HardwareSaveAvailability.allows(testing: blockedGate == 0,
                foreground: blockedGate != 1, cameraScreenVisible: blockedGate != 2,
                canSave: blockedGate != 3, sessionRunning: blockedGate != 4))
        }
    }
    func testHostPassesTouchesThroughAndRemovesDisabledInteraction() throws {
        let view = CaptureButtonPassthroughView(frame: CGRect(x: 0, y: 0, width: 320, height: 640))
        XCTAssertTrue(view.isUserInteractionEnabled)
        XCTAssertFalse(view.point(inside: CGPoint(x: 100, y: 100), with: nil))
        if #available(iOS 17.2, *) {
            let unrelatedInteraction = UIPointerInteraction(delegate: nil)
            view.addInteraction(unrelatedInteraction)
            // UIKit can install supporting interactions alongside the capture interaction.
            // Assert the host's ownership by type and identity, not the view's total count.
            let captureInteractions = {
                view.interactions.compactMap { $0 as? AVCaptureEventInteraction }
            }
            let coordinator = CaptureButtonHost.Coordinator()
            coordinator.update(view, enabled: true, canSave: { true }, save: {})
            XCTAssertEqual(captureInteractions().count, 1)
            let initialInteraction = try XCTUnwrap(captureInteractions().first)
            XCTAssertTrue(initialInteraction.isEnabled)
            XCTAssertTrue(initialInteraction.view === view)
            XCTAssertNil(view.hitTest(CGPoint(x: 100, y: 100), with: nil))
            coordinator.update(view, enabled: true, canSave: { true }, save: {})
            XCTAssertEqual(captureInteractions().count, 1)
            XCTAssertTrue(captureInteractions().first === initialInteraction)
            coordinator.update(view, enabled: false, canSave: { false }, save: {})
            XCTAssertTrue(captureInteractions().isEmpty)
            XCTAssertFalse(initialInteraction.isEnabled)
            XCTAssertNil(initialInteraction.view)
            XCTAssertTrue(view.interactions.contains { $0 === unrelatedInteraction })
            coordinator.update(view, enabled: true, canSave: { true }, save: {})
            XCTAssertEqual(captureInteractions().count, 1)
            let reenabledInteraction = try XCTUnwrap(captureInteractions().first)
            XCTAssertFalse(reenabledInteraction === initialInteraction)
            XCTAssertTrue(reenabledInteraction.isEnabled)
            XCTAssertTrue(reenabledInteraction.view === view)
            XCTAssertNil(view.hitTest(CGPoint(x: 100, y: 100), with: nil))
            coordinator.dismantle(view)
            XCTAssertTrue(captureInteractions().isEmpty)
            XCTAssertFalse(reenabledInteraction.isEnabled)
            XCTAssertNil(reenabledInteraction.view)
            XCTAssertTrue(view.interactions.contains { $0 === unrelatedInteraction })
        }
    }
}
