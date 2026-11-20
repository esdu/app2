import AVFoundation
import XCTest
@testable import LittleMoments

/// Content checks identify capture frames and tones after actual H.264/AAC decode.
/// Passthrough remains an opt-in trial: compatibility alone is not a correctness verdict.
final class ClipExportContentTests: XCTestCase {
    private var directory: URL!
    private var measurements: [String] = []
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Export-" + UUID().uuidString)
        try ProtectedFiles.directory(directory)
    }
    override func tearDownWithError() throws {
        let report = XCTAttachment(string: measurements.joined(separator: "\n"))
        report.name = "Export trial wall time, bytes, and decoded endpoints"
        report.lifetime = .keepAlways; add(report)
        if let run = testRun, run.failureCount > 0 {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where ["mov", "mp4"].contains(url.pathExtension) {
                let media = XCTAttachment(contentsOfFile: url); media.lifetime = .keepAlways; add(media)
            }
        }
        try FileManager.default.removeItem(at: directory)
    }
    private func segment(_ source: TimestampedSampleSource, frames: Range<Int>, audio: Bool) async throws -> VideoSegment {
        let writer = try SegmentWriter(sample: source.video(frame: frames.lowerBound), audioEnabled: audio, directory: directory)
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            for frame in frames {
                for isAudio in audio ? [false, true] : [false] {
                    let sample: CMSampleBuffer
                    if isAudio { sample = try source.audio(frame: frame) }
                    else { sample = try source.video(frame: frame) }
                    while try !writer.append(sample, isAudio: isAudio) {
                        guard ContinuousClock.now < deadline else { throw CameraError.writer("Fixture writer stalled") }
                        try await Task.sleep(for: .milliseconds(2))
                    }
                }
            }
            return try await withCheckedThrowingContinuation { continuation in writer.finish { continuation.resume(with: $0) } }
        } catch { writer.cancel(); throw error }
    }
    private final class ObservedSystemBackend: ClipExportBackend {
        let system = SystemClipExportBackend()
        var compatibility: Bool?
        var attempts: [String] = []
        func supportsPassthrough(_ asset: AVAsset) async -> Bool {
            let result = await system.supportsPassthrough(asset); compatibility = result; return result
        }
        func export(_ asset: AVAsset, preset: String, to destination: URL) async throws {
            attempts.append(preset); try await system.export(asset, preset: preset, to: destination)
        }
    }
    private func export(_ snapshot: BufferSnapshot, strategy: ClipExportStrategy, label: String) async throws -> URL {
        let output = directory.appendingPathComponent(label + ".mp4")
        let start = ContinuousClock.now
        let backend = ObservedSystemBackend()
        try await ClipComposer(strategy: strategy, backend: backend).compose(snapshot, to: output)
        let elapsed = start.duration(to: .now)
        measurements.append("\(label): strategy=\(strategy), wall=\(elapsed), bytes=\(ProtectedFiles.bytes(output)), compatible=\(String(describing: backend.compatibility)), attempts=\(backend.attempts)")
        return output
    }
    func testIndependentSegmentsSilentAndAudioBothExportStrategies() async throws {
        for audio in [false, true] {
            let source = TimestampedSampleSource(origin: 12_345)
            let first = try await segment(source, frames: 0..<20, audio: audio)
            let second = try await segment(source, frames: 20..<40, audio: audio)
            XCTAssertNotEqual(first.url, second.url)
            let snapshot = BufferSnapshot(token: UUID(), segments: [second, first], end: source.origin + 4, window: 4)
            for (name, strategy) in [("quality", ClipExportStrategy.highestQuality), ("trial", .evaluatePassthrough)] {
                let output = try await export(snapshot, strategy: strategy, label: "\(name)-audio-\(audio)")
                let video = try decodeVideo(output)
                XCTAssertEqual(video.map(\.marker), Array(0..<40))
                XCTAssertEqual(try XCTUnwrap(video.first).time, 0, accuracy: 0.003)
                XCTAssertEqual(try XCTUnwrap(video.last).time, 3.9, accuracy: 0.003)
                if audio { try assertTones(output, sections: [(0, 4, 0)]) }
                else { XCTAssertTrue(AVURLAsset(url: output).tracks(withMediaType: .audio).isEmpty) }
            }
        }
    }
    func testNonKeyframeRequestedEndpointsHaveNoEarlierOrMissingContent() async throws {
        let source = TimestampedSampleSource(origin: 50_000)
        let segment = try await segment(source, frames: 0..<40, audio: true)
        // .35 and 3.85 deliberately fall between sample/keyframe boundaries.
        let snapshot = BufferSnapshot(token: UUID(), segments: [segment], end: source.origin + 3.85, window: 3.5)
        for (name, strategy) in [("quality", ClipExportStrategy.highestQuality), ("trial", .evaluatePassthrough)] {
            let output = try await export(snapshot, strategy: strategy, label: "trim-\(name)")
            let video = try decodeVideo(output)
            // The frame spanning the requested first instant is marker 3;
            // marker 38 spans the tapped endpoint. Decoder preroll must not leak.
            XCTAssertEqual(try XCTUnwrap(video.first).marker, 3)
            XCTAssertEqual(try XCTUnwrap(video.last).marker, 38)
            XCTAssertTrue(video.allSatisfy { (3...38).contains($0.marker) })
            XCTAssertEqual(Set(video.map(\.marker)), Set(3...38))
            let duration = try await AVURLAsset(url: output).load(.duration)
            XCTAssertEqual(duration.seconds, 3.5, accuracy: 0.04)
            try assertTones(output, sections: [(0, 3.5, 0.35)])
        }
    }
    func testDelayedAudioAndSourceGapPreserveJoinSynchronization() async throws {
        let source = TimestampedSampleSource(origin: 91_000, audioOffset: 0.025, gaps: [20: 0.4])
        let first = try await segment(source, frames: 0..<20, audio: true)
        let second = try await segment(source, frames: 20..<40, audio: true)
        let snapshot = BufferSnapshot(token: UUID(), segments: [first, second], end: source.origin + 4.4, window: 10)
        for (name, strategy) in [("quality", ClipExportStrategy.highestQuality), ("trial", .evaluatePassthrough)] {
            let output = try await export(snapshot, strategy: strategy, label: "offset-gap-\(name)")
            let video = try decodeVideo(output)
            XCTAssertEqual(video.map(\.marker), Array(0..<40))
            XCTAssertEqual(try XCTUnwrap(video.first { $0.marker == 20 }).time, 2, accuracy: 0.005)
            let packets = try decodeAudio(output)
            XCTAssertEqual(try XCTUnwrap(packets.first).time, 0.025, accuracy: 0.03)
            // The .4 source gap collapses at the video join. Audio's own offset
            // and identifiable tone clock still translate with its video range.
            try assertTones(output, sections: [(0.15, 1.9, -0.025), (2.15, 3.9, 0.375)])
        }
    }

    /// Remux an actual production H.264 segment with front/rear portrait display
    /// metadata. This exercises exported orientation without camera hardware.
    private func oriented(_ segment: VideoSegment, transform: CGAffineTransform) async throws -> VideoSegment {
        let asset = AVURLAsset(url: segment.url)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        let rawFormat = try XCTUnwrap(track.formatDescriptions.first)
        let format = rawFormat as! CMFormatDescription
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        let url = directory.appendingPathComponent(UUID().uuidString + ".mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        input.transform = transform
        writer.add(input)
        guard writer.startWriting(), reader.startReading() else { throw writer.error ?? reader.error ?? CameraError.unavailable }
        writer.startSession(atSourceTime: .zero)
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        do {
            while let sample = output.copyNextSampleBuffer() {
                while !input.isReadyForMoreMediaData {
                    guard writer.status == .writing, ContinuousClock.now < deadline else { throw CameraError.unavailable }
                    try await Task.sleep(for: .milliseconds(2))
                }
                guard input.append(sample) else { throw writer.error ?? CameraError.unavailable }
            }
            guard reader.status == .completed else { throw reader.error ?? CameraError.unavailable }
            input.markAsFinished()
            writer.endSession(atSourceTime: CMTime(seconds: segment.duration, preferredTimescale: 60_000))
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? CameraError.unavailable }
            try ProtectedFiles.protect(url)
            return VideoSegment(id: UUID(), url: url, start: segment.start, end: segment.end, bytes: ProtectedFiles.bytes(url))
        } catch { writer.cancelWriting(); reader.cancelReading(); ProtectedFiles.remove([url]); throw error }
    }
    func testFrontAndRearPortraitDisplayGeometrySurvivesBothStrategies() async throws {
        let source = TimestampedSampleSource(origin: 8_000)
        let raw = try await segment(source, frames: 0..<20, audio: false)
        for (camera, transform) in [
            ("rear", CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 96, ty: 0)),
            ("front", CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0))
        ] {
            let portrait = try await oriented(raw, transform: transform)
            let snapshot = BufferSnapshot(token: UUID(), segments: [portrait], end: portrait.end, window: 10)
            let reference = CGRect(x: 0, y: 0, width: 128, height: 96).applying(transform).standardized
            for (name, strategy) in [("quality", ClipExportStrategy.highestQuality), ("trial", .evaluatePassthrough)] {
                let output = try await export(snapshot, strategy: strategy, label: "portrait-\(camera)-\(name)")
                let track = try XCTUnwrap(AVURLAsset(url: output).tracks(withMediaType: .video).first)
                let displayed = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform).standardized
                XCTAssertEqual(displayed.width, reference.width, accuracy: 1)
                XCTAssertEqual(displayed.height, reference.height, accuracy: 1)
                let image = try displayedImage(output, at: 1.3)
                let sourceImage = try displayedImage(portrait.url, at: 1.3)
                XCTAssertEqual(image.width, 96); XCTAssertEqual(image.height, 128)
                XCTAssertEqual(try visualMarkerGrid(image), try visualMarkerGrid(sourceImage),
                    "Portrait rotation and front-camera mirroring must preserve displayed frame content")
            }
        }
    }

    private func displayedImage(_ url: URL, at seconds: Double) throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600), actualTime: nil)
    }
    private func visualMarkerGrid(_ image: CGImage) throws -> [Bool] {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        // Sample centers rather than compression edges; rotated frame markers
        // become horizontal bars and front mirroring must match the reference.
        return stride(from: 4, to: height, by: 8).flatMap { y in
            stride(from: 4, to: width, by: 8).map { x in pixels[(y * width + x) * 4 + 1] > 128 }
        }
    }

    func testWindowBenchmarkMatrixAndRepeatedSavesWhileCaptureContinues() async throws {
        let recorder = RollingRecorder(queue: DispatchQueue(label: "ExportEvaluation"),
            directory: directory.appendingPathComponent("rolling"), now: { 1 })
        await withCheckedContinuation { continuation in
            recorder.queue.async { recorder.start(audio: true, duration: 120); continuation.resume() }
        }
        let source = TimestampedSampleSource(origin: 25_000, frameDuration: CMTime(value: 1, timescale: 2))
        func feed(_ frames: Range<Int>) async throws {
            for frame in frames {
                try await recorder.appendManually(source.video(frame: frame), isAudio: false)
                try await recorder.appendManually(source.audio(frame: frame), isAudio: true)
            }
        }
        try await feed(0..<2)
        let early = try await recorder.snapshot()
        for (name, strategy) in [("quality", ClipExportStrategy.highestQuality), ("trial", .evaluatePassthrough)] {
            let output = try await export(early, strategy: strategy, label: "early-\(name)")
            XCTAssertEqual(try decodeVideo(output).map(\.marker), [0, 1])
        }
        await recorder.release(early)
        try await feed(2..<240)
        var nextFrame = 240
        for window in [15.0, 30, 60, 120] {
            for (name, strategy) in [("quality", ClipExportStrategy.highestQuality), ("trial", .evaluatePassthrough)] {
                let leased = try await recorder.snapshot()
                let selection = BufferSnapshot(token: leased.token, segments: leased.segments,
                    end: leased.end, window: window)
                let expectedEnd = nextFrame
                async let output = export(selection, strategy: strategy, label: "window-\(Int(window))-\(name)")
                try await feed(nextFrame..<(nextFrame + 2)); nextFrame += 2
                let url = try await output
                XCTAssertTrue(leased.segments.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
                XCTAssertEqual(try decodeVideo(url).map(\.marker), Array((expectedEnd - Int(window * 2))..<expectedEnd))
                try assertTones(url, sections: [(0, window, Double(expectedEnd) / 2 - window)])
                let pressure = try await recorder.diagnostics()
                measurements.append("window=\(window) strategy=\(name): rolling-disk=\(pressure.diskBytes), segments=\(pressure.segments.count), pending=\(pressure.pending)")
                await recorder.release(leased)
            }
        }
        await withCheckedContinuation { continuation in recorder.queue.async { recorder.stop(); continuation.resume() } }
        let cleared = try await recorder.diagnostics(); XCTAssertTrue(cleared.files.isEmpty)
    }

    private struct Frame { let marker: Int; let time: Double }
    private func decodeVideo(_ url: URL) throws -> [Frame] {
        let asset = AVURLAsset(url: url)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var frames: [Frame] = []
        while let sample = output.copyNextSampleBuffer() {
            let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            XCTAssertEqual(CVPixelBufferGetWidth(image), TimestampedSampleSource.width)
            CVPixelBufferLockBaseAddress(image, .readOnly)
            let bytes = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(image) * (CVPixelBufferGetHeight(image) / 2)
            var marker = 0
            for bit in 0..<16 where bytes[row + (bit * 8 + 4) * 4 + 1] > 128 { marker |= 1 << bit }
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            frames.append(Frame(marker: marker, time: time))
        }
        XCTAssertEqual(reader.status, .completed)
        measurements.append("\(url.lastPathComponent): decoded=\(frames.count), first=\(String(describing: frames.first)), last=\(String(describing: frames.last))")
        return frames
    }
    private struct AudioPacket { let time: Double; let duration: Double; let rms: Double; let frequency: Double }
    private func decodeAudio(_ url: URL) throws -> [AudioPacket] {
        let asset = AVURLAsset(url: url)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .audio).first)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false])
        let reader = try AVAssetReader(asset: asset)
        reader.add(output); XCTAssertTrue(reader.startReading())
        var packets: [AudioPacket] = []
        while let sample = output.copyNextSampleBuffer() {
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            var values = [Int16](repeating: 0, count: CMBlockBufferGetDataLength(block) / 2)
            let status = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            XCTAssertEqual(status, kCMBlockBufferNoErr)
            let duration = Double(values.count) / 44_100
            let rms = sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, values.count)))
            let crossings = zip(values, values.dropFirst()).filter { $0.0 <= 0 && $0.1 > 0 }.count
            packets.append(AudioPacket(time: CMSampleBufferGetPresentationTimeStamp(sample).seconds,
                duration: duration, rms: rms, frequency: Double(crossings) / max(duration, 0.000001)))
        }
        XCTAssertEqual(reader.status, .completed); return packets
    }
    private func assertTones(_ url: URL, sections: [(start: Double, end: Double, sourceOffset: Double)]) throws {
        let packets = try decodeAudio(url)
        XCTAssertFalse(packets.isEmpty)
        for section in sections {
            let stable = packets.filter {
                let sourceTime = $0.time + section.sourceOffset
                let phase = sourceTime.truncatingRemainder(dividingBy: 1)
                return $0.time > section.start && $0.time < section.end && phase > 0.15 && phase < 0.8 && $0.duration > 0.01
            }
            XCTAssertFalse(stable.isEmpty)
            for packet in stable {
                XCTAssertGreaterThan(packet.rms, 3_000)
                XCTAssertEqual(packet.frequency, TimestampedSampleSource.frequency(at: packet.time + section.sourceOffset), accuracy: 65)
            }
        }
    }
}
