import AVFoundation

/// The production media pipeline, independent of camera hardware. All mutable
/// state and synchronous methods belong to `queue`, including delegate ingestion.
/// Media PTS never drives the watchdog: `now` is a separate monotonic host clock.
final class RollingRecorder: @unchecked Sendable {
    let queue: DispatchQueue
    let directory: URL
    var onStatistics: ((CameraStatistics) -> Void)?
    var onFailure: ((Error) -> Void)?
    private let now: () -> Double
    private let capacity: () throws -> Int64
    private let makeWriter: (CMSampleBuffer, Bool, URL) throws -> SegmentWriting
    private let deliverCompletion: (@escaping () -> Void) -> Void
    private var index = SegmentIndex()
    private var writer: SegmentWriting?
    private var running = false
    private var audioEnabled = false
    private var pending = 0
    private var generation = UUID()
    private var freezing = false
    private var snapshotContinuation: CheckedContinuation<BufferSnapshot, Error>?
    private var snapshotEnd: Double = 0
    private var lastTimestamp: Double = 0
    private var lastReport: Double = -.infinity
    private var health: CaptureWatchdog?
    private let diskLimit: Int64 = 192 * 1_024 * 1_024

    init(queue: DispatchQueue, directory: URL? = nil,
         now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
         capacity: (() throws -> Int64)? = nil,
         makeWriter: @escaping (CMSampleBuffer, Bool, URL) throws -> SegmentWriting = {
             try SegmentWriter(sample: $0, audioEnabled: $1, directory: $2)
         },
         deliverCompletion: @escaping (@escaping () -> Void) -> Void = { $0() }) {
        self.queue = queue
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RollingSegments", isDirectory: true)
        self.now = now
        let storage = self.directory
        self.capacity = capacity ?? {
            try storage.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage ?? Int64.max
        }
        self.makeWriter = makeWriter
        self.deliverCompletion = deliverCompletion
        // Only expendable capture media lives here, never the persistent library.
        try? FileManager.default.removeItem(at: self.directory)
        try? ProtectedFiles.directory(self.directory)
    }

    func start(audio: Bool, duration: Double) {
        dispatchPrecondition(condition: .onQueue(queue))
        stop()
        index.window = duration
        audioEnabled = audio
        running = true
        health = CaptureWatchdog(startedAt: now())
    }

    func stop(snapshotError: Error = CameraError.empty) {
        dispatchPrecondition(condition: .onQueue(queue))
        running = false
        health = nil
        writer?.cancel(); writer = nil
        generation = UUID(); pending = 0
        lastTimestamp = 0; lastReport = -.infinity
        if let continuation = snapshotContinuation {
            snapshotContinuation = nil
            continuation.resume(throwing: snapshotError)
        }
        freezing = false
        ProtectedFiles.remove(index.clearUnpinned().map(\.url))
        onStatistics?(CameraStatistics(seconds: 0, bytes: index.bytes))
    }

    func pollHealth() {
        dispatchPrecondition(condition: .onQueue(queue))
        if running, health?.timedOut(at: now()) == true {
            fail(CameraError.writer("Camera frames stopped arriving. Tap Start Buffer to retry."))
        }
    }

    /// Nonblocking real-time ingestion. False denotes backpressure only; a
    /// hardware delegate drops it. DEBUG manual advancement may retry off-queue.
    @discardableResult func ingest(_ sample: CMSampleBuffer, isAudio: Bool) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard running, !freezing else { return true }
        do {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard pts.isNumeric else { return true }
            if !isAudio {
                health?.sawVideo(at: now())
                // Ignore stale video across rotations as well as within a file.
                guard lastTimestamp == 0 || pts.seconds > lastTimestamp else { return true }
                if let current = writer, pts.seconds - current.start.seconds >= 2 {
                    writer = nil
                    finish(current)
                }
                guard pending < 3 else { throw CameraError.writer("Video encoding is too slow. Buffering stopped.") }
                if writer == nil { writer = try makeWriter(sample, audioEnabled, directory) }
            }
            let accepted = try writer?.append(sample, isAudio: isAudio) ?? true
            if !isAudio, accepted { lastTimestamp = pts.seconds }
            if now() - lastReport >= 0.25 {
                lastReport = now()
                let bytes = try diskBytes()
                guard bytes < diskLimit, try capacity() > 64 * 1_024 * 1_024 else { throw CameraError.storage }
                onStatistics?(CameraStatistics(seconds: min(index.window, index.duration +
                    (writer.map { $0.end.seconds - $0.start.seconds } ?? 0)), bytes: bytes))
            }
            return accepted
        } catch { fail(error); return true }
    }

    private func fail(_ error: Error) {
        stop(snapshotError: error)
        onFailure?(error)
    }

    private func diskBytes() throws -> Int64 {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .reduce(Int64(0)) { $0 + ProtectedFiles.bytes($1) }
    }

    private func finish(_ closing: SegmentWriting) {
        pending += 1
        let epoch = generation
        closing.finish { [weak self] result in
            guard let self else {
                if case .success(let segment) = result { ProtectedFiles.remove([segment.url]) }
                return
            }
            self.deliverCompletion { [self] in queue.async { [self] in
                guard epoch == generation else {
                    if case .success(let segment) = result { ProtectedFiles.remove([segment.url]) }
                    return
                }
                pending -= 1
                switch result {
                case .success(let segment):
                    index.insert(segment)
                    // Save pins boundary segments before any expiration pass.
                    if !freezing { ProtectedFiles.remove(index.prune(now: lastTimestamp).map(\.url)) }
                    completeSnapshotIfReady()
                case .failure(let error): fail(error)
                }
            } }
        }
    }

    func snapshot() async throws -> BufferSnapshot {
        try await withCheckedThrowingContinuation { continuation in queue.async { [self] in
            guard running, !freezing else { continuation.resume(throwing: CameraError.empty); return }
            freezing = true
            snapshotContinuation = continuation
            snapshotEnd = writer?.end.seconds ?? lastTimestamp
            if let current = writer { writer = nil; finish(current) }
            completeSnapshotIfReady()
        } }
    }

    private func completeSnapshotIfReady() {
        guard freezing, pending == 0, let continuation = snapshotContinuation else { return }
        snapshotContinuation = nil
        let (token, selection) = index.pin(endingAt: snapshotEnd)
        freezing = false
        guard !selection.isEmpty else {
            index.release(token); continuation.resume(throwing: CameraError.empty); return
        }
        continuation.resume(returning: BufferSnapshot(token: token, segments: selection,
                                                    end: snapshotEnd, window: index.window))
    }

    func release(_ snapshot: BufferSnapshot) async {
        await withCheckedContinuation { continuation in queue.async { [self] in
            index.release(snapshot.token)
            let removed = running ? index.prune(now: lastTimestamp) : index.clearUnpinned()
            ProtectedFiles.remove(removed.map(\.url))
            continuation.resume()
        } }
    }

    #if DEBUG
    struct Diagnostics {
        let running: Bool
        let freezing: Bool
        let pending: Int
        let segments: [VideoSegment]
        let diskBytes: Int64
        let files: [URL]
    }
    func diagnostics() async throws -> Diagnostics {
        try await withCheckedThrowingContinuation { continuation in queue.async { [self] in
            do {
                continuation.resume(returning: Diagnostics(running: running, freezing: freezing,
                    pending: pending, segments: index.segments, diskBytes: try diskBytes(),
                    files: try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)))
            } catch { continuation.resume(throwing: error) }
        } }
    }

    /// Only the explicitly constructed DEBUG harness waits. Encoder callbacks
    /// and other stream samples can run between retries; no queue is blocked.
    func appendManually(_ sample: CMSampleBuffer, isAudio: Bool,
                        timeout: Duration = .seconds(15)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            let accepted: Bool = try await withCheckedThrowingContinuation { continuation in queue.async { [self] in
                guard running else { continuation.resume(throwing: CameraError.empty); return }
                // Manual time may outrun asynchronous finalization. Hardware
                // keeps the ordinary three-writer overload stop above.
                if pending >= 2 || freezing { continuation.resume(returning: false); return }
                let accepted = ingest(sample, isAudio: isAudio)
                guard running else { continuation.resume(throwing: CameraError.empty); return }
                continuation.resume(returning: accepted)
            } }
            if accepted { return }
            guard ContinuousClock.now < deadline else { throw CameraError.writer("Manual sample ingestion timed out.") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    #endif
}
