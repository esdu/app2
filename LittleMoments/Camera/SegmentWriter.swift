import AVFoundation

/// A single compressed segment. Only accessed on CaptureEngine.queue.
protocol SegmentWriting: AnyObject {
    var start: CMTime { get }
    var end: CMTime { get }
    var url: URL { get }
    func append(_ sample: CMSampleBuffer, isAudio: Bool) throws -> Bool
    func finish(completion: @escaping (Result<VideoSegment, Error>) -> Void)
    func cancel()
}

final class SegmentWriter: SegmentWriting {
    let writer: AVAssetWriter
    let video: AVAssetWriterInput
    let audio: AVAssetWriterInput?
    let start: CMTime
    private(set) var end: CMTime
    private var timeline = Timeline()
    let url: URL
    init(sample: CMSampleBuffer, audioEnabled: Bool, directory: URL) throws {
        url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        start = CMSampleBufferGetPresentationTimeStamp(sample)
        end = start
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        guard let format = CMSampleBufferGetFormatDescription(sample) else { throw CameraError.unavailable }
        let size = CMVideoFormatDescriptionGetDimensions(format)
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000,
                                             AVVideoMaxKeyFrameIntervalKey: 30]]
        // Keep camera-provided colorimetry. The image subtype/source hint carries
        // full/video range; no RGB conversion or invented range attachment occurs.
        var color: [String: Any] = [:]
        for (outputKey, sourceKey) in [(AVVideoColorPrimariesKey, kCMFormatDescriptionExtension_ColorPrimaries),
                                      (AVVideoTransferFunctionKey, kCMFormatDescriptionExtension_TransferFunction),
                                      (AVVideoYCbCrMatrixKey, kCMFormatDescriptionExtension_YCbCrMatrix)] {
            if let value = CMFormatDescriptionGetExtension(format, extensionKey: sourceKey) as? String {
                color[outputKey] = value
            }
        }
        if !color.isEmpty { videoSettings[AVVideoColorPropertiesKey] = color }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings, sourceFormatHint: format)
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw CameraError.unavailable }
        writer.add(video)
        if audioEnabled {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw CameraError.unavailable }
            writer.add(input)
            audio = input
        } else { audio = nil }
        guard writer.startWriting() else { throw writer.error ?? CameraError.unavailable }
        writer.startSession(atSourceTime: start)
        try ProtectedFiles.protect(url)
    }
    /// False means encoder backpressure. The real-time caller drops the sample;
    /// the manual harness may retry outside the capture queue with a deadline.
    @discardableResult func append(_ sample: CMSampleBuffer, isAudio: Bool) throws -> Bool {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isNumeric, pts >= start else { return true }
        guard let input = isAudio ? audio : video else { return true }
        guard input.isReadyForMoreMediaData else { return false }
        // A rejected sample must not consume its timestamp: manual retries use
        // exactly the same ingestion path and production still never waits.
        guard timeline.accept(pts.seconds, audio: isAudio) else { return true }
        guard input.append(sample) else { throw writer.error ?? CameraError.writer("Video encoding failed.") }
        if !isAudio {
            let duration = CMSampleBufferGetDuration(sample)
            end = pts + (duration.isNumeric && duration.seconds > 0 ? duration : CMTime(value: 1, timescale: 30))
        }
        return true
    }
    func finish(completion: @escaping (Result<VideoSegment, Error>) -> Void) {
        video.markAsFinished()
        audio?.markAsFinished()
        writer.endSession(atSourceTime: end)
        writer.finishWriting { [self] in
            guard writer.status == .completed, end > start else {
                try? FileManager.default.removeItem(at: url)
                completion(.failure(writer.error ?? CameraError.empty)); return
            }
            completion(.success(VideoSegment(id: UUID(), url: url, start: start.seconds,
                                             end: end.seconds, bytes: ProtectedFiles.bytes(url))))
        }
    }
    func cancel() { writer.cancelWriting(); try? FileManager.default.removeItem(at: url) }
}
