import AVFoundation
import XCTest
@testable import LittleMoments

private final class ControlledCamera: CameraService {
    var session: AVCaptureSession? { nil }
    var onStatistics: ((CameraStatistics) -> Void)?
    var onInterruption: ((String) -> Void)?
    var permission = true
    var suspendStop = false
    var pendingStop: CheckedContinuation<Void, Never>?
    var onStop: (() -> Void)?
    var suspendStart = false
    var pendingStart: CheckedContinuation<Void, Never>?
    var onStart: (() -> Void)?
    var starts = 0
    var stops = 0
    @MainActor func start(audio: Bool, front: Bool, duration: Double) async throws {
        starts += 1
        if suspendStart { await withCheckedContinuation { c in pendingStart = c; onStart?() } }
        if !permission { throw CameraError.permission }
    }
    @MainActor func stop() async {
        stops += 1
        if suspendStop { await withCheckedContinuation { c in pendingStop = c; onStop?() } }
    }
    func snapshot() async throws -> BufferSnapshot { throw CameraError.empty }
    func release(_ snapshot: BufferSnapshot) async { }
}
@MainActor final class CameraModelTests: XCTestCase {
    private func makeModel(_ camera: ControlledCamera) -> CameraModel {
        CameraModel(camera: camera, library: ClipLibrary(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    }
    private func waitUntil(_ condition: @escaping @MainActor () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Expected asynchronous state transition", file: file, line: line)
    }
    func testLaunchDoesNotStartCamera() {
        let camera = ControlledCamera(); let model = makeModel(camera)
        XCTAssertEqual(camera.starts, 0); XCTAssertEqual(model.phase, .stopped)
    }
    func testDeniedCameraPermission() async {
        let camera = ControlledCamera(); camera.permission = false
        let model = makeModel(camera); model.start(); await waitUntil { !model.transitioning }
        XCTAssertEqual(model.phase, .denied); XCTAssertNotNil(model.message)
    }
    func testBackgroundPausesAndForegroundDoesNotResume() async {
        let camera = ControlledCamera(); let model = makeModel(camera)
        model.start(); await waitUntil { !model.transitioning }; XCTAssertEqual(model.phase, .buffering)
        model.setForeground(false); await waitUntil { !model.transitioning }; XCTAssertEqual(model.phase, .paused)
        model.setForeground(true); XCTAssertEqual(model.phase, .paused)
        XCTAssertEqual(camera.starts, 1); XCTAssertGreaterThanOrEqual(camera.stops, 1)
        model.start(); await waitUntil { !model.transitioning }; XCTAssertEqual(camera.starts, 2)
    }
    func testInterruptionRequiresExplicitRestart() async {
        let camera = ControlledCamera(); let model = makeModel(camera)
        model.start(); await waitUntil { !model.transitioning }; camera.onInterruption?("Interrupted")
        await waitUntil { model.phase == .paused }; XCTAssertEqual(camera.starts, 1)
    }
    func testBackgroundDuringStartupCannotActivateLater() async {
        let camera = ControlledCamera(); camera.suspendStart = true
        let model = makeModel(camera)
        let started = expectation(description: "Start is pending")
        camera.onStart = { started.fulfill() }
        model.start()
        await fulfillment(of: [started], timeout: 2)
        model.setForeground(false)
        camera.pendingStart?.resume(); camera.pendingStart = nil
        await waitUntil { !model.transitioning }
        XCTAssertEqual(model.phase, .paused)
        XCTAssertFalse(model.transitioning)
        XCTAssertGreaterThanOrEqual(camera.stops, 1)
    }
    func testRestartWaitsUntilPreviousStopCompletes() async {
        let camera = ControlledCamera(); let model = makeModel(camera)
        model.start(); await waitUntil { !model.transitioning }
        camera.suspendStop = true
        let stopping = expectation(description: "Stop is pending")
        camera.onStop = { stopping.fulfill() }
        model.stop(); await fulfillment(of: [stopping], timeout: 2)
        XCTAssertTrue(model.transitioning)
        model.start()
        XCTAssertEqual(camera.starts, 1)
        camera.suspendStop = false; camera.pendingStop?.resume(); camera.pendingStop = nil
        await waitUntil { !model.transitioning }
        model.start(); await waitUntil { !model.transitioning }
        XCTAssertEqual(camera.starts, 2)
    }
    func testSaveFailureIsVisible() async {
        let camera = ControlledCamera(); let model = makeModel(camera)
        model.start(); await waitUntil { !model.transitioning }
        camera.onStatistics?(CameraStatistics(seconds: 2, bytes: 100))
        await waitUntil { model.canSave }
        model.save(); await waitUntil { !model.saving }
        XCTAssertFalse(model.saving); XCTAssertNotNil(model.message)
    }
    func testLateInterruptionCannotReplaceStoppedStateOrActionableError() async {
        let camera = ControlledCamera(); let model = makeModel(camera)
        model.start(); await waitUntil { !model.transitioning }
        model.stop(); await waitUntil { !model.transitioning }
        model.message = "Keep this actionable error"
        camera.onInterruption?("Late interruption")
        // Statistics provide an observable fence after the queued callbacks.
        camera.onStatistics?(CameraStatistics(seconds: 2, bytes: 321))
        await waitUntil { model.bytes == 321 }
        XCTAssertEqual(model.phase, .stopped)
        XCTAssertEqual(model.message, "Keep this actionable error")
        XCTAssertEqual(model.seconds, 0)
        XCTAssertFalse(model.canSave)
    }
    func testNewCaptureWaitsForFreshStatisticsEvenIfServiceDoesNotPublishOnStop() async {
        let camera = ControlledCamera(); let model = makeModel(camera)
        model.start(); await waitUntil { !model.transitioning }
        camera.onStatistics?(CameraStatistics(seconds: 2, bytes: 100))
        await waitUntil { model.canSave }
        model.stop(); await waitUntil { !model.transitioning }
        XCTAssertEqual(model.seconds, 0)
        model.start(); await waitUntil { !model.transitioning }
        XCTAssertEqual(model.phase, .buffering)
        XCTAssertFalse(model.canSave)
        camera.onStatistics?(CameraStatistics(seconds: 1, bytes: 50))
        await waitUntil { model.canSave }
        XCTAssertEqual(model.seconds, 1)
    }
}
