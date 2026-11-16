import AVFoundation
import XCTest
@testable import LittleMoments

private final class ControlledCamera: CameraService {
    var session: AVCaptureSession? { nil }
    var onStatistics: ((CameraStatistics) -> Void)?
    var onInterruption: ((String) -> Void)?
    var permission = true
    var starts = 0
    var stops = 0
    func start(audio: Bool, front: Bool, duration: Double) async throws {
        starts += 1
        if !permission { throw CameraError.permission }
    }
    func stop() async { stops += 1 }
    func snapshot() async throws -> BufferSnapshot { throw CameraError.empty }
    func release(_ snapshot: BufferSnapshot) async { }
}
@MainActor final class CameraModelTests: XCTestCase {
    private func makeModel(_ camera: ControlledCamera) -> CameraModel {
        CameraModel(camera: camera, library: ClipLibrary(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
    }
    private func settle() async { for _ in 0..<20 { await Task.yield() } }
    func testLaunchDoesNotStartCamera() {
        let camera = ControlledCamera(); let model = makeModel(camera)
        XCTAssertEqual(camera.starts, 0); XCTAssertEqual(model.phase, .stopped)
    }
    func testDeniedCameraPermission() async {
        let camera = ControlledCamera(); camera.permission = false
        let model = makeModel(camera); model.start(); await settle()
        XCTAssertEqual(model.phase, .denied); XCTAssertNotNil(model.message)
    }
    func testBackgroundPausesAndForegroundDoesNotResume() async {
        let camera = ControlledCamera(); let model = makeModel(camera)
        model.start(); await settle(); XCTAssertEqual(model.phase, .buffering)
        model.setForeground(false); await settle(); XCTAssertEqual(model.phase, .paused)
        model.setForeground(true); await settle(); XCTAssertEqual(model.phase, .paused)
        XCTAssertEqual(camera.starts, 1); XCTAssertGreaterThanOrEqual(camera.stops, 1)
        model.start(); await settle(); XCTAssertEqual(camera.starts, 2)
    }
    func testInterruptionRequiresExplicitRestart() async {
        let camera = ControlledCamera(); let model = makeModel(camera)
        model.start(); await settle(); camera.onInterruption?("Interrupted")
        await settle(); XCTAssertEqual(model.phase, .paused); XCTAssertEqual(camera.starts, 1)
    }
    func testSaveFailureIsVisible() async {
        let camera = ControlledCamera(); let model = makeModel(camera)
        model.start(); await settle(); model.save(); await settle()
        XCTAssertFalse(model.saving); XCTAssertNotNil(model.message)
    }
}
