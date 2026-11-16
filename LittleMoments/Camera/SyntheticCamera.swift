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
    static func write(to url: URL, audio: Bool = false) async throws {
        try await Task.detached(priority: .userInitiated) {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 120])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
                sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                                              kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 120])
            writer.add(video)
            let audioInput: AVAssetWriterInput? = audio ? AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000]) : nil
            if let audioInput { writer.add(audioInput) }
            guard writer.startWriting() else { throw writer.error ?? CameraError.unavailable }
            writer.startSession(atSourceTime: .zero)
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            do {
                // Each input must advance independently and signal EOF independently.
                // Waiting on one track inside the other's pump can deadlock interleaving.
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for frame in 0..<60 {
                            try await waitUntilReady(video, writer: writer, deadline: deadline)
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
                            guard adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                                throw writer.error ?? CameraError.unavailable
                            }
                        }
                        video.markAsFinished()
                    }
                    if let audioInput { group.addTask {
                        for frame in 0..<60 {
                            try await waitUntilReady(audioInput, writer: writer, deadline: deadline)
                            guard audioInput.append(try tone(frame: frame)) else { throw writer.error ?? CameraError.unavailable }
                        }
                        audioInput.markAsFinished()
                    } }
                    try await group.waitForAll()
                }
                writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
                await writer.finishWriting()
                guard writer.status == .completed else { throw writer.error ?? CameraError.unavailable }
                try ProtectedFiles.protect(url)
            } catch {
                writer.cancelWriting(); ProtectedFiles.remove([url]); throw error
            }
        }.value
    }
    private static func waitUntilReady(_ input: AVAssetWriterInput, writer: AVAssetWriter,
                                       deadline: ContinuousClock.Instant) async throws {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard writer.status == .writing else { throw writer.error ?? CameraError.unavailable }
            guard ContinuousClock.now < deadline else { throw CameraError.writer("Synthetic media encoder timed out.") }
            try await Task.sleep(for: .milliseconds(2))
        }
        try Task.checkCancellation()
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
