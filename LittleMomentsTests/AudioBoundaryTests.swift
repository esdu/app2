import AVFoundation
import XCTest
@testable import LittleMoments

final class AudioBoundaryTests: XCTestCase {
    func testOverlappingPCMRetainsFramesAtSessionStart() throws {
        let source = TimestampedSampleSource(origin: 999.997,
            frameDuration: CMTime(value: 441, timescale: 44_100))
        let sample = try source.audio(frame: 0)
        let start = CMTime(seconds: 1_000, preferredTimescale: 44_100)
        let tail = try XCTUnwrap(AudioSampleBoundary.trim(sample, startingAt: start, isAudio: true))
        let dropped = CMTimeConvertScale(start - CMSampleBufferGetPresentationTimeStamp(sample),
            timescale: 44_100, method: .roundAwayFromZero).value
        XCTAssertEqual(CMSampleBufferGetNumSamples(tail), 441 - Int(dropped))
        XCTAssertGreaterThanOrEqual(CMSampleBufferGetPresentationTimeStamp(tail), start)
        XCTAssertLessThan((CMSampleBufferGetPresentationTimeStamp(tail) - start).seconds, 1.0 / 44_100)
        XCTAssertEqual(AudioSampleBoundary.end(tail).seconds, AudioSampleBoundary.end(sample).seconds, accuracy: 1.0 / 44_100)
        XCTAssertNil(try AudioSampleBoundary.trim(sample,
            startingAt: CMTime(seconds: 1_001, preferredTimescale: 44_100), isAudio: true))
    }

    private final class Writer: SegmentWriting {
        let start: CMTime
        let end: CMTime
        let url = URL(fileURLWithPath: "/unused")
        var audio: [CMSampleBuffer] = []
        var acceptedAudioSampleCount: Int64 { Int64(audio.count) }
        var cancelled = false
        init(_ start: Double, _ end: Double) {
            self.start = CMTime(seconds: start, preferredTimescale: 44_100)
            self.end = CMTime(seconds: end, preferredTimescale: 44_100)
        }
        func append(_ sample: CMSampleBuffer, isAudio: Bool) throws -> Bool {
            if isAudio { audio.append(sample) }; return true
        }
        func finish(completion: @escaping (Result<VideoSegment, Error>) -> Void) { }
        func cancel() { cancelled = true }
    }

    func testLateAudioReachesBothBoundaryWritersBeforeFinishing() throws {
        let router = SegmentAudioBoundary()
        let old = Writer(1_000, 1_002), next = Writer(1_002, 1_004)
        var finished: [SegmentWriting] = []
        router.rotate(old, at: 50) { finished.append($0) }
        try router.prepare(next)
        XCTAssertTrue(router.waiting); XCTAssertTrue(finished.isEmpty)
        let audio = try TimestampedSampleSource(origin: 1_001.997,
            frameDuration: CMTime(value: 441, timescale: 44_100)).audio(frame: 0)
        XCTAssertTrue(try router.append(audio, to: next) { finished.append($0) })
        XCTAssertEqual(old.audio.count, 1); XCTAssertEqual(next.audio.count, 1)
        XCTAssertEqual(finished.count, 1); XCTAssertTrue(finished.first === old)
        XCTAssertFalse(router.waiting)
        XCTAssertEqual(router.acceptedInputCount, 1)
    }

    func testSaveImmediatelyAfterRolloverWaitsForBothAudioBoundaries() throws {
        let router = SegmentAudioBoundary()
        let old = Writer(1_000, 1_002), current = Writer(1_002, 1_002.033333)
        var finished: [SegmentWriting] = []
        router.rotate(old, at: 50) { finished.append($0) }
        router.rotate(current, at: 50.01) { finished.append($0) }
        XCTAssertEqual(router.waitingCount, 2); XCTAssertTrue(finished.isEmpty)
        let source = TimestampedSampleSource(origin: 1_001.997,
            frameDuration: CMTime(value: 441, timescale: 44_100))
        for packet in 0..<5 {
            XCTAssertTrue(try router.append(source.audio(frame: packet), to: nil) { finished.append($0) })
        }
        XCTAssertEqual(finished.count, 2)
        XCTAssertEqual(old.audio.count, 1)
        XCTAssertGreaterThan(current.audio.count, 1)
        XCTAssertFalse(router.waiting)
    }

    func testMultipleLeadingPacketsReplayWithoutDoubleCountingInputs() throws {
        let router = SegmentAudioBoundary()
        let old = Writer(1_000, 1_002), next = Writer(1_002, 1_004)
        let source = TimestampedSampleSource(origin: 1_001.997,
            frameDuration: CMTime(value: 441, timescale: 44_100))
        for packet in 0..<3 {
            XCTAssertTrue(try router.append(source.audio(frame: packet), to: old) { _ in })
        }
        var finished = 0
        router.rotate(old, at: 50) { _ in finished += 1 }
        try router.prepare(next)
        XCTAssertEqual(finished, 1)
        XCTAssertEqual(next.audio.count, 3)
        XCTAssertEqual(router.acceptedInputCount, 3)
    }

    func testAudioBeforeFirstVideoIsCountedWhenLookaheadIsEncoded() throws {
        let router = SegmentAudioBoundary(), writer = Writer(1_000, 1_000)
        let source = TimestampedSampleSource(frameDuration: CMTime(value: 441, timescale: 44_100))
        for packet in 0..<3 {
            XCTAssertTrue(try router.append(source.audio(frame: packet), to: nil) { _ in })
        }
        XCTAssertEqual(router.acceptedInputCount, 0)
        try router.prepare(writer)
        XCTAssertEqual(writer.audio.count, 3)
        XCTAssertEqual(router.acceptedInputCount, 3)
    }

    func testAudioLookaheadIsBoundedWhenVideoStopsAdvancing() throws {
        let router = SegmentAudioBoundary(), writer = Writer(1_000, 1_000)
        let source = TimestampedSampleSource(frameDuration: CMTime(value: 441, timescale: 44_100))
        for packet in 0..<64 {
            XCTAssertTrue(try router.append(source.audio(frame: packet), to: writer) { _ in })
        }
        XCTAssertThrowsError(try router.append(source.audio(frame: 64), to: writer) { _ in })
        router.cancel()
        XCTAssertEqual(router.acceptedInputCount, 0)
    }

    func testMissingMicrophoneReleasesClosingWriterAndCancelReleasesLookahead() throws {
        let router = SegmentAudioBoundary(), old = Writer(1_000, 1_002)
        var finished = 0
        router.rotate(old, at: 50) { _ in finished += 1 }
        router.poll(at: 50.99) { _ in finished += 1 }
        XCTAssertEqual(finished, 0)
        router.poll(at: 51) { _ in finished += 1 }
        XCTAssertEqual(finished, 1); XCTAssertFalse(router.waiting)
        let next = Writer(1_002, 1_004)
        router.rotate(next, at: 52) { _ in finished += 1 }
        router.cancel()
        XCTAssertTrue(next.cancelled); XCTAssertFalse(router.waiting)
    }

    func testProductionAudioPacketsLaggingVideoRemainContinuousAcrossRollovers() async throws {
        try await roundTrip(audioDeliveryDelay: 0.04)
    }
    func testProductionAudioPacketsLeadingVideoRemainContinuousAcrossRollovers() async throws {
        try await roundTrip(audioDeliveryDelay: -0.04)
    }

    private func roundTrip(audioDeliveryDelay: Double) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AudioBoundary-" + UUID().uuidString)
        try ProtectedFiles.directory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = RollingRecorder(queue: DispatchQueue(label: "AudioBoundaryTest"),
            directory: directory.appendingPathComponent("buffer"))
        await withCheckedContinuation { continuation in recorder.queue.async {
            recorder.start(audio: true, duration: 15); continuation.resume()
        } }
        let video = TimestampedSampleSource(frameDuration: CMTime(value: 1, timescale: 30))
        // Independent 10 ms PCM packets straddle every 30 fps/two-second video
        // boundary. Delivery delay is independent of the media timestamp.
        let audio = TimestampedSampleSource(origin: video.origin - 0.013,
            frameDuration: CMTime(value: 441, timescale: 44_100))
        var packet = 0
        let frameCount = 183
        for frame in 0..<frameCount {
            try await recorder.appendManually(video.video(frame: frame), isAudio: false)
            while audio.timestamp(frame: packet) + audioDeliveryDelay <= video.timestamp(frame: frame) {
                try await recorder.appendManually(audio.audio(frame: packet), isAudio: true)
                packet += 1
            }
        }
        let cutoff = video.origin + Double(frameCount) / 30
        while audio.timestamp(frame: packet) < cutoff {
            try await recorder.appendManually(audio.audio(frame: packet), isAudio: true)
            packet += 1
        }
        let snapshot = try await recorder.snapshot()
        let output = directory.appendingPathComponent("audio.mp4")
        try await ClipComposer().compose(snapshot, to: output)
        try assertDecodedBoundaryAudio(output, duration: Double(frameCount) / 30)
        if (testRun?.failureCount ?? 0) > 0 {
            let attachment = XCTAttachment(contentsOfFile: output); attachment.lifetime = .keepAlways; add(attachment)
        }
        await recorder.release(snapshot)
        await withCheckedContinuation { continuation in recorder.queue.async {
            recorder.stop(); continuation.resume()
        } }
        let state = try await recorder.diagnostics()
        XCTAssertTrue(state.files.isEmpty)
    }

    private func assertDecodedBoundaryAudio(_ url: URL, duration: Double) throws {
        let asset = AVURLAsset(url: url)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var energy = [Double](repeating: 0, count: 3)
        var counts = [Int](repeating: 0, count: 3)
        var previousEnd: Double?
        while let sample = output.copyNextSampleBuffer() {
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            var values = [Int16](repeating: 0, count: CMBlockBufferGetDataLength(block) / 2)
            XCTAssertEqual(values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }, kCMBlockBufferNoErr)
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if let previousEnd { XCTAssertEqual(start, previousEnd, accuracy: 2.0 / 44_100) }
            previousEnd = start + Double(values.count) / 44_100
            for (index, value) in values.enumerated() {
                let time = start + Double(index) / 44_100
                for boundary in 1...3 where abs(time - Double(boundary * 2)) < 0.010 {
                    energy[boundary - 1] += Double(value) * Double(value)
                    counts[boundary - 1] += 1
                }
            }
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(try XCTUnwrap(previousEnd), duration, accuracy: 0.03)
        for boundary in 0..<3 {
            XCTAssertGreaterThan(counts[boundary], 800, "Missing PCM near rollover \(boundary + 1)")
            let rms = sqrt(energy[boundary] / Double(max(1, counts[boundary])))
            XCTAssertGreaterThan(rms, 4_000, "Audio gap near rollover \(boundary + 1)")
        }
    }
}
