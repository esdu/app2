import AVFoundation
import XCTest
@testable import LittleMoments

private final class RecordingExportBackend: ClipExportBackend {
    var compatible = true
    var compatibilityChecks = 0
    var attempts: [String] = []
    var errors: [Int: Error] = [:]
    var beforeAttempt: ((Int, URL) throws -> Void)?
    func supportsPassthrough(_ asset: AVAsset) async -> Bool {
        compatibilityChecks += 1; return compatible
    }
    func export(_ asset: AVAsset, preset: String, to destination: URL) async throws {
        let attempt = attempts.count
        attempts.append(preset)
        try beforeAttempt?(attempt, destination)
        // Simulate a session that writes a partial file before reporting failure.
        try Data([UInt8(attempt + 1)]).write(to: destination)
        if let error = errors[attempt] { throw error }
    }
}

final class ClipExportTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try ProtectedFiles.directory(directory)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func snapshot() async throws -> BufferSnapshot {
        let source = directory.appendingPathComponent("source.mov")
        try await SyntheticMovie.write(to: source)
        return BufferSnapshot(token: UUID(), segments: [VideoSegment(id: UUID(), url: source,
            start: 100, end: 102, bytes: ProtectedFiles.bytes(source))], end: 102, window: 30)
    }
    func testProductionDefaultDoesNotAttemptPassthrough() async throws {
        let snapshot = try await snapshot(), backend = RecordingExportBackend()
        let output = directory.appendingPathComponent("clip.mp4")
        try await ClipComposer(backend: backend).compose(snapshot, to: output)
        XCTAssertEqual(backend.compatibilityChecks, 0)
        XCTAssertEqual(backend.attempts, [AVAssetExportPresetHighestQuality])
    }
    func testUnsupportedPassthroughUsesOnlyHighestQuality() async throws {
        let snapshot = try await snapshot(), backend = RecordingExportBackend()
        backend.compatible = false
        try await ClipComposer(strategy: .evaluatePassthrough, backend: backend)
            .compose(snapshot, to: directory.appendingPathComponent("clip.mp4"))
        XCTAssertEqual(backend.compatibilityChecks, 1)
        XCTAssertEqual(backend.attempts, [AVAssetExportPresetHighestQuality])
    }
    func testFailedPartialIsRemovedBeforeFreshFallbackAndLeaseRemainsPinned() async throws {
        let original = try await snapshot(), backend = RecordingExportBackend()
        var index = SegmentIndex(); index.insert(original.segments[0])
        let (token, segments) = index.pin(endingAt: original.end)
        let pinned = BufferSnapshot(token: token, segments: segments, end: original.end, window: original.window)
        backend.errors[0] = ClipExportFailure.incompatible
        backend.beforeAttempt = { attempt, output in
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "No partial may reach a fresh attempt")
            XCTAssertTrue(index.clearUnpinned().isEmpty, "Source lease must span every attempt")
            XCTAssertTrue(FileManager.default.fileExists(atPath: segments[0].url.path))
            XCTAssertEqual(attempt, backend.attempts.count - 1)
        }
        let output = directory.appendingPathComponent("clip.mp4")
        try await ClipComposer(strategy: .evaluatePassthrough, backend: backend).compose(pinned, to: output)
        XCTAssertEqual(backend.attempts, [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality])
        XCTAssertEqual(try Data(contentsOf: output), Data([2]))
        XCTAssertTrue(index.clearUnpinned().isEmpty)
        index.release(token); XCTAssertEqual(index.clearUnpinned().count, 1)
    }
    func testFailedFallbackRemovesDestinationWithoutRemovingSources() async throws {
        let snapshot = try await snapshot(), backend = RecordingExportBackend()
        backend.errors = [0: ClipExportFailure.incompatible, 1: CameraError.storage]
        let output = directory.appendingPathComponent("clip.mp4")
        do {
            try await ClipComposer(strategy: .evaluatePassthrough, backend: backend).compose(snapshot, to: output)
            XCTFail("Fallback failure must propagate")
        } catch {
            XCTAssertEqual((error as? CameraError)?.localizedDescription, CameraError.storage.localizedDescription)
        }
        XCTAssertEqual(backend.attempts.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.segments[0].url.path))
    }
    func testCancellationStorageAndProtectedDataDoNotRetry() async throws {
        let snapshot = try await snapshot()
        let failures: [Error] = [CancellationError(),
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError),
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError),
            NSError(domain: AVFoundationErrorDomain, code: AVError.exportFailed.rawValue)]
        for (number, failure) in failures.enumerated() {
            let backend = RecordingExportBackend(); backend.errors[0] = failure
            let output = directory.appendingPathComponent("failure-\(number).mp4")
            do {
                try await ClipComposer(strategy: .evaluatePassthrough, backend: backend).compose(snapshot, to: output)
                XCTFail("Actionable error must propagate")
            } catch { XCTAssertFalse(ClipComposer.allowsPassthroughFallback(error)) }
            XCTAssertEqual(backend.attempts, [AVAssetExportPresetPassthrough])
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        }
    }
    func testAlreadyCancelledTaskStartsNoExportAttempt() async throws {
        let snapshot = try await snapshot(), backend = RecordingExportBackend()
        let output = directory.appendingPathComponent("cancelled.mp4")
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await ClipComposer(strategy: .evaluatePassthrough, backend: backend).compose(snapshot, to: output)
        }
        do { try await operation.value; XCTFail("Cancellation must propagate") } catch {}
        XCTAssertTrue(backend.attempts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
    func testRetryClassificationIsNarrow() {
        XCTAssertTrue(ClipComposer.allowsPassthroughFallback(ClipExportFailure.incompatible))
        XCTAssertTrue(ClipComposer.allowsPassthroughFallback(NSError(domain: AVFoundationErrorDomain,
            code: AVError.operationNotSupportedForAsset.rawValue)))
        XCTAssertFalse(ClipComposer.allowsPassthroughFallback(CameraError.unavailable))
        XCTAssertFalse(ClipComposer.allowsPassthroughFallback(NSError(domain: AVFoundationErrorDomain,
            code: AVError.operationNotSupportedForAsset.rawValue, userInfo: [NSUnderlyingErrorKey:
                NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)])))
        XCTAssertFalse(ClipComposer.allowsPassthroughFallback(NSError(domain: NSPOSIXErrorDomain, code: 28)))
        XCTAssertFalse(ClipComposer.allowsPassthroughFallback(NSError(domain: AVFoundationErrorDomain,
            code: AVError.exportFailed.rawValue, userInfo: [NSUnderlyingErrorKey:
                NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)])))
    }
}
