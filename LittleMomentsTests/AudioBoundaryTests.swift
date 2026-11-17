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
        defer { try? FileManager.default.removeItem(at: directory) }
        try ProtectedFiles.directory(directory)
        let recorder = RollingRecorder(queue: DispatchQueue(label: "AudioBoundaryTest"),
            directory: directory.appendingPathComponent("buffer"))
        var snapshot: BufferSnapshot?
        var failure: Error?
        var timing = ["audio delivery delay=\(audioDeliveryDelay)"]
        let failuresBefore = testRun?.failureCount ?? 0
        var attachedEvidence = false
        do {
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
            timing.append("fed video frames=\(frameCount), PCM packets=\(packet), cutoff=\(cutoff)")
            let leased = try await recorder.snapshot()
            snapshot = leased
            timing.append("snapshot end=\(leased.end), segments=\(leased.segments)")
            let output = directory.appendingPathComponent("audio.mp4")
            try await ClipComposer().compose(leased, to: output)
            try assertDecodedBoundaryAudio(output, duration: Double(frameCount) / 30, timing: &timing)
        } catch {
            failure = error
            timing.append("run error: \(error)")
        }
        if failure != nil || (testRun?.failureCount ?? 0) > failuresBefore {
            // Preserve source MOVs and partial exports before stop/release can
            // delete them, including failures thrown before decoding starts.
            attachFailureEvidence(in: directory, timing: timing)
            attachedEvidence = true
        }
        // Cleanup deliberately runs after both thrown errors and XCTest assertion
        // failures. A lease is released only after the recorder has stopped.
        await withCheckedContinuation { continuation in recorder.queue.async {
            recorder.stop(); continuation.resume()
        } }
        if let snapshot { await recorder.release(snapshot) }
        do {
            let state = try await recorder.diagnostics()
            timing.append("cleanup running=\(state.running), files=\(state.files), pending=\(state.pending)")
            XCTAssertFalse(state.running)
            XCTAssertTrue(state.files.isEmpty)
        } catch {
            if failure == nil { failure = error }
            timing.append("cleanup diagnostics error: \(error)")
        }
        if attachedEvidence {
            attachFailureEvidence(in: directory, timing: timing, includeMedia: false)
        } else if failure != nil || (testRun?.failureCount ?? 0) > failuresBefore {
            attachFailureEvidence(in: directory, timing: timing)
        }
        if let failure { throw failure }
    }

    private func attachFailureEvidence(in directory: URL, timing: [String], includeMedia: Bool = true) {
        let log = XCTAttachment(string: timing.joined(separator: "\n"))
        log.name = includeMedia ? "Audio boundary failure timing" : "Audio boundary cleanup timing"
        log.lifetime = .keepAlways; add(log)
        guard includeMedia else { return }
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let url = files?.nextObject() as? URL {
            guard ["mov", "mp4", "partial"].contains(url.pathExtension) else { continue }
            let media = XCTAttachment(contentsOfFile: url)
            media.name = "Audio boundary " + url.lastPathComponent
            media.lifetime = .keepAlways; add(media)
        }
    }

    /// Overlapping 2 ms bins prevent a short padded gap from being averaged with
    /// a whole 20 ms window of valid tone. The threshold allows substantial AAC
    /// attenuation; its simulator/device behavior still needs native execution.
    private struct BoundaryProbe {
        static let binsPerBoundary = 59
        struct Bin {
            var energy: Double = 0
            var count = 0
            var rms: Double { sqrt(energy / Double(max(1, count))) }
        }
        let boundaries: [Double]
        private(set) var bins: [Bin]
        init(boundaries: [Double]) {
            self.boundaries = boundaries
            bins = [Bin](repeating: Bin(), count: boundaries.count * Self.binsPerBoundary)
        }
        mutating func add(_ values: [Int16], startingAt start: Double) {
            for (sample, value) in values.enumerated() {
                let time = start + Double(sample) / 44_100
                for (boundary, center) in boundaries.enumerated() {
                    let offset = time - (center - 0.030)
                    guard offset >= 0, offset < 0.060 else { continue }
                    let latest = min(Self.binsPerBoundary - 1, Int(floor(offset / 0.001)))
                    for bin in max(0, latest - 2)...latest {
                        let relative = offset - Double(bin) * 0.001
                        guard relative >= 0, relative < 0.002 else { continue }
                        let index = boundary * Self.binsPerBoundary + bin
                        bins[index].energy += Double(value) * Double(value)
                        bins[index].count += 1
                    }
                }
            }
        }
        func threshold(for boundary: Int) -> Double {
            let base = boundary * Self.binsPerBoundary
            var reference: [Double] = []
            for bin in 0..<Self.binsPerBoundary where bin < 10 || bin >= 49 {
                reference.append(bins[base + bin].rms)
            }
            reference.sort()
            // Compare with nearby decoded tone as well as a conservative absolute
            // floor; timestamp-contiguous inserted silence must not pass.
            return max(2_500, reference[reference.count / 2] * 0.4)
        }
        func lowEnergyBins(for boundary: Int) -> [Int] {
            let threshold = threshold(for: boundary)
            let base = boundary * Self.binsPerBoundary
            return (0..<Self.binsPerBoundary).filter { bins[base + $0].rms < threshold }
        }
    }

    func testBoundaryProbeDetectsTimestampContinuousFifteenMillisecondSilence() {
        let start = 1.96
        let sampleRate: Double = 44_100.0
        let angularFrequency: Double = 600.0 * 2.0 * Double.pi
        var tone: [Int16] = []
        tone.reserveCapacity(3_528)
        for sample in 0..<3_528 {
            let elapsed: Double = Double(sample) / sampleRate
            let amplitude: Double = sin(elapsed * angularFrequency) * 12_000.0
            tone.append(Int16(amplitude))
        }
        var continuous = BoundaryProbe(boundaries: [2])
        continuous.add(tone, startingAt: start)
        XCTAssertTrue(continuous.lowEnergyBins(for: 0).isEmpty)
        var padded = tone
        for index in padded.indices {
            let time: Double = start + Double(index) / sampleRate
            if abs(time - 2.0) < 0.0075 { padded[index] = 0 }
        }
        var gap = BoundaryProbe(boundaries: [2])
        gap.add(padded, startingAt: start)
        XCTAssertFalse(gap.lowEnergyBins(for: 0).isEmpty)
    }

    private func assertDecodedBoundaryAudio(_ url: URL, duration: Double, timing: inout [String]) throws {
        let asset = AVURLAsset(url: url)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var probe = BoundaryProbe(boundaries: [2, 4, 6])
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
            probe.add(values, startingAt: start)
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(try XCTUnwrap(previousEnd), duration, accuracy: 0.03)
        for boundary in probe.boundaries.indices {
            let threshold = probe.threshold(for: boundary)
            let base = boundary * BoundaryProbe.binsPerBoundary
            var descriptions: [String] = []
            for index in 0..<BoundaryProbe.binsPerBoundary {
                let bin = probe.bins[base + index]
                descriptions.append("\(index):count=\(bin.count),rms=\(bin.rms)")
            }
            let binSummary = descriptions.joined(separator: ";")
            timing.append("rollover \(probe.boundaries[boundary]) threshold=\(threshold), bins=\(binSummary)")
            for bin in 0..<BoundaryProbe.binsPerBoundary {
                let result = probe.bins[base + bin]
                XCTAssertGreaterThanOrEqual(result.count, 85, "Missing PCM near rollover \(boundary + 1), bin \(bin)")
                XCTAssertGreaterThanOrEqual(result.rms, threshold, "Audio gap near rollover \(boundary + 1), bin \(bin)")
            }
        }
    }
}
