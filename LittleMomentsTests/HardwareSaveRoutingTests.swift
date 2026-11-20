import AVFoundation
import XCTest
@testable import LittleMoments

private final class HardwareRoutingCamera: CameraService {
    var session: AVCaptureSession? { nil }
    var onStatistics: ((CameraStatistics) -> Void)?
    var onInterruption: ((String) -> Void)?
    var starts = 0, snapshots = 0
    var suspendStart = false
    var pendingStart: CheckedContinuation<Void, Never>?
    @MainActor func start(audio: Bool, front: Bool, duration: Double) async throws {
        starts += 1
        if suspendStart { await withCheckedContinuation { pendingStart = $0 } }
        onStatistics?(CameraStatistics(seconds: 2, bytes: 100))
    }
    func stop() async {}
    func snapshot() async throws -> BufferSnapshot {
        snapshots += 1
        return BufferSnapshot(token: UUID(), segments: [], end: 2, window: 30)
    }
    func release(_ snapshot: BufferSnapshot) async {}
}
@MainActor private final class HardwareRoutingSaver: MomentSaving {
    var calls = 0
    var pending: CheckedContinuation<Void, Never>?
    func save(_ snapshot: BufferSnapshot) async throws {
        calls += 1
        await withCheckedContinuation { pending = $0 }
    }
    func finish() { pending?.resume(); pending = nil }
}
@MainActor private final class SilentHardwareFeedback: SaveHaptics, SaveAnnouncing {
    func notify(_ outcome: SaveOutcome) {}
    func announce(_ text: String) {}
}

@MainActor final class HardwareSaveRoutingTests: XCTestCase {
    private func makeModel(_ camera: HardwareRoutingCamera, saver: HardwareRoutingSaver) -> CameraModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let feedback = SilentHardwareFeedback()
        return CameraModel(camera: camera, library: ClipLibrary(directory: directory),
            saver: saver, haptics: feedback, announcer: feedback)
    }
    private func waitUntil(_ condition: @escaping @MainActor () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Expected model transition", file: file, line: line)
    }
    private func makeRouter(for model: CameraModel) -> CapturePressRouter {
        let router = CapturePressRouter()
        // A running-session value is injected here; no test pretends a synthetic
        // camera can deliver physical button events. All model guards stay live.
        router.update(enabled: true, canSave: {
            HardwareSaveAvailability.allows(testing: model.testing, foreground: model.foreground,
                cameraScreenVisible: model.cameraScreenVisible, canSave: model.canSave, sessionRunning: true)
        }, save: { model.save() })
        return router
    }
    private func press(_ handler: @MainActor (CapturePressRouter.Phase) -> Void) {
        handler(.began); handler(.ended)
    }
    func testReadyRouteSavesOnceWhileRapidInputsCannotBypassSingleSaveGuard() async {
        let camera = HardwareRoutingCamera(), saver = HardwareRoutingSaver()
        let model = makeModel(camera, saver: saver)
        model.start(); await waitUntil { model.canSave }
        let router = makeRouter(for: model), handler = router.makeHandler()
        press(handler); press(handler); press(handler)
        await waitUntil { saver.pending != nil }
        XCTAssertTrue(model.saving); XCTAssertEqual(camera.snapshots, 1)
        XCTAssertEqual(saver.calls, 1); XCTAssertEqual(camera.starts, 1)
        saver.finish(); await waitUntil { !model.saving }
    }
    func testStoppedStartingAndEmptyRoutesNeverSaveOrStartCamera() async {
        let camera = HardwareRoutingCamera(), saver = HardwareRoutingSaver()
        let model = makeModel(camera, saver: saver)
        let router = makeRouter(for: model), handler = router.makeHandler()
        press(handler); XCTAssertEqual(camera.starts, 0); XCTAssertFalse(model.saving)
        camera.suspendStart = true; model.start()
        await waitUntil { camera.pendingStart != nil }
        press(handler); XCTAssertEqual(model.phase, .starting); XCTAssertFalse(model.saving)
        camera.pendingStart?.resume(); camera.pendingStart = nil
        await waitUntil { model.canSave }
        camera.onStatistics?(CameraStatistics(seconds: 0, bytes: 0))
        await waitUntil { model.seconds == 0 }
        press(handler)
        XCTAssertFalse(model.saving); XCTAssertEqual(camera.snapshots, 0)
        XCTAssertEqual(camera.starts, 1)
        XCTAssertFalse(model.hardwareSaveEnabled) // No real running AVCaptureSession.
    }
    func testStateChangesDuringPressRejectStopNavigationBackgroundAndInterruption() async {
        for change in 0..<4 {
            let camera = HardwareRoutingCamera(), saver = HardwareRoutingSaver()
            let model = makeModel(camera, saver: saver)
            model.start(); await waitUntil { model.canSave }
            let router = makeRouter(for: model), handler = router.makeHandler()
            handler(.began)
            switch change {
            case 0: model.stop()
            case 1: model.setCameraScreenVisible(false)
            case 2: model.setForeground(false)
            default:
                camera.onInterruption?("Interrupted")
                await waitUntil { model.phase == .paused }
            }
            handler(.ended); press(handler)
            XCTAssertFalse(model.saving); XCTAssertEqual(camera.snapshots, 0)
            XCTAssertEqual(saver.calls, 0); XCTAssertEqual(camera.starts, 1)
        }
    }
}
