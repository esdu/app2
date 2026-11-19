#if DEBUG
import AVFoundation

/// Opt-in only through --uitesting in DEBUG builds. Never selected for normal launches.
// Mutable fixture state is used only by MainActor-isolated async methods.
final class SyntheticCamera: CameraService, @unchecked Sendable {
    var session: AVCaptureSession? { nil }
    var onStatistics: ((CameraStatistics) -> Void)?
    var onInterruption: ((String) -> Void)?
    private let denied: Bool
    private var fixture: URL?
    private var active = false
    init(denied: Bool = false) { self.denied = denied }
    @MainActor func start(audio: Bool, front: Bool, duration: Double) async throws {
        guard !denied else { throw CameraError.permission }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UITestCamera")
        try ProtectedFiles.directory(directory)
        if fixture == nil {
            let url = directory.appendingPathComponent(UUID().uuidString + ".mov")
            try await SyntheticMovie.write(to: url, audio: audio)
            fixture = url
        }
        active = true
        // Fixed statistics match the actual fixture and leave XCTest a quiescent UI.
        onStatistics?(CameraStatistics(seconds: 2, bytes: ProtectedFiles.bytes(fixture!)))
    }
    @MainActor func stop() async { active = false; onStatistics?(CameraStatistics(seconds: 0, bytes: 0)) }
    @MainActor func snapshot() async throws -> BufferSnapshot {
        guard active, let fixture else { throw CameraError.empty }
        return BufferSnapshot(token: UUID(), segments: [VideoSegment(id: UUID(), url: fixture, start: 0, end: 2,
                                                                    bytes: ProtectedFiles.bytes(fixture))], end: 2, window: 30)
    }
    func release(_ snapshot: BufferSnapshot) async { }
}

/// Deterministic color frames and optional sine wave, encoded with the real system codecs.
/// Used by UI tests and composition integration tests; it never accesses a camera.
enum SyntheticMovie {
    // The readiness override is a DEBUG-only fault seam for a permanently
    // backpressured input. Ordinary fixtures always use the encoder's signal.
    static func write(to url: URL, audio: Bool = false, timeout: TimeInterval = 20,
                      readiness: @escaping (AVAssetWriterInput) -> Bool = { $0.isReadyForMoreMediaData }) async throws {
        let encoding = try Encoding(url: url, audio: audio, timeout: timeout, readiness: readiness)
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in encoding.start(continuation) }
        }, onCancel: { encoding.cancel() })
    }

    /// AVFoundation drives each input on this dedicated queue. No cooperative
    /// task repeatedly polls readiness, and neither input waits for the other.
    private final class Encoding: @unchecked Sendable {
        private let queue = DispatchQueue(label: "SyntheticMovie.Encoding", qos: .userInitiated)
        private let writer: AVAssetWriter
        private let video: AVAssetWriterInput
        private let adaptor: AVAssetWriterInputPixelBufferAdaptor
        private let audio: AVAssetWriterInput?
        private let url: URL
        private let timeout: TimeInterval
        private let readiness: (AVAssetWriterInput) -> Bool
        private var continuation: CheckedContinuation<Void, Error>?
        private var timer: DispatchSourceTimer?
        private var cancelled = false
        private var settled = false
        private var finishing = false
        private var videoFrame = 0
        private var audioFrame = 0
        private var videoFinished = false
        private var audioFinished = false
        private var videoReady = false
        private var audioReady = false

        init(url: URL, audio: Bool, timeout: TimeInterval,
             readiness: @escaping (AVAssetWriterInput) -> Bool) throws {
            self.url = url; self.timeout = timeout; self.readiness = readiness
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            video = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 120])
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
                sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                                              kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 120])
            self.audio = audio ? AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000]) : nil
            writer.add(video)
            if let audioInput = self.audio { writer.add(audioInput) }
        }

        func start(_ continuation: CheckedContinuation<Void, Error>) {
            queue.async { [self] in
                self.continuation = continuation
                guard !self.cancelled else { self.settle(.failure(CancellationError())); return }
                guard self.writer.startWriting() else {
                    self.settle(.failure(self.writer.error ?? CameraError.unavailable)); return
                }
                self.writer.startSession(atSourceTime: .zero)
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + self.timeout)
                timer.setEventHandler { [weak self] in self?.timedOut() }
                self.timer = timer; timer.resume()
                self.video.requestMediaDataWhenReady(on: self.queue) { [weak self] in self?.pumpVideo() }
                self.audio?.requestMediaDataWhenReady(on: self.queue) { [weak self] in self?.pumpAudio() }
            }
        }

        func cancel() {
            queue.async { [self] in
                self.cancelled = true
                if self.continuation != nil { self.settle(.failure(CancellationError())) }
            }
        }

        private func pumpVideo() {
            guard !settled, !finishing, videoFrame < 60 else { return }
            do {
                while videoFrame < 60 {
                    videoReady = readiness(video)
                    guard videoReady else { break }
                    guard writer.status == .writing else { throw writer.error ?? CameraError.unavailable }
                    let pixel = try SyntheticMovie.pixel(frame: videoFrame, adaptor: adaptor)
                    guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(videoFrame), timescale: 30)) else {
                        throw writer.error ?? CameraError.unavailable
                    }
                    videoFrame += 1
                }
                if videoFrame == 60 { video.markAsFinished(); videoFinished = true; finishIfReady() }
            } catch { settle(.failure(error)) }
        }

        private func pumpAudio() {
            guard !settled, !finishing, audioFrame < 60, let audio else { return }
            do {
                while audioFrame < 60 {
                    audioReady = readiness(audio)
                    guard audioReady else { break }
                    guard writer.status == .writing else { throw writer.error ?? CameraError.unavailable }
                    guard audio.append(try SyntheticMovie.tone(frame: audioFrame)) else {
                        throw writer.error ?? CameraError.unavailable
                    }
                    audioFrame += 1
                }
                if audioFrame == 60 { audio.markAsFinished(); audioFinished = true; finishIfReady() }
            } catch { settle(.failure(error)) }
        }

        private func finishIfReady() {
            guard videoFrame == 60, audio == nil || audioFrame == 60 else { return }
            finishing = true
            writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
            writer.finishWriting { [weak self] in
                guard let self else { return }
                self.queue.async { [self] in
                    guard !self.settled else { return }
                    do {
                        guard self.writer.status == .completed else { throw self.writer.error ?? CameraError.unavailable }
                        try ProtectedFiles.protect(self.url)
                        self.settle(.success(()))
                    } catch { self.settle(.failure(error)) }
                }
            }
        }

        private func timedOut() {
            guard !settled else { return }
            let audioProgress = audio.map { "\(audioFrame)/60 ready=\(audioReady) encoderReady=\($0.isReadyForMoreMediaData)" } ?? "off"
            let status: String
            switch writer.status {
            case .unknown: status = "unknown"
            case .writing: status = "writing"
            case .completed: status = "completed"
            case .failed: status = "failed"
            case .cancelled: status = "cancelled"
            @unknown default: status = "unrecognized(\(writer.status.rawValue))"
            }
            let details = "stage=\(finishing ? "finishing" : "feeding") video=\(videoFrame)/60 ready=\(videoReady) encoderReady=\(video.isReadyForMoreMediaData) " +
                "audio=\(audioProgress) writerStatus=\(status) error=\(String(describing: writer.error))"
            settle(.failure(CameraError.writer("Synthetic media encoder timed out: " + details)))
        }

        private func settle(_ result: Result<Void, Error>) {
            guard !settled, let continuation else { return }
            settled = true; self.continuation = nil
            timer?.cancel(); timer = nil
            if case .failure = result {
                // markAsFinished on the request queue prevents further input
                // callbacks. Only unfinished inputs on a writing asset accept
                // EOF; failed/cancelled assets are safe with weak callbacks.
                if writer.status == .writing {
                    if !videoFinished { video.markAsFinished(); videoFinished = true }
                    if let audio, !audioFinished { audio.markAsFinished(); audioFinished = true }
                }
                writer.cancelWriting()
                ProtectedFiles.remove([url])
            }
            continuation.resume(with: result)
        }
    }

    private static func pixel(frame: Int, adaptor: AVAssetWriterInputPixelBufferAdaptor) throws -> CVPixelBuffer {
        var pixel: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess,
              let pixel else { throw CameraError.unavailable }
        CVPixelBufferLockBaseAddress(pixel, [])
        let base = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(pixel)
        for y in 0..<120 { for x in 0..<160 {
            let offset = y * rowBytes + x * 4
            base[offset] = 255; base[offset + 1] = UInt8(80 + frame * 2)
            base[offset + 2] = UInt8(x); base[offset + 3] = UInt8(y)
        } }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        return pixel
    }
    private static func tone(frame: Int) throws -> CMSampleBuffer {
        let count = 1_470
        var format = AudioStreamBasicDescription(mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var description: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &format, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description) == noErr,
              let description else { throw CameraError.unavailable }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count * 2,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: count * 2,
            flags: 0, blockBufferOut: &block) == kCMBlockBufferNoErr, let block else { throw CameraError.unavailable }
        let samples: [Int16] = (0..<count).map {
            Int16(sin(Double(frame * count + $0) * 440 * 2 * .pi / 44_100) * 3_000)
        }
        let status = samples.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                          dataLength: count * 2)
        }
        guard status == kCMBlockBufferNoErr else { throw CameraError.unavailable }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block,
            formatDescription: description, sampleCount: count,
            presentationTimeStamp: CMTime(value: Int64(frame * count), timescale: 44_100),
            packetDescriptions: nil, sampleBufferOut: &sample) == noErr, let sample else { throw CameraError.unavailable }
        return sample
    }
}
#endif
