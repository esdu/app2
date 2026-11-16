import AVFoundation
import XCTest
@testable import LittleMoments

private final class ThermalCamera: CameraService {
    var session: AVCaptureSession? { nil }
    var onStatistics: ((CameraStatistics) -> Void)?
    var onInterruption: ((String) -> Void)?
    var starts = 0
    var stops = 0
    var active = false
    var suspendStart = false
    var pendingStart: CheckedContinuation<Void, Never>?
    var suspendSnapshot = false
    var pendingSnapshot: CheckedContinuation<BufferSnapshot, Error>?
    var segment: VideoSegment?
    var onLease: (() -> Void)?
    var pinnedSourceSurvivedStop = false
    var releases = 0
    private var generation = 0
    private var index = SegmentIndex()

    @MainActor func start(audio: Bool, front: Bool, duration: Double) async throws {
        starts += 1
        let request = generation
        if suspendStart { await withCheckedContinuation { pendingStart = $0 } }
        // Match production stop's invalidation of a start still awaiting permission/configuration.
        guard request == generation else { return }
        active = true
        onStatistics?(CameraStatistics(seconds: 2, bytes: segment?.bytes ?? 1))
    }
    @MainActor func stop() async {
        stops += 1; generation += 1; active = false
        ProtectedFiles.remove(index.clearUnpinned().map(\.url))
        if let segment { pinnedSourceSurvivedStop = FileManager.default.fileExists(atPath: segment.url.path) }
        if let pendingSnapshot {
            self.pendingSnapshot = nil
            pendingSnapshot.resume(throwing: CameraError.writer("The buffer paused before the save was ready."))
        }
        onStatistics?(CameraStatistics(seconds: 0, bytes: index.bytes))
    }
    @MainActor func snapshot() async throws -> BufferSnapshot {
        if suspendSnapshot { return try await withCheckedThrowingContinuation { pendingSnapshot = $0 } }
        guard active, let segment else { throw CameraError.empty }
        index.insert(segment)
        let (token, segments) = index.pin(endingAt: segment.end)
        onLease?()
        return BufferSnapshot(token: token, segments: segments, end: segment.end, window: 30)
    }
    @MainActor func release(_ snapshot: BufferSnapshot) async {
        releases += 1; index.release(snapshot.token)
        ProtectedFiles.remove(index.clearUnpinned().map(\.url))
    }
}

@MainActor final class ThermalTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try ProtectedFiles.directory(url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func makeModel(_ camera: ThermalCamera, _ monitor: ThermalMonitoring,
                           library: ClipLibrary? = nil) throws -> CameraModel {
        let selectedLibrary: ClipLibrary
        if let library { selectedLibrary = library }
        else { selectedLibrary = ClipLibrary(directory: try directory()) }
        return CameraModel(camera: camera, library: selectedLibrary, thermalMonitor: monitor)
    }
    private func waitUntil(_ condition: @escaping @MainActor () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Expected thermal/capture transition", file: file, line: line)
    }

    func testPurePolicyForEveryThermalState() {
        for state in [ThermalLevel.nominal, .fair] {
            XCTAssertFalse(ThermalPolicy(state: state).blocksCapture)
            XCTAssertNil(ThermalPolicy(state: state).warning)
        }
        let serious = ThermalPolicy(state: .serious)
        XCTAssertFalse(serious.blocksCapture)
        XCTAssertTrue(serious.warning?.contains("remains at 720p") == true)
        let critical = ThermalPolicy(state: .critical)
        XCTAssertTrue(critical.blocksCapture)
        XCTAssertTrue(critical.warning?.contains("Let it cool") == true)
    }

    func testLaunchAlreadyCriticalBlocksStartWithoutPermissionsOrStop() throws {
        let camera = ThermalCamera(), monitor = MutableThermalMonitor(state: .critical)
        let subject = try makeModel(camera, monitor)
        XCTAssertEqual(subject.phase, .stopped)
        XCTAssertFalse(subject.canStart)
        XCTAssertNotNil(subject.thermalWarning)
        subject.start(); subject.start()
        XCTAssertEqual(camera.starts, 0)
        XCTAssertEqual(camera.stops, 0)
        XCTAssertFalse(subject.transitioning)
    }

    func testSeriousWarnsCriticalStopsOnceAndCoolingNeedsExplicitRestart() async throws {
        let camera = ThermalCamera(), monitor = MutableThermalMonitor(state: .serious)
        let subject = try makeModel(camera, monitor)
        XCTAssertNotNil(subject.thermalWarning)
        subject.start(); await waitUntil { subject.phase == .buffering && !subject.transitioning }
        monitor.setState(.critical); monitor.setState(.critical)
        await waitUntil { !subject.transitioning }
        XCTAssertEqual(subject.phase, .paused)
        XCTAssertEqual(camera.stops, 1)
        XCTAssertFalse(subject.canStart)
        monitor.setState(.serious); monitor.setState(.critical); monitor.setState(.fair); monitor.setState(.nominal)
        XCTAssertEqual(camera.starts, 1)
        XCTAssertEqual(camera.stops, 1)
        XCTAssertEqual(subject.phase, .paused)
        XCTAssertNil(subject.thermalWarning)
        XCTAssertTrue(subject.canStart)
        subject.start(); await waitUntil { subject.phase == .buffering && !subject.transitioning }
        XCTAssertEqual(camera.starts, 2)
    }

    func testCriticalDuringStartupCannotActivateOnLateCompletion() async throws {
        let camera = ThermalCamera(), monitor = MutableThermalMonitor()
        camera.suspendStart = true
        let subject = try makeModel(camera, monitor)
        subject.start(); await waitUntil { camera.pendingStart != nil }
        monitor.setState(.critical); monitor.setState(.critical)
        await waitUntil { camera.stops == 1 }
        monitor.setState(.nominal)
        subject.start() // Startup is still draining; this must not create a restart loop.
        XCTAssertEqual(camera.starts, 1)
        camera.pendingStart?.resume(); camera.pendingStart = nil
        await waitUntil { !subject.transitioning }
        XCTAssertEqual(subject.phase, .paused)
        XCTAssertFalse(camera.active)
        XCTAssertEqual(camera.stops, 1)
    }

    func testStartAndCompletionSampleCurrentStateEvenWithoutNotification() async throws {
        let camera = ThermalCamera(), monitor = MutableThermalMonitor()
        let subject = try makeModel(camera, monitor)
        monitor.state = .critical
        subject.start()
        XCTAssertEqual(camera.starts, 0)
        monitor.state = .nominal
        camera.suspendStart = true
        subject.start(); await waitUntil { camera.pendingStart != nil }
        monitor.state = .critical
        camera.pendingStart?.resume(); camera.pendingStart = nil
        await waitUntil { !subject.transitioning }
        XCTAssertEqual(subject.phase, .paused)
        XCTAssertEqual(camera.stops, 1)
        XCTAssertFalse(camera.active)
    }

    func testQueuedStaleNotificationReadsCurrentStateAndNeverRestarts() async throws {
        let center = NotificationCenter()
        var current = ThermalLevel.nominal
        let monitor = ProcessThermalMonitor(center: center, readState: { current })
        let camera = ThermalCamera()
        let subject = try makeModel(camera, monitor)
        let update = monitor.onChange
        var deliveries = 0
        monitor.onChange = { deliveries += 1; update?() }
        subject.start(); await waitUntil { subject.phase == .buffering && !subject.transitioning }
        current = .critical
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        current = .nominal
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        // Both queued notifications must sample nominal when they reach MainActor.
        await waitUntil { deliveries == 2 }
        XCTAssertEqual(subject.thermalState, .nominal)
        XCTAssertEqual(subject.phase, .buffering)
        XCTAssertEqual(camera.stops, 0)
        subject.stop(); await waitUntil { !subject.transitioning }
        center.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        await waitUntil { deliveries == 3 }
        XCTAssertEqual(subject.phase, .stopped)
        XCTAssertEqual(camera.starts, 1)
    }

    func testThermalPauseThenBackgroundAndCoolingDoNotStopTwiceOrResume() async throws {
        let camera = ThermalCamera(), monitor = MutableThermalMonitor()
        let subject = try makeModel(camera, monitor)
        subject.start(); await waitUntil { subject.phase == .buffering && !subject.transitioning }
        monitor.setState(.critical)
        subject.setForeground(false)
        monitor.setState(.nominal)
        await waitUntil { !subject.transitioning }
        subject.start()
        XCTAssertEqual(camera.starts, 1)
        XCTAssertEqual(camera.stops, 1)
        subject.setForeground(true)
        XCTAssertEqual(subject.phase, .paused)
        XCTAssertEqual(camera.starts, 1)
    }

    func testThermalStopPreservesLeasedSourceUntilRealSaveCompletes() async throws {
        let root = try directory(), camera = ThermalCamera(), monitor = MutableThermalMonitor()
        let source = root.appendingPathComponent("source.mov")
        try await SyntheticMovie.write(to: source, audio: true)
        camera.segment = VideoSegment(id: UUID(), url: source, start: 0, end: 2, bytes: ProtectedFiles.bytes(source))
        let library = ClipLibrary(directory: root.appendingPathComponent("Saved"))
        let subject = try makeModel(camera, monitor, library: library)
        subject.start(); await waitUntil { subject.phase == .buffering && subject.seconds > 0 && !subject.transitioning }
        camera.onLease = { monitor.setState(.critical) }
        subject.save(); await waitUntil { !subject.saving && !subject.transitioning }
        XCTAssertEqual(subject.phase, .paused)
        XCTAssertEqual(camera.stops, 1)
        XCTAssertTrue(camera.pinnedSourceSurvivedStop)
        XCTAssertEqual(camera.releases, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let clip = try XCTUnwrap(library.clips.first)
        XCTAssertEqual(library.clips.count, 1)
        let asset = AVURLAsset(url: clip.url)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(video.count, 1); XCTAssertEqual(audio.count, 1)
        XCTAssertEqual(duration.seconds, 2, accuracy: 0.08)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(video.first), outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var samples = 0
        while output.copyNextSampleBuffer() != nil { samples += 1 }
        XCTAssertEqual(reader.status, .completed); XCTAssertGreaterThan(samples, 0)
        let reloaded = ClipLibrary(directory: library.directory); try reloaded.load()
        XCTAssertEqual(reloaded.clips.count, 1)
    }

    func testCriticalDuringSnapshotFinalizationReportsFailureAndKeepsSavedFiles() async throws {
        let root = try directory(), camera = ThermalCamera(), monitor = MutableThermalMonitor()
        let source = root.appendingPathComponent("older-source.mov")
        try await SyntheticMovie.write(to: source)
        let library = ClipLibrary(directory: root.appendingPathComponent("Saved"))
        let segment = VideoSegment(id: UUID(), url: source, start: 0, end: 2, bytes: ProtectedFiles.bytes(source))
        try await library.save(BufferSnapshot(token: UUID(), segments: [segment], end: 2, window: 30))
        let saved = try XCTUnwrap(library.clips.first).url
        let bytes = try Data(contentsOf: saved)
        let subject = try makeModel(camera, monitor, library: library)
        camera.suspendSnapshot = true
        subject.start(); await waitUntil { subject.phase == .buffering && subject.seconds > 0 && !subject.transitioning }
        subject.save(); await waitUntil { camera.pendingSnapshot != nil }
        monitor.setState(.critical)
        await waitUntil { !subject.saving && !subject.transitioning }
        XCTAssertEqual(subject.phase, .paused)
        XCTAssertNotNil(subject.message)
        XCTAssertEqual(camera.releases, 0)
        XCTAssertEqual(try Data(contentsOf: saved), bytes)
        XCTAssertEqual(library.clips.count, 1)
    }
}
