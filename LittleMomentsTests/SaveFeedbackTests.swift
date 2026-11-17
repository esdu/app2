import AVFoundation
import XCTest
@testable import LittleMoments

private final class FeedbackCamera: CameraService {
    var session: AVCaptureSession? { nil }
    var onStatistics: ((CameraStatistics) -> Void)?
    var onInterruption: ((String) -> Void)?
    var snapshotError: Error?
    var snapshots = 0
    var releases = 0
    var segments: [VideoSegment] = []
    var requestedPostRoll: Double?
    var partial = false
    var suspendCollection = false
    var collection: CheckedContinuation<Void, Never>?
    var progress: ((Double) -> Void)?
    var suspendRelease = false
    var releaseContinuation: CheckedContinuation<Void, Never>?
    func start(audio: Bool, front: Bool, duration: Double) async throws {
        onStatistics?(CameraStatistics(seconds: 2, bytes: 100))
    }
    func stop() async {}
    func snapshot() async throws -> BufferSnapshot {
        snapshots += 1
        if let snapshotError { throw snapshotError }
        return BufferSnapshot(token: UUID(), segments: segments, end: 2, window: 30, requestedEnd: partial ? 7 : 2)
    }
    func snapshot(postRoll: Double, onProgress: @escaping (Double) -> Void) async throws -> BufferSnapshot {
        requestedPostRoll = postRoll; progress = onProgress
        if suspendCollection { await withCheckedContinuation { collection = $0 } }
        return try await snapshot()
    }
    func release(_ snapshot: BufferSnapshot) async {
        releases += 1
        if suspendRelease { await withCheckedContinuation { releaseContinuation = $0 } }
    }
}
@MainActor private final class FeedbackSaver: MomentSaving {
    var calls = 0
    var error: Error?
    var suspended = false
    var pending: CheckedContinuation<Void, Never>?
    func save(_ snapshot: BufferSnapshot) async throws {
        calls += 1
        if suspended { await withCheckedContinuation { pending = $0 } }
        if let error { throw error }
    }
    func finish() { pending?.resume(); pending = nil }
}
@MainActor private final class FeedbackRecorder: SaveHaptics, SaveAnnouncing {
    var haptics: [SaveOutcome] = []
    var announcements: [String] = []
    var onAnnounce: (() -> Void)?
    func notify(_ outcome: SaveOutcome) { haptics.append(outcome) }
    func announce(_ text: String) { announcements.append(text); onAnnounce?() }
}
@MainActor private final class ManualFeedbackScheduler: FeedbackScheduling {
    final class Entry: FeedbackCancellation {
        var cancelled = false
        let action: @MainActor () -> Void
        init(_ action: @escaping @MainActor () -> Void) { self.action = action }
        func cancel() { cancelled = true }
        // Deliberately execute even cancelled callbacks to exercise the token guard.
        func fire() { action() }
    }
    var entries: [Entry] = []
    func schedule(after delay: Duration, action: @escaping @MainActor () -> Void) -> any FeedbackCancellation {
        let entry = Entry(action); entries.append(entry); return entry
    }
}

@MainActor final class SaveFeedbackTests: XCTestCase {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func model(camera: FeedbackCamera, saver: FeedbackSaver? = nil,
                       feedback: FeedbackRecorder, scheduler: ManualFeedbackScheduler) -> CameraModel {
        CameraModel(camera: camera, library: ClipLibrary(directory: directory()), saver: saver,
                    haptics: feedback, announcer: feedback, feedbackScheduler: scheduler)
    }
    private func waitUntil(_ condition: @escaping @MainActor () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Expected asynchronous state transition", file: file, line: line)
    }
    private func start(_ model: CameraModel) async {
        model.start(); await waitUntil { model.canSave }
    }
    func testPostRollProgressAndOneSaveUntilLeaseRelease() async {
        let camera = FeedbackCamera(), saver = FeedbackSaver(), feedback = FeedbackRecorder(), scheduler = ManualFeedbackScheduler()
        camera.suspendCollection = true; camera.suspendRelease = true
        let subject = model(camera: camera, saver: saver, feedback: feedback, scheduler: scheduler)
        subject.setPostRoll(10); await start(subject)
        subject.save(); subject.save()
        await waitUntil { camera.collection != nil }
        XCTAssertEqual(camera.requestedPostRoll, 10); XCTAssertEqual(subject.postRollRemaining, 10)
        camera.progress?(4.2); await waitUntil { subject.postRollRemaining == 4.2 }
        XCTAssertFalse(subject.canChangePreferences); subject.setPostRoll(5); XCTAssertEqual(subject.postRoll, 10)
        camera.collection?.resume(); camera.collection = nil
        await waitUntil { camera.releaseContinuation != nil }
        XCTAssertTrue(subject.saving); XCTAssertNil(subject.postRollRemaining)
        subject.save(); XCTAssertEqual(camera.snapshots, 1); XCTAssertEqual(saver.calls, 1)
        camera.releaseContinuation?.resume(); camera.releaseContinuation = nil
        await waitUntil { !subject.saving }
        // A delayed progress callback from collection must not revive the status.
        camera.progress?(1); await Task.yield(); XCTAssertNil(subject.postRollRemaining)
        XCTAssertEqual(feedback.haptics, [.success]); XCTAssertEqual(camera.releases, 1)
    }

    func testBackgroundDuringPostRollDefersShorterFeedbackAndDoesNotResume() async {
        let camera = FeedbackCamera(), saver = FeedbackSaver(), feedback = FeedbackRecorder(), scheduler = ManualFeedbackScheduler()
        camera.suspendCollection = true; camera.partial = true
        let subject = model(camera: camera, saver: saver, feedback: feedback, scheduler: scheduler)
        subject.setPostRoll(5); await start(subject); subject.save()
        await waitUntil { camera.collection != nil }
        subject.setForeground(false)
        camera.collection?.resume(); camera.collection = nil
        await waitUntil { !subject.saving && !subject.transitioning }
        XCTAssertEqual(subject.phase, .paused); XCTAssertNil(subject.saveStatus)
        XCTAssertTrue(feedback.haptics.isEmpty); XCTAssertTrue(feedback.announcements.isEmpty)
        XCTAssertEqual(camera.releases, 1)
        subject.setForeground(true)
        XCTAssertEqual(subject.phase, .paused)
        XCTAssertEqual(subject.saveStatus, SaveOutcome.partial.text)
        XCTAssertEqual(feedback.announcements, [SaveOutcome.partial.text]); XCTAssertTrue(feedback.haptics.isEmpty)
    }

    func testCommittedSavePublishesSuccessOnceAndReleasesLease() async throws {
        let camera = FeedbackCamera(), feedback = FeedbackRecorder(), scheduler = ManualFeedbackScheduler()
        let sourceDirectory = directory(); try ProtectedFiles.directory(sourceDirectory)
        let source = sourceDirectory.appendingPathComponent("fixture.mov")
        try await SyntheticMovie.write(to: source)
        camera.segments = [VideoSegment(id: UUID(), url: source, start: 0, end: 2, bytes: ProtectedFiles.bytes(source))]
        let model = model(camera: camera, feedback: feedback, scheduler: scheduler)
        feedback.onAnnounce = { XCTAssertEqual(model.library.clips.count, 1) }
        await start(model); model.save(); await waitUntil { !model.saving }
        XCTAssertEqual(model.saveStatus, "Moment saved to your library")
        XCTAssertNil(model.message); XCTAssertEqual(feedback.haptics, [.success])
        XCTAssertEqual(feedback.announcements, ["Moment saved to your library"])
        XCTAssertEqual(camera.releases, 1)
        ProtectedFiles.remove([source])
        let reloaded = ClipLibrary(directory: model.library.directory); try reloaded.load()
        XCTAssertEqual(reloaded.clips.count, 1)
        XCTAssertGreaterThan(reloaded.clips[0].bytes, 0)
    }
    func testNoSuccessBeforeCommitAndRapidTriggersSaveOnce() async {
        let camera = FeedbackCamera(), saver = FeedbackSaver(), feedback = FeedbackRecorder(), scheduler = ManualFeedbackScheduler()
        saver.suspended = true
        let model = model(camera: camera, saver: saver, feedback: feedback, scheduler: scheduler)
        await start(model); model.save(); model.save(); model.save()
        await waitUntil { saver.pending != nil }
        XCTAssertTrue(model.saving); XCTAssertFalse(model.canSave)
        XCTAssertNil(model.saveStatus); XCTAssertTrue(feedback.haptics.isEmpty)
        XCTAssertTrue(feedback.announcements.isEmpty)
        XCTAssertEqual(camera.snapshots, 1); XCTAssertEqual(saver.calls, 1)
        saver.finish(); await waitUntil { !model.saving }
        XCTAssertEqual(feedback.haptics, [.success]); XCTAssertEqual(camera.releases, 1)
    }
    func testSnapshotFailureIsPersistentAndDoesNotInvokeSaver() async {
        let camera = FeedbackCamera(), saver = FeedbackSaver(), feedback = FeedbackRecorder(), scheduler = ManualFeedbackScheduler()
        camera.snapshotError = CameraError.empty
        let model = model(camera: camera, saver: saver, feedback: feedback, scheduler: scheduler)
        await start(model); model.save(); await waitUntil { !model.saving }
        XCTAssertEqual(saver.calls, 0); XCTAssertEqual(camera.releases, 0)
        XCTAssertEqual(model.message, CameraError.empty.localizedDescription)
        XCTAssertEqual(feedback.haptics, [.failure(CameraError.empty.localizedDescription)])
        XCTAssertEqual(feedback.announcements.count, 1); XCTAssertTrue(scheduler.entries.isEmpty)
        XCTAssertNil(model.saveStatus)
    }
    func testExportFailureReleasesLeaseAndPersistsError() async {
        let camera = FeedbackCamera(), saver = FeedbackSaver(), feedback = FeedbackRecorder(), scheduler = ManualFeedbackScheduler()
        let model = model(camera: camera, saver: saver, feedback: feedback, scheduler: scheduler)
        await start(model)
        model.save(); await waitUntil { !model.saving }
        let oldTimer = scheduler.entries[0]
        saver.error = CameraError.storage
        model.save(); await waitUntil { !model.saving }
        XCTAssertEqual(camera.releases, 2)
        XCTAssertEqual(feedback.haptics, [.success, .failure(CameraError.storage.localizedDescription)])
        XCTAssertEqual(feedback.announcements.count, 2)
        oldTimer.fire()
        XCTAssertNil(model.saveStatus)
        XCTAssertEqual(model.message, CameraError.storage.localizedDescription)
    }
    func testReplacementIgnoresCancelledTimeout() async {
        let camera = FeedbackCamera(), saver = FeedbackSaver(), feedback = FeedbackRecorder(), scheduler = ManualFeedbackScheduler()
        let model = model(camera: camera, saver: saver, feedback: feedback, scheduler: scheduler)
        await start(model); model.save(); await waitUntil { !model.saving }
        let oldTimer = scheduler.entries[0]
        model.save(); await waitUntil { !model.saving }
        XCTAssertTrue(oldTimer.cancelled)
        oldTimer.fire(); XCTAssertNotNil(model.saveStatus)
        scheduler.entries[1].fire(); XCTAssertNil(model.saveStatus)
        XCTAssertEqual(feedback.haptics, [.success, .success]); XCTAssertEqual(feedback.announcements.count, 2)
    }
    func testInactiveCompletionDefersAnnouncementWithoutDelayedHaptics() async {
        let camera = FeedbackCamera(), saver = FeedbackSaver(), feedback = FeedbackRecorder(), scheduler = ManualFeedbackScheduler()
        saver.suspended = true
        let model = model(camera: camera, saver: saver, feedback: feedback, scheduler: scheduler)
        await start(model); model.save(); await waitUntil { saver.pending != nil }
        model.setForeground(false); saver.finish(); await waitUntil { !model.saving }
        XCTAssertNil(model.saveStatus); XCTAssertTrue(feedback.haptics.isEmpty)
        XCTAssertTrue(feedback.announcements.isEmpty); XCTAssertEqual(camera.releases, 1)
        model.setForeground(true)
        XCTAssertNotNil(model.saveStatus); XCTAssertEqual(feedback.announcements.count, 1)
        XCTAssertTrue(feedback.haptics.isEmpty)
        model.setForeground(true); XCTAssertEqual(feedback.announcements.count, 1)
        XCTAssertEqual(model.phase, .paused)
    }
    func testCompletionInLibraryStillPresentsOutcome() async {
        let camera = FeedbackCamera(), saver = FeedbackSaver(), feedback = FeedbackRecorder(), scheduler = ManualFeedbackScheduler()
        saver.suspended = true
        let model = model(camera: camera, saver: saver, feedback: feedback, scheduler: scheduler)
        await start(model); model.save(); await waitUntil { saver.pending != nil }
        model.setCameraScreenVisible(false); model.stop(); saver.finish()
        await waitUntil { !model.saving }
        XCTAssertNotNil(model.saveStatus); XCTAssertEqual(feedback.announcements.count, 1)
        XCTAssertFalse(model.canSave); XCTAssertEqual(camera.releases, 1)
    }
    func testCentralGuardRejectsStoppedEmptyHiddenAndInactiveTriggers() async {
        let camera = FeedbackCamera(), saver = FeedbackSaver(), feedback = FeedbackRecorder(), scheduler = ManualFeedbackScheduler()
        let model = model(camera: camera, saver: saver, feedback: feedback, scheduler: scheduler)
        model.save(); XCTAssertFalse(model.saving)
        await start(model)
        camera.onStatistics?(CameraStatistics(seconds: 0, bytes: 0)); await waitUntil { model.seconds == 0 }
        model.save(); XCTAssertFalse(model.saving)
        camera.onStatistics?(CameraStatistics(seconds: 2, bytes: 100)); await waitUntil { model.canSave }
        model.setCameraScreenVisible(false); model.save(); XCTAssertFalse(model.saving)
        model.setCameraScreenVisible(true); XCTAssertTrue(model.canSave)
        model.setForeground(false); model.save(); XCTAssertFalse(model.saving)
        XCTAssertEqual(camera.snapshots, 0); XCTAssertTrue(feedback.haptics.isEmpty)
    }
}
