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
    private let audioBoundary = SegmentAudioBoundary()
    private var running = false
    private var audioEnabled = false
    private var pending = 0
    private var finalizing: [UUID: SegmentWriting] = [:]
    private var generation = UUID()
    private var freezing = false
    private var snapshotContinuation: CheckedContinuation<BufferSnapshot, Error>?
    private var snapshotEnd: Double = 0
    private var lastTimestamp: Double = 0
    private var lastReport: Double = -.infinity
    private var health: CaptureWatchdog?
    private final class CollectionRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func cancel() { lock.lock(); value = true; lock.unlock() }
    }
    private final class Collection {
        let request: CollectionRequest
        let token: UUID
        let start: Double
        let target: Double
        let continuation: CheckedContinuation<BufferSnapshot, Error>
        let progress: (Double) -> Void
        var cutoff: Double?
        var finalizers: Set<UUID> = []
        var deadline: Double
        init(request: CollectionRequest, token: UUID, start: Double, target: Double, deadline: Double,
             continuation: CheckedContinuation<BufferSnapshot, Error>, progress: @escaping (Double) -> Void) {
            self.request = request; self.token = token; self.start = start; self.target = target; self.deadline = deadline
            self.continuation = continuation; self.progress = progress
        }
    }
    private var collection: Collection?
    private var collectionTimer: DispatchSourceTimer?
    private var receivedVideo: Int64 = 0
    private var acceptedVideo: Int64 = 0
    private var receivedAudio: Int64 = 0
    private var acceptedAudio: Int64 = 0
    private var saveDroppedVideo: Int64 = 0
    private var backpressuredVideo: Int64 = 0
    private var saveDroppedAudio: Int64 = 0
    private var backpressuredAudio: Int64 = 0
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
        cancelCollection(CameraError.writer("The pending moment was canceled by a new capture session."))
        stop()
        index.window = duration
        audioEnabled = audio
        receivedVideo = 0; acceptedVideo = 0; receivedAudio = 0; acceptedAudio = 0
        saveDroppedVideo = 0; backpressuredVideo = 0
        saveDroppedAudio = 0; backpressuredAudio = 0
        running = true
        health = CaptureWatchdog(startedAt: now())
    }

    func stop(snapshotError: Error = CameraError.empty) {
        dispatchPrecondition(condition: .onQueue(queue))
        running = false
        health = nil
        if let collection {
            // Explicit stop/background/interruption never keeps capture alive.
            // Safely finish only media already accepted for this fixed interval.
            if collection.cutoff == nil {
                collection.cutoff = min(collection.target, writer?.end.seconds ?? lastTimestamp)
                collection.deadline = now() + 5
                collection.progress(0)
                if let current = writer { writer = nil; finish(current) }
            } else {
                writer?.cancel(); writer = nil
            }
            audioBoundary.flush(finish: finish)
            ProtectedFiles.remove(index.clearUnpinned().map(\.url))
            completeCollectionIfReady()
            onStatistics?(CameraStatistics(seconds: 0, bytes: index.bytes))
            return
        }
        resetStoppedMedia(snapshotError: snapshotError)
    }

    private func resetStoppedMedia(snapshotError: Error) {
        writer?.cancel(); writer = nil
        audioBoundary.cancel()
        finalizing.values.forEach { $0.cancel() }; finalizing.removeAll()
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
        audioBoundary.poll(at: now(), finish: finish)
        pollCollectionDeadline()
    }

    private func pollCollectionDeadline() {
        guard let collection, now() >= collection.deadline else { return }
        if collection.cutoff == nil {
            fail(CameraError.writer("Post-roll stopped because no more camera frames arrived. Tap Start Buffer to retry."))
        } else {
            let error = CameraError.writer("The shortened moment could not finish encoding. Please try again.")
            cancelCollection(error)
            fail(error)
        }
    }

    /// Nonblocking real-time ingestion. False denotes backpressure only; a
    /// hardware delegate drops it. DEBUG manual advancement may retry off-queue.
    @discardableResult func ingest(_ sample: CMSampleBuffer, isAudio: Bool) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        guard running else { return true }
        if isAudio { receivedAudio += 1 } else { receivedVideo += 1 }
        if freezing && (!isAudio || !audioBoundary.waiting) {
            if isAudio { saveDroppedAudio += 1 } else { saveDroppedVideo += 1 }
            return true
        }
        do {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard pts.isNumeric else { return true }
            let previousAudioCount = audioBoundary.acceptedInputCount
            if !isAudio {
                health?.sawVideo(at: now())
                // Ignore stale video across rotations as well as within a file.
                guard lastTimestamp == 0 || pts.seconds > lastTimestamp else { return true }
                if let collection, collection.cutoff == nil, pts.seconds + 0.000001 >= collection.target {
                    collection.cutoff = collection.target
                    collection.deadline = now() + 5
                    collection.progress(0)
                    closeAtSaveBoundary()
                    completeCollectionIfReady()
                }
                if let current = writer, pts.seconds - current.start.seconds >= 2 {
                    writer = nil
                    if audioEnabled { audioBoundary.rotate(current, at: now(), finish: finish) }
                    else { finish(current) }
                }
                guard pending + audioBoundary.waitingCount < 3 else { throw CameraError.writer("Video encoding is too slow. Buffering stopped.") }
                if writer == nil {
                    writer = try makeWriter(sample, audioEnabled, directory)
                    if let writer { try audioBoundary.prepare(writer) }
                }
            }
            let previousVideoCount = writer?.acceptedVideoSampleCount ?? 0
            let accepted: Bool
            if isAudio {
                accepted = try audioBoundary.append(sample, to: writer, finish: finish)
            } else {
                accepted = try writer?.append(sample, isAudio: false) ?? true
            }
            acceptedVideo += (writer?.acceptedVideoSampleCount ?? 0) - previousVideoCount
            acceptedAudio += audioBoundary.acceptedInputCount - previousAudioCount
            if !isAudio {
                if accepted {
                    lastTimestamp = pts.seconds
                    if let writer { audioBoundary.sawVideo(end: writer.end) }
                }
                else { backpressuredVideo += 1 }
            } else if !accepted { backpressuredAudio += 1 }
            if !isAudio, let collection, collection.cutoff == nil {
                collection.progress(max(0, collection.target - (writer?.end.seconds ?? lastTimestamp)))
            }
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
        let identifier = UUID()
        finalizing[identifier] = closing
        if let collection, closing.end.seconds > collection.start, closing.start.seconds < collection.target {
            collection.finalizers.insert(identifier)
        }
        let epoch = generation
        closing.finish { [weak self] result in
            guard let self else {
                if case .success(let segment) = result { ProtectedFiles.remove([segment.url]) }
                return
            }
            self.deliverCompletion { [self] in self.queue.async { [self] in
                guard epoch == self.generation else {
                    if case .success(let segment) = result { ProtectedFiles.remove([segment.url]) }
                    return
                }
                self.finalizing.removeValue(forKey: identifier)
                self.collection?.finalizers.remove(identifier)
                self.pending -= 1
                switch result {
                case .success(let segment):
                    self.index.insert(segment)
                    if let collection = self.collection {
                        self.index.extend(collection.token, startingAt: collection.start, endingAt: collection.target)
                    }
                    // Save pins boundary segments before any expiration pass.
                    if !self.freezing { ProtectedFiles.remove(self.index.prune(now: self.lastTimestamp).map(\.url)) }
                    if self.index.bytes > self.index.byteLimit {
                        // Leased pre-roll cannot be silently sacrificed to make
                        // a larger requested interval fit the completed quota.
                        self.cancelCollection(CameraError.writer("There is not enough temporary storage to preserve this entire moment. Choose a shorter buffer or post-roll."))
                        self.fail(CameraError.storage)
                        return
                    }
                    self.completeSnapshotIfReady()
                    self.completeCollectionIfReady()
                case .failure(let error):
                    self.cancelCollection(error)
                    self.fail(error)
                }
            } }
        }
    }

    func snapshot() async throws -> BufferSnapshot {
        try await withCheckedThrowingContinuation { continuation in queue.async { [self] in
            guard running, !freezing, collection == nil else { continuation.resume(throwing: CameraError.empty); return }
            freezing = true
            snapshotContinuation = continuation
            snapshotEnd = writer?.end.seconds ?? lastTimestamp
            closeAtSaveBoundary()
            completeSnapshotIfReady()
        } }
    }

    /// Registers one immutable media interval. Off keeps the established
    /// retrospective snapshot behavior; positive post-roll never freezes intake.
    func snapshot(postRoll: Double, onProgress: @escaping (Double) -> Void) async throws -> BufferSnapshot {
        if postRoll == 0 { return try await snapshot() }
        return try await snapshotKeepingIntake(postRoll: postRoll, onProgress: onProgress)
    }

    /// Shared fixed-interval seam for post-roll and the opt-in #11 comparison.
    /// Calling this explicitly with zero does not change production Off policy.
    func snapshotKeepingIntake(postRoll: Double = 0,
                               onProgress: @escaping (Double) -> Void = { _ in }) async throws -> BufferSnapshot {
        guard [0.0, 5, 10].contains(postRoll) else { throw CameraError.writer("Choose Off, 5 or 10 seconds of post-roll.") }
        let request = CollectionRequest()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in queue.async { [self] in
                guard !request.cancelled else { continuation.resume(throwing: CancellationError()); return }
                guard running, !freezing else { continuation.resume(throwing: CameraError.empty); return }
                guard collection == nil else { continuation.resume(throwing: CameraError.busy); return }
                let trigger = writer?.end.seconds ?? lastTimestamp
                guard trigger > 0 else { continuation.resume(throwing: CameraError.empty); return }
                let start = trigger - index.window
                let (token, _) = index.pin(startingAt: start, endingAt: trigger + postRoll)
                collection = Collection(request: request, token: token, start: start, target: trigger + postRoll,
                    deadline: now() + postRoll + 5, continuation: continuation, progress: onProgress)
                collection?.finalizers = Set(finalizing.compactMap { id, closing in
                    closing.end.seconds > start && closing.start.seconds < trigger + postRoll ? id : nil
                })
                onProgress(postRoll)
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
                timer.setEventHandler { [weak self] in self?.pollCollectionDeadline() }
                collectionTimer = timer; timer.resume()
                if postRoll == 0 {
                    collection?.cutoff = trigger
                    closeAtSaveBoundary()
                    completeCollectionIfReady()
                }
            } }
        }, onCancel: { [weak self] in
            request.cancel()
            guard let self else { return }
            self.queue.async {
                if self.collection?.request === request { self.cancelCollection(CancellationError()) }
            }
        })
    }

    private func closeAtSaveBoundary() {
        if let current = writer {
            writer = nil
            if audioEnabled { audioBoundary.rotate(current, at: now(), finish: finish) }
            else { finish(current) }
        } else { audioBoundary.flush(finish: finish) }
    }

    private func completeCollectionIfReady() {
        guard let collection, let cutoff = collection.cutoff, collection.finalizers.isEmpty,
              !audioBoundary.intersects(start: collection.start, end: cutoff) else { return }
        let selection = index.selection(for: collection.token)
        let actualEnd = min(cutoff, selection.map(\.end).max() ?? collection.start)
        self.collection = nil
        collectionTimer?.cancel(); collectionTimer = nil
        guard actualEnd > collection.start, !selection.isEmpty else {
            index.release(collection.token)
            collection.continuation.resume(throwing: CameraError.empty)
            if !running { resetStoppedMedia(snapshotError: CameraError.empty) }
            return
        }
        // Window carries the ORIGINAL requested start even after truncation.
        collection.continuation.resume(returning: BufferSnapshot(token: collection.token,
            segments: selection, end: actualEnd, window: actualEnd - collection.start, requestedEnd: collection.target))
        if !running { resetStoppedMedia(snapshotError: CameraError.empty) }
    }

    private func cancelCollection(_ error: Error) {
        guard let collection else { return }
        self.collection = nil
        collectionTimer?.cancel(); collectionTimer = nil
        index.release(collection.token)
        ProtectedFiles.remove((running ? index.prune(now: lastTimestamp) : index.clearUnpinned()).map(\.url))
        collection.continuation.resume(throwing: error)
        if !running { resetStoppedMedia(snapshotError: error) }
    }

    private func completeSnapshotIfReady() {
        guard freezing, pending == 0, !audioBoundary.waiting, let continuation = snapshotContinuation else { return }
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
        let collecting: Bool
        let leaseCount: Int
        let finalizingWriters: Int
        let receivedVideo: Int64
        let acceptedVideo: Int64
        let receivedAudio: Int64
        let acceptedAudio: Int64
        let saveDroppedVideo: Int64
        let backpressuredVideo: Int64
        let saveDroppedAudio: Int64
        let backpressuredAudio: Int64
    }
    func diagnostics() async throws -> Diagnostics {
        try await withCheckedThrowingContinuation { continuation in queue.async { [self] in
            do {
                continuation.resume(returning: Diagnostics(running: running, freezing: freezing,
                    pending: pending, segments: index.segments, diskBytes: try diskBytes(),
                    files: try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil),
                    collecting: collection != nil, leaseCount: index.leaseCount, finalizingWriters: finalizing.count, receivedVideo: receivedVideo, acceptedVideo: acceptedVideo,
                    receivedAudio: receivedAudio, acceptedAudio: acceptedAudio,
                    saveDroppedVideo: saveDroppedVideo, backpressuredVideo: backpressuredVideo,
                    saveDroppedAudio: saveDroppedAudio, backpressuredAudio: backpressuredAudio))
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
                if pending >= 2 || (freezing && !isAudio) { continuation.resume(returning: false); return }
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
