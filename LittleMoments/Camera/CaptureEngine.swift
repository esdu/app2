import AVFoundation
import UIKit
import os

/// Mutable capture state is confined to queue; callbacks are installed once before use.
final class CaptureEngine: NSObject, CameraService, AVCaptureVideoDataOutputSampleBufferDelegate,
                           AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let capture = AVCaptureSession()
    var session: AVCaptureSession? { capture }
    var onStatistics: ((CameraStatistics) -> Void)?
    var onInterruption: ((String) -> Void)?
    private let queue = DispatchQueue(label: "LittleMoments.capture", qos: .userInitiated)
    private lazy var recorder = RollingRecorder(queue: queue)
    private var startRequest = UUID()
    private var healthTimer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []
    private var deliveryValidator: CaptureDeliveryValidator?
    private var droppedVideoFrames = 0
    private let configurationLog = Logger(subsystem: "org.littlemoments", category: "CaptureConfiguration")

    override init() {
        super.init()
        recorder.onStatistics = { [weak self] in self?.onStatistics?($0) }
        recorder.onFailure = { [weak self] error in
            guard let self else { return }
            self.stopOnQueue(snapshotError: error)
            self.onInterruption?(error.localizedDescription)
        }
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
                    try configure(front: front, audio: audio)
                    capture.startRunning()
                    guard capture.isRunning else { throw CameraError.unavailable }
                    recorder.start(audio: audio, duration: duration)
                    let timer = DispatchSource.makeTimerSource(queue: queue)
                    timer.schedule(deadline: .now() + 1, repeating: 1)
                    timer.setEventHandler { [weak self] in
                        self?.recorder.pollHealth()
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
        guard capture.canSetSessionPreset(.inputPriority) else {
            throw CameraError.writer("This camera cannot use an explicitly selected capture format. Switch cameras and retry.")
        }
        capture.sessionPreset = .inputPriority
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video,
                                                   position: front ? .front : .back) else { throw CameraError.unavailable }
        let input = try AVCaptureDeviceInput(device: device)
        guard capture.canAddInput(input) else { throw CameraError.unavailable }
        capture.addInput(input)
        let candidates = device.formats.enumerated().map { index, format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return CaptureFormatPolicy.Candidate(index: index, width: dimensions.width, height: dimensions.height,
                rates: format.videoSupportedFrameRateRanges.map { .init(minimum: $0.minFrameRate, maximum: $0.maxFrameRate) })
        }
        let selected = try CaptureFormatPolicy.select(candidates)
        try device.lockForConfiguration()
        do {
            defer { device.unlockForConfiguration() }
            device.activeFormat = device.formats[selected.index]
            device.activeVideoMinFrameDuration = CaptureFormatPolicy.frameDuration
            device.activeVideoMaxFrameDuration = CaptureFormatPolicy.frameDuration
            guard CMTimeCompare(device.activeVideoMinFrameDuration, CaptureFormatPolicy.frameDuration) == 0,
                  CMTimeCompare(device.activeVideoMaxFrameDuration, CaptureFormatPolicy.frameDuration) == 0 else {
                throw CameraError.writer("This camera could not apply a fixed 30 fps configuration. Switch cameras and retry.")
            }
        }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard capture.canAddOutput(output) else { throw CameraError.unavailable }
        capture.addOutput(output)
        let pixelFormat = try CaptureFormatPolicy.pixelFormat(supported: output.availableVideoPixelFormatTypes)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        guard let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) else {
            throw CameraError.writer("This camera cannot deliver the required portrait orientation. Switch cameras and retry.")
        }
        connection.videoRotationAngle = 90
        deliveryValidator = CaptureDeliveryValidator(width: selected.height, height: selected.width, pixelFormat: pixelFormat)
        let side = front ? "front" : "rear"
        let formatName = CaptureFormatPolicy.name(pixelFormat)
        configurationLog.notice("Selected \(side, privacy: .public) \(selected.width, privacy: .public)×\(selected.height, privacy: .public) at fixed 30 fps; portrait delivery \(selected.height, privacy: .public)×\(selected.width, privacy: .public), \(formatName, privacy: .public). Smaller dimensions or BGRA indicate supported fallback.")
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
        healthTimer?.cancel(); healthTimer = nil
        capture.stopRunning()
        deliveryValidator = nil
        droppedVideoFrames = 0
        recorder.stop(snapshotError: snapshotError)
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let isAudio = output is AVCaptureAudioDataOutput
        if !isAudio {
            do {
                guard deliveryValidator != nil else { return }
                try deliveryValidator?.validate(sampleBuffer)
                if let state = deliveryValidator, state.frames == 1 || state.frames % 150 == 0 {
                    let fps = state.observedFPS.map { String(format: "%.2f", $0) } ?? "pending"
                    let format = CaptureFormatPolicy.name(state.pixelFormat)
                    configurationLog.notice("Delivered \(state.width, privacy: .public)×\(state.height, privacy: .public), \(format, privacy: .public); frames \(state.frames, privacy: .public), observed fps \(fps, privacy: .public), delegate drops \(self.droppedVideoFrames, privacy: .public). First frame has no measured cadence.")
                }
            } catch {
                configurationLog.error("Video configuration validation failed: \(error.localizedDescription, privacy: .public)")
                stopOnQueue(snapshotError: error)
                onInterruption?(error.localizedDescription)
                return
            }
        }
        recorder.ingest(sampleBuffer, isAudio: isAudio)
    }
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard output is AVCaptureVideoDataOutput, deliveryValidator != nil else { return }
        droppedVideoFrames += 1
        if droppedVideoFrames == 1 || droppedVideoFrames % 30 == 0 {
            configurationLog.notice("Delegate dropped video frames: \(self.droppedVideoFrames, privacy: .public)")
        }
    }
    func snapshot() async throws -> BufferSnapshot { try await recorder.snapshot() }
    func release(_ snapshot: BufferSnapshot) async { await recorder.release(snapshot) }
}
