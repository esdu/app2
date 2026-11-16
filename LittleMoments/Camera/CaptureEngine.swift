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
    private lazy var recorder = RollingRecorder(queue: queue)
    private var startRequest = UUID()
    private var healthTimer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []

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
        healthTimer?.cancel(); healthTimer = nil
        capture.stopRunning()
        recorder.stop(snapshotError: snapshotError)
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        recorder.ingest(sampleBuffer, isAudio: output is AVCaptureAudioDataOutput)
    }
    func snapshot() async throws -> BufferSnapshot { try await recorder.snapshot() }
    func release(_ snapshot: BufferSnapshot) async { await recorder.release(snapshot) }
}
