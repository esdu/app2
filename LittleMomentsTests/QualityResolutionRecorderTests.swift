import AVFoundation
import Darwin
import XCTest
@testable import LittleMoments

/// Actual portrait sample sizes, deliberately only 2 fps. This checks real codec
/// and recorder correctness; it does not model a camera or sustained 30 fps load.
private struct QualityResolutionSource {
    let width: Int
    let height: Int
    let markerBase: Int
    let clock = TimestampedSampleSource(frameDuration: CMTime(value: 1, timescale: 2))

    func video(frame: Int) throws -> CMSampleBuffer {
        var result: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result) == kCVReturnSuccess,
              let image = result else { throw CameraError.unavailable }
        CVBufferSetAttachment(image, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(image, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVPixelBufferLockBaseAddress(image, [])
        let luma = CVPixelBufferGetBaseAddressOfPlane(image, 0)!.assumingMemoryBound(to: UInt8.self)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(image, 1)!
        let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        memset(luma, 100, stride * height)
        memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(image, 1) * (height / 2))
        // A large upper stripe holds sixteen bits; the asymmetric lower corners
        // detect rotation/mirroring, independently of dimension metadata.
        let marker = markerBase + frame
        for y in (height / 16)..<(3 * height / 16) {
            for bit in 0..<16 {
                let start = bit * width / 16, end = (bit + 1) * width / 16
                memset(luma + y * stride + start, marker & (1 << bit) == 0 ? 16 : 235, end - start)
            }
        }
        for y in (3 * height / 4)..<height {
            memset(luma + y * stride, 235, width / 4)
            memset(luma + y * stride + 3 * width / 4, 16, width / 4)
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image,
            formatDescriptionOut: &description) == noErr, let description else { throw CameraError.unavailable }
        var timing = CMSampleTimingInfo(duration: clock.frameDuration,
            presentationTimeStamp: CMTime(seconds: clock.timestamp(frame: frame), preferredTimescale: 44_100),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image,
            formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { throw CameraError.unavailable }
        return sample
    }
}

final class QualityResolutionRecorderTests: XCTestCase {
    private var directory: URL!
    private var recorders: [RollingRecorder] = []
    private var leases: [(RollingRecorder, BufferSnapshot)] = []
    private var evidence: [String] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Quality-" + UUID().uuidString)
        try ProtectedFiles.directory(directory)
    }
    override func tearDown() async throws {
        // Preserve failing sources before stop/release removes leased files.
        if let run = testRun, run.failureCount > 0 {
            let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
            while let url = files?.nextObject() as? URL {
                if ["mov", "mp4"].contains(url.pathExtension) {
                    let attachment = XCTAttachment(contentsOfFile: url)
                    attachment.lifetime = .keepAlways; add(attachment)
                }
            }
        }
        for recorder in recorders { await perform(recorder) { recorder.stop() } }
        for (recorder, snapshot) in leases { await recorder.release(snapshot) }
        let log = XCTAttachment(string: evidence.joined(separator: "\n"))
        log.name = "Actual-resolution codec correctness (2 fps, not device performance)"
        log.lifetime = .keepAlways; add(log)
        try FileManager.default.removeItem(at: directory)
        recorders = []; leases = []; evidence = []
    }

    func testPortrait720pEarlyBoundaryAndFullWindowTrimming() async throws {
        try await roundTrip(width: 720, height: 1280)
    }
    func testPortrait1080pEarlyBoundaryAndFullWindowTrimming() async throws {
        try await roundTrip(width: 1080, height: 1920)
    }

    private func makeRecorder() -> RollingRecorder {
        let recorder = RollingRecorder(queue: DispatchQueue(label: "Quality." + UUID().uuidString),
            directory: directory.appendingPathComponent(UUID().uuidString))
        recorders.append(recorder)
        return recorder
    }
    private func perform(_ recorder: RollingRecorder, _ body: @escaping () -> Void) async {
        await withCheckedContinuation { continuation in recorder.queue.async { body(); continuation.resume() } }
    }
    private func feed(_ recorder: RollingRecorder, source: QualityResolutionSource,
                      frames: Range<Int>, audio: Bool) async throws {
        for frame in frames {
            let video = try autoreleasepool { try source.video(frame: frame) }
            try await recorder.appendManually(video, isAudio: false)
            if audio { try await recorder.appendManually(source.clock.audio(frame: frame), isAudio: true) }
        }
    }
    private func snapshot(_ recorder: RollingRecorder) async throws -> BufferSnapshot {
        let snapshot = try await recorder.snapshot()
        leases.append((recorder, snapshot))
        evidence.append("snapshot end=\(snapshot.end) window=\(snapshot.window) sources=\(snapshot.segments.map { "\($0.start)...\($0.end) \($0.url.lastPathComponent)" })")
        return snapshot
    }
    private func release(_ recorder: RollingRecorder, _ snapshot: BufferSnapshot) async {
        await recorder.release(snapshot)
        leases.removeAll { $0.1.token == snapshot.token }
    }

    private func roundTrip(width: Int, height: Int) async throws {
        let recorder = makeRecorder()
        let source = QualityResolutionSource(width: width, height: height, markerBase: 0)
        // 0.5s warmup; immediately before/after the 2s boundary; then a full 15s
        // window whose beginning trims a non-keyframe inside a source segment.
        // Each starts fresh so prior snapshots cannot shift the rollover boundary.
        for endpoint in [1, 4, 5, 37] {
            await perform(recorder) { recorder.start(audio: true, duration: 15) }
            try await feed(recorder, source: source, frames: 0..<endpoint, audio: true)
            let selected = try await snapshot(recorder)
            let first = max(0, endpoint - 30)
            XCTAssertEqual(selected.end, source.clock.origin + Double(endpoint) / 2, accuracy: 0.001)
            XCTAssertEqual(selected.window, 15)
            if endpoint == 5 {
                XCTAssertEqual(selected.segments.count, 2)
                XCTAssertEqual(try XCTUnwrap(selected.segments.first).end, source.clock.origin + 2, accuracy: 0.001)
                XCTAssertEqual(try XCTUnwrap(selected.segments.last).start, source.clock.origin + 2, accuracy: 0.001)
            }
            if first > 0 {
                XCTAssertLessThan(try XCTUnwrap(selected.segments.first).start, source.clock.timestamp(frame: first))
                XCTAssertGreaterThan(selected.segments.count, 1)
            }
            let output = directory.appendingPathComponent("\(width)-\(endpoint).mp4")
            try await ClipComposer().compose(selected, to: output)
            try verify(output, source: source, frames: first..<endpoint, audio: true)
            XCTAssertTrue(selected.segments.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
            await release(recorder, selected)
            await perform(recorder) { recorder.stop() }
            let cleared = try await recorder.diagnostics()
            XCTAssertTrue(cleared.files.isEmpty); XCTAssertTrue(cleared.segments.isEmpty)
        }
        await perform(recorder) { recorder.stop() }
        let state = try await recorder.diagnostics()
        XCTAssertFalse(state.running); XCTAssertTrue(state.files.isEmpty)
        XCTAssertTrue(state.segments.isEmpty); XCTAssertEqual(state.diskBytes, 0)
    }

    func testStoppedResolutionChangesCannotMixOldLeasedGenerations() async throws {
        let recorder = makeRecorder()
        var oldFiles: Set<URL> = []
        // The same media timestamps recur deliberately. Old pinned files must
        // survive restart, but cannot leak into the next resolution/audio intent.
        for (generation, dimensions) in [(720, 1280), (1080, 1920), (720, 1280)].enumerated() {
            let source = QualityResolutionSource(width: dimensions.0, height: dimensions.1, markerBase: generation * 64)
            let audio = generation != 1
            await perform(recorder) { recorder.start(audio: audio, duration: 15) }
            try await feed(recorder, source: source, frames: 0..<6, audio: audio)
            let selected = try await snapshot(recorder)
            let files = Set(selected.segments.map(\.url))
            XCTAssertTrue(files.isDisjoint(with: oldFiles))
            XCTAssertTrue(oldFiles.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
            await perform(recorder) { recorder.stop() }
            let output = directory.appendingPathComponent("generation-\(generation).mp4")
            try await ClipComposer().compose(selected, to: output)
            try verify(output, source: source, frames: 0..<6, audio: audio)
            oldFiles.formUnion(files)
        }
        for (_, selected) in leases { await recorder.release(selected) }
        leases.removeAll()
        XCTAssertTrue(oldFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        let state = try await recorder.diagnostics()
        XCTAssertTrue(state.files.isEmpty); XCTAssertTrue(state.segments.isEmpty)
    }

    private func verify(_ url: URL, source: QualityResolutionSource, frames expected: Range<Int>, audio: Bool) throws {
        let asset = AVURLAsset(url: url)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        XCTAssertEqual(track.naturalSize, CGSize(width: CGFloat(source.width), height: CGFloat(source.height)))
        let display = CGRect(origin: .zero, size: track.naturalSize).applying(track.preferredTransform)
        XCTAssertEqual(abs(display.width), CGFloat(source.width), accuracy: 0.1)
        XCTAssertEqual(abs(display.height), CGFloat(source.height), accuracy: 0.1)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var markers: [Int] = []
        while let sample = output.copyNextSampleBuffer() {
            let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            XCTAssertEqual(CVPixelBufferGetWidth(image), source.width)
            XCTAssertEqual(CVPixelBufferGetHeight(image), source.height)
            CVPixelBufferLockBaseAddress(image, .readOnly)
            let bytes = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(image)
            var marker = 0
            for bit in 0..<16 {
                let x = (2 * bit + 1) * source.width / 32
                if bytes[(source.height / 8) * stride + x * 4 + 1] > 128 { marker |= 1 << bit }
            }
            XCTAssertGreaterThan(bytes[(7 * source.height / 8) * stride + (source.width / 8) * 4 + 1], 200)
            XCTAssertLessThan(bytes[(7 * source.height / 8) * stride + (7 * source.width / 8) * 4 + 1], 50)
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
            XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample).seconds, Double(markers.count) / 2, accuracy: 0.003)
            markers.append(marker)
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(markers, expected.map { source.markerBase + $0 })
        let duration = Double(expected.count) / 2
        XCTAssertEqual(track.timeRange.start.seconds, 0, accuracy: 0.003)
        XCTAssertEqual(track.timeRange.duration.seconds, duration, accuracy: 0.04)
        let tracks = asset.tracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, audio ? 1 : 0)
        if let audioTrack = tracks.first {
            try verifyAudio(asset, track: audioTrack, sourceStart: Double(expected.lowerBound) / 2, duration: duration)
        }
        evidence.append("\(url.lastPathComponent): \(source.width)x\(source.height), ids=\(markers), duration=\(track.timeRange.duration.seconds), audio=\(tracks.count), bytes=\(ProtectedFiles.bytes(url))")
    }

    private func verifyAudio(_ asset: AVAsset, track: AVAssetTrack, sourceStart: Double, duration: Double) throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var end = 0.0, count = 0, identified = 0
        while let sample = output.copyNextSampleBuffer() {
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            var values = [Int16](repeating: 0, count: CMBlockBufferGetDataLength(block) / 2)
            XCTAssertEqual(values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }, kCMBlockBufferNoErr)
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let packetDuration = Double(values.count) / 44_100
            XCTAssertEqual(time, end, accuracy: 0.03, "Audio gap or misaligned start")
            let phase = (sourceStart + time).truncatingRemainder(dividingBy: 1)
            if phase > 0.1, phase + packetDuration < 0.85, packetDuration > 0.01 {
                let rms = sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(values.count))
                let crossings = zip(values, values.dropFirst()).filter { $0.0 <= 0 && $0.1 > 0 }.count
                XCTAssertGreaterThan(rms, 3_000)
                XCTAssertEqual(Double(crossings) / packetDuration,
                    TimestampedSampleSource.frequency(at: sourceStart + time), accuracy: 65)
                identified += 1
            }
            end = time + packetDuration; count += 1
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertGreaterThan(count, 0); XCTAssertGreaterThan(identified, 0)
        XCTAssertEqual(end, duration, accuracy: 0.06)
    }
}
