import AVFoundation

/// A single compressed segment. Only accessed on CaptureEngine.queue.
protocol SegmentWriting: AnyObject {
    var start: CMTime { get }
    var end: CMTime { get }
    var url: URL { get }
    var acceptedVideoSampleCount: Int64 { get }
    var acceptedAudioSampleCount: Int64 { get }
    func append(_ sample: CMSampleBuffer, isAudio: Bool) throws -> Bool
    func finish(completion: @escaping (Result<VideoSegment, Error>) -> Void)
    func cancel()
}
extension SegmentWriting {
    // Fault wrappers may not expose counters. Concrete production writers do.
    var acceptedVideoSampleCount: Int64 { 0 }
    var acceptedAudioSampleCount: Int64 { 0 }
}

final class SegmentWriter: SegmentWriting {
    let writer: AVAssetWriter
    let video: AVAssetWriterInput
    let audio: AVAssetWriterInput?
    let start: CMTime
    private(set) var end: CMTime
    private var timeline = Timeline()
    private(set) var acceptedVideoSampleCount: Int64 = 0
    private(set) var acceptedAudioSampleCount: Int64 = 0
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
        // A microphone packet may straddle the first video frame. Preserve its
        // overlapping PCM frames instead of dropping the entire packet.
        guard let sample = try AudioSampleBoundary.trim(sample, startingAt: start, isAudio: isAudio) else { return true }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard let input = isAudio ? audio : video else { return true }
        guard input.isReadyForMoreMediaData else { return false }
        // A rejected sample must not consume its timestamp: manual retries use
        // exactly the same ingestion path and production still never waits.
        guard timeline.accept(pts.seconds, audio: isAudio) else { return true }
        guard input.append(sample) else { throw writer.error ?? CameraError.writer("Video encoding failed.") }
        if isAudio { acceptedAudioSampleCount += 1 } else { acceptedVideoSampleCount += 1 }
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
    func cancel() {
        if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Capture audio is uncompressed PCM: a range copy keeps sample timing and
/// channel layout intact while clipping at an exact audio-frame boundary.
enum AudioSampleBoundary {
    static func end(_ sample: CMSampleBuffer) -> CMTime {
        CMSampleBufferGetPresentationTimeStamp(sample) + CMSampleBufferGetDuration(sample)
    }
    static func trim(_ sample: CMSampleBuffer, startingAt start: CMTime,
                     isAudio: Bool) throws -> CMSampleBuffer? {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isNumeric else { return nil }
        guard pts < start else { return sample }
        guard isAudio, end(sample) > start,
              let description = CMSampleBufferGetFormatDescription(sample),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              format.pointee.mFormatID == kAudioFormatLinearPCM,
              format.pointee.mSampleRate.isFinite, format.pointee.mSampleRate > 0,
              format.pointee.mSampleRate <= Double(Int32.max) else { return nil }
        let rate = format.pointee.mSampleRate
        let offset = Int(CMTimeConvertScale(start - pts, timescale: Int32(rate), method: .roundAwayFromZero).value)
        let count = CMSampleBufferGetNumSamples(sample)
        guard offset >= 0, offset < count else { return nil }
        var trimmed: CMSampleBuffer?
        let status = CMSampleBufferCopySampleBufferForRange(allocator: kCFAllocatorDefault,
            sampleBuffer: sample, sampleRange: CFRange(location: offset, length: count - offset),
            sampleBufferOut: &trimmed)
        guard status == noErr, let trimmed else { throw CameraError.writer("Audio boundary trimming failed.") }
        return trimmed
    }
}

/// At most two closing writers wait for the microphone's media watermark:
/// the rollover boundary and a save cutoff immediately after that boundary.
/// This handles independent delegate ordering without unbounded packet queues or
/// waiting in a hardware callback. A missing microphone cannot retain a writer
/// past the next rotation (or the one-second health poll).
final class SegmentAudioBoundary {
    private struct Closing {
        let writer: SegmentWriting
        let deadline: Double
    }
    private var closing: [Closing] = []
    private var leading: [CMSampleBuffer] = []
    private var replay: [CMSampleBuffer] = []
    private var lastCountedPTS: CMTime?
    private var latestAudioEnd: CMTime?
    private(set) var acceptedInputCount: Int64 = 0

    var waiting: Bool { !closing.isEmpty }
    var waitingCount: Int { closing.count }

    func rotate(_ writer: SegmentWriting, at now: Double, finish: (SegmentWriting) -> Void) {
        // The aggregate recorder guard also counts these unfinished writers.
        // Never retain a third microphone boundary even if audio disappears.
        if closing.count >= 2 { finish(closing.removeFirst().writer) }
        if let latestAudioEnd, latestAudioEnd >= writer.end {
            finish(writer)
        } else {
            closing.append(Closing(writer: writer, deadline: now + 1))
        }
    }
    func intersects(start: Double, end: Double) -> Bool {
        closing.contains { $0.writer.start.seconds < end && $0.writer.end.seconds > start }
    }
    func prepare(_ writer: SegmentWriting) throws {
        // Microphone callbacks may lead video by more than one packet. Retain
        // only this bounded lookahead, never an entire segment's audio history.
        replay = leading.filter { AudioSampleBoundary.end($0) > writer.start }
        _ = try replayPending(to: writer)
    }
    private func replayPending(to writer: SegmentWriting) throws -> Bool {
        while let sample = replay.first {
            guard try appendIncoming(sample, to: writer) else { return false }
            replay.removeFirst()
        }
        return true
    }
    func sawVideo(end: CMTime) {
        leading.removeAll { AudioSampleBoundary.end($0) <= end }
    }
    func append(_ sample: CMSampleBuffer, to writer: SegmentWriting?,
                finish: (SegmentWriting) -> Void) throws -> Bool {
        if let writer, !(try replayPending(to: writer)) { return false }
        for boundary in closing {
            guard try appendIncoming(sample, to: boundary.writer) else { return false }
        }
        if let writer {
            guard try appendIncoming(sample, to: writer) else { return false }
        }
        if leading.last.map({ CMSampleBufferGetPresentationTimeStamp(sample) > CMSampleBufferGetPresentationTimeStamp($0) }) ?? true {
            leading.append(sample)
        }
        let audioEnd = AudioSampleBoundary.end(sample)
        if latestAudioEnd.map({ audioEnd > $0 }) ?? true { latestAudioEnd = audioEnd }
        if let writer { sawVideo(end: writer.end) }
        guard leading.count <= 64,
              leading.reduce(0, { $0 + CMSampleBufferGetTotalSampleSize($1) }) <= 2 * 1_024 * 1_024 else {
            throw CameraError.writer("Microphone timing moved too far ahead of video. Tap Start Buffer to retry.")
        }
        let ready = closing.filter { AudioSampleBoundary.end(sample) >= $0.writer.end }
        closing.removeAll { AudioSampleBoundary.end(sample) >= $0.writer.end }
        ready.forEach { finish($0.writer) }
        return true
    }
    private func appendIncoming(_ sample: CMSampleBuffer, to writer: SegmentWriting) throws -> Bool {
        let before = writer.acceptedAudioSampleCount
        let ready = try writer.append(sample, isAudio: true)
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if writer.acceptedAudioSampleCount > before,
           lastCountedPTS.map({ pts > $0 }) ?? true {
            // Count source inputs once, even if the same packet is split across
            // two writers or retried after one writer reported backpressure.
            acceptedInputCount += 1
            lastCountedPTS = pts
        }
        return ready
    }
    func poll(at now: Double, finish: (SegmentWriting) -> Void) {
        let expired = closing.filter { now >= $0.deadline }
        closing.removeAll { now >= $0.deadline }
        expired.forEach { finish($0.writer) }
    }
    func flush(finish: (SegmentWriting) -> Void) {
        let pending = closing; closing.removeAll()
        pending.forEach { finish($0.writer) }
    }
    func cancel() {
        closing.forEach { $0.writer.cancel() }; closing.removeAll()
        leading.removeAll(); replay.removeAll()
        lastCountedPTS = nil; latestAudioEnd = nil; acceptedInputCount = 0
    }
}
