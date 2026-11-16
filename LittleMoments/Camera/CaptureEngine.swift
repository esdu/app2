import AVFoundation
import UIKit

/// Mutable capture state is confined to queue; callbacks are installed once before use.
final class CaptureEngine: NSObject, CameraService, AVCaptureVideoDataOutputSampleBufferDelegate,
                           AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let capture = AVCaptureSession()
    var session: AVCaptureSession? { capture }
    var onStatistics: ((CameraStatistics) -> Void)?
    var onInterruption: ((String) -> Void)?
    private let queue = DispatchQueue(label: "LittleMoments.capture", qos: .userInitiated)
    private let directory: URL
    private var index = SegmentIndex()
    private var writer: SegmentWriter?
    private var running = false
    private var audioEnabled = false
    private var pending = 0
    private var generation = UUID()
    private var startRequest = UUID()
    private var freezing = false
    private var snapshotContinuation: CheckedContinuation<BufferSnapshot, Error>?
    private var snapshotEnd: Double = 0
    private var lastTimestamp: Double = 0
    private var lastReport: Double = 0
    private var health: CaptureWatchdog?
    private var healthTimer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private let diskLimit: Int64 = 192 * 1_024 * 1_024

    override init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RollingSegments", isDirectory: true)
        super.init()
        // This directory contains only expendable buffer files, never saved clips.
        try? FileManager.default.removeItem(at: directory)
        try? ProtectedFiles.directory(directory)
        for name in [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.runtimeErrorNotification,
                     AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: name == AVAudioSession.interruptionNotification || name == AVAudioSession.mediaServicesWereResetNotification ? AVAudioSession.sharedInstance() : capture, queue: nil) { [weak self] _ in
                self?.queue.async { [weak self] in
                    self?.stopOnQueue()
                    self?.onInterruption?("Camera interrupted. Return to the app and tap Start Buffer to restart.")
                }
            })
        }
    }
    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    func start(audio: Bool, front: Bool, duration: Double) async throws {
        let request: UUID = await withCheckedContinuation { c in queue.async {
            self.startRequest = UUID(); c.resume(returning: self.startRequest)
        } }
        guard await Permissions.capture(audio: audio) else { throw CameraError.permission }
        guard await MainActor.run(body: { UIApplication.shared.applicationState == .active }) else {
            throw CameraError.writer("Camera startup paused. Tap Start Buffer after returning to the app.")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    guard request == startRequest else { throw CameraError.writer("Camera startup was canceled. Tap Start Buffer to restart.") }
                    stopOnQueue(invalidateStart: false)
                    index.window = duration
                    audioEnabled = audio
                    try configure(front: front, audio: audio)
                    capture.startRunning()
                    guard capture.isRunning else { throw CameraError.unavailable }
                    running = true
                    health = CaptureWatchdog(startedAt: ProcessInfo.processInfo.systemUptime)
                    let timer = DispatchSource.makeTimerSource(queue: queue)
                    timer.schedule(deadline: .now() + 1, repeating: 1)
                    timer.setEventHandler { [weak self] in
                        guard let self, self.running,
                              self.health?.timedOut(at: ProcessInfo.processInfo.systemUptime) == true else { return }
                        self.stopOnQueue()
                        self.onInterruption?("Camera frames stopped arriving. Tap Start Buffer to retry.")
                    }
                    healthTimer = timer
                    timer.resume()
                    continuation.resume()
                } catch { stopOnQueue(); continuation.resume(throwing: error) }
            }
        }
    }
    private func configure(front: Bool, audio: Bool) throws {
        capture.beginConfiguration()
        defer { capture.commitConfiguration() }
        capture.inputs.forEach { capture.removeInput($0) }
        capture.outputs.forEach { capture.removeOutput($0) }
        capture.sessionPreset = .hd1280x720
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video,
                                                   position: front ? .front : .back) else { throw CameraError.unavailable }
        let input = try AVCaptureDeviceInput(device: device)
        guard capture.canAddInput(input) else { throw CameraError.unavailable }
        capture.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        guard capture.canAddOutput(output) else { throw CameraError.unavailable }
        capture.addOutput(output)
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        if audio {
            guard let mic = AVCaptureDevice.default(for: .audio) else { throw CameraError.unavailable }
            let micInput = try AVCaptureDeviceInput(device: mic)
            guard capture.canAddInput(micInput) else { throw CameraError.unavailable }
            capture.addInput(micInput)
            let audioOutput = AVCaptureAudioDataOutput()
            audioOutput.setSampleBufferDelegate(self, queue: queue)
            guard capture.canAddOutput(audioOutput) else { throw CameraError.unavailable }
            capture.addOutput(audioOutput)
        }
    }
    func stop() async { await withCheckedContinuation { c in queue.async { self.stopOnQueue(); c.resume() } } }
    private func stopOnQueue(invalidateStart: Bool = true, snapshotError: Error = CameraError.empty) {
        if invalidateStart { startRequest = UUID() }
        running = false
        healthTimer?.cancel(); healthTimer = nil; health = nil
        capture.stopRunning()
        writer?.cancel(); writer = nil
        generation = UUID(); pending = 0
        lastTimestamp = 0; lastReport = 0
        if let c = snapshotContinuation { snapshotContinuation = nil; c.resume(throwing: snapshotError) }
        freezing = false
        ProtectedFiles.remove(index.clearUnpinned().map(\.url))
        onStatistics?(CameraStatistics(seconds: 0, bytes: index.bytes))
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard running, !freezing else { return }
        do {
            let isAudio = output is AVCaptureAudioDataOutput
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard pts.isNumeric else { return }
            let hostTime = ProcessInfo.processInfo.systemUptime
            if !isAudio {
                health?.sawVideo(at: hostTime)
                lastTimestamp = pts.seconds
                if let current = writer, pts.seconds - current.start.seconds >= 2 {
                    writer = nil
                    finish(current)
                }
                guard pending < 3 else { throw CameraError.writer("Video encoding is too slow. Buffering stopped.") }
                if writer == nil { writer = try SegmentWriter(sample: sampleBuffer, audioEnabled: audioEnabled, directory: directory) }
            }
            try writer?.append(sampleBuffer, isAudio: isAudio)
            if hostTime - lastReport >= 0.25 {
                lastReport = hostTime
                let diskBytes = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    .reduce(Int64(0)) { $0 + ProtectedFiles.bytes($1) }
                let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                    .volumeAvailableCapacityForImportantUsage ?? Int64.max
                guard diskBytes < diskLimit, capacity > 64 * 1_024 * 1_024 else { throw CameraError.storage }
                onStatistics?(CameraStatistics(seconds: min(index.window, index.duration + (writer.map { $0.end.seconds - $0.start.seconds } ?? 0)), bytes: diskBytes))
            }
        } catch { stopOnQueue(); onInterruption?(error.localizedDescription) }
    }
    private func finish(_ closing: SegmentWriter) {
        pending += 1
        let epoch = generation
        closing.finish { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard epoch == self.generation else {
                    if case .success(let segment) = result { ProtectedFiles.remove([segment.url]) }; return
                }
                self.pending -= 1
                switch result {
                case .success(let segment):
                    self.index.insert(segment)
                    // During save, pin before pruning any boundary segments.
                    if !self.freezing { ProtectedFiles.remove(self.index.prune(now: self.lastTimestamp).map(\.url)) }
                    self.completeSnapshotIfReady()
                case .failure(let error): self.stopOnQueue(snapshotError: error); self.onInterruption?(error.localizedDescription)
                }
            }
        }
    }
    func snapshot() async throws -> BufferSnapshot {
        try await withCheckedThrowingContinuation { c in
            queue.async { [self] in
                guard running, !freezing else { c.resume(throwing: CameraError.empty); return }
                freezing = true
                snapshotContinuation = c
                snapshotEnd = writer?.end.seconds ?? lastTimestamp
                if let current = writer { writer = nil; finish(current) }
                completeSnapshotIfReady()
            }
        }
    }
    private func completeSnapshotIfReady() {
        guard freezing, pending == 0, let c = snapshotContinuation else { return }
        snapshotContinuation = nil
        let (token, selection) = index.pin(endingAt: snapshotEnd)
        freezing = false
        guard !selection.isEmpty else { index.release(token); c.resume(throwing: CameraError.empty); return }
        c.resume(returning: BufferSnapshot(token: token, segments: selection, end: snapshotEnd, window: index.window))
    }
    func release(_ snapshot: BufferSnapshot) async {
        await withCheckedContinuation { c in queue.async { [self] in
            index.release(snapshot.token)
            let removed = running ? index.prune(now: lastTimestamp) : index.clearUnpinned()
            ProtectedFiles.remove(removed.map(\.url)); c.resume()
        } }
    }
}
