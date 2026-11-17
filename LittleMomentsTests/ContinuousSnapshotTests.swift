import AVFoundation
import XCTest
@testable import LittleMoments

/// Actual production recorder/writers/composer; only callback delivery is delayed.
/// Manual codec pacing is used for exact-content tests; the comparison separately
/// calls the nonwaiting hardware ingest path to expose Save-attributable loss.
final class ContinuousSnapshotTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Continuous-" + UUID().uuidString)
        try ProtectedFiles.directory(root)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private final class Clock { var value = 50.0 }
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var held = true
        private var callbacks: [() -> Void] = []
        var count: Int { lock.lock(); defer { lock.unlock() }; return callbacks.count }
        func deliver(_ body: @escaping () -> Void) {
            lock.lock()
            if held { callbacks.append(body); lock.unlock() } else { lock.unlock(); body() }
        }
        func open() {
            lock.lock(); held = false; let work = callbacks; callbacks = []; lock.unlock()
            work.forEach { $0() }
        }
    }
    private struct Harness {
        let recorder: RollingRecorder
        let clock: Clock
        var experiment: ContinuousSnapshotExperiment { ContinuousSnapshotExperiment(recorder: recorder) }
        func perform(_ body: @escaping () -> Void) async {
            await withCheckedContinuation { c in recorder.queue.async { body(); c.resume() } }
        }
        func feed(_ source: TimestampedSampleSource, _ range: Range<Int>, audio: Bool = true) async throws {
            for frame in range {
                try await recorder.appendManually(source.video(frame: frame), isAudio: false)
                if audio { try await recorder.appendManually(source.audio(frame: frame), isAudio: true) }
            }
        }
        func stop() async { await perform { recorder.stop() } }
    }
    private func harness(window: Double = 15, gate: Gate? = nil,
                         capacity: @escaping () throws -> Int64 = { Int64.max }) async -> Harness {
        let clock = Clock()
        let recorder = RollingRecorder(queue: DispatchQueue(label: "Continuous." + UUID().uuidString),
            directory: root.appendingPathComponent(UUID().uuidString), now: { clock.value }, capacity: capacity,
            deliverCompletion: { body in if let gate { gate.deliver(body) } else { body() } })
        let h = Harness(recorder: recorder, clock: clock)
        await h.perform { recorder.start(audio: true, duration: window) }
        return h
    }
    private func wait(_ predicate: () async throws -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(15))
        while !(try await predicate()) {
            guard ContinuousClock.now < end else { throw CameraError.writer("Experiment callback timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testHardwareIntakeComparisonSeparatesSaveLossFromEncoderBackpressure() async throws {
        for mode in ContinuousSnapshotExperiment.Mode.allCases {
            let gate = Gate(), h = await harness(gate: gate)
            let source = TimestampedSampleSource()
            try await h.feed(source, 0..<7)
            let before = try await h.recorder.diagnostics()
            let pending = Task { try await h.experiment.snapshot(mode) }
            try await wait { gate.count == 1 }
            // Identical nonretrying arrival sequence during genuine finalization.
            for frame in 7..<12 {
                let video = try source.video(frame: frame), audio = try source.audio(frame: frame)
                await h.perform {
                    h.recorder.ingest(video, isAudio: false)
                    h.recorder.ingest(audio, isAudio: true)
                }
            }
            let during = try await h.recorder.diagnostics()
            XCTAssertTrue(during.running)
            XCTAssertEqual(during.receivedVideo - before.receivedVideo, 5)
            XCTAssertEqual(during.receivedAudio - before.receivedAudio, 5)
            let drops: Int64 = mode == .freezingBaseline ? 5 : 0
            XCTAssertEqual(during.saveDroppedVideo - before.saveDroppedVideo, drops)
            XCTAssertEqual(during.saveDroppedAudio - before.saveDroppedAudio, drops)
            XCTAssertEqual(during.acceptedVideo - before.acceptedVideo +
                during.backpressuredVideo - before.backpressuredVideo + drops, 5)
            XCTAssertEqual(during.acceptedAudio - before.acceptedAudio +
                during.backpressuredAudio - before.backpressuredAudio + drops, 5)
            let report = XCTAttachment(string: "mode=\(mode) received=5 saveDrops=\(drops) videoBackpressure=\(during.backpressuredVideo - before.backpressuredVideo) audioBackpressure=\(during.backpressuredAudio - before.backpressuredAudio)")
            report.lifetime = .keepAlways; add(report)
            gate.open()
            let snapshot = try await pending.value
            XCTAssertEqual(snapshot.end, source.origin + 0.7, accuracy: 0.0001)
            let output = root.appendingPathComponent(UUID().uuidString + ".mp4")
            try await ClipComposer().compose(snapshot, to: output)
            try assertMedia(output, markers: Array(0..<7), sourceStart: 0, duration: 0.7, frameDuration: 0.1)
            await h.recorder.release(snapshot); await h.stop()
            let final = try await h.recorder.diagnostics(); XCTAssertTrue(final.files.isEmpty)
        }
    }

    func testAllRetentionWindowsAndConsecutiveMidSegmentSavesDecodeExactCutoffs() async throws {
        for window in [15.0, 30, 60, 120] {
            let h = await harness(window: window)
            let source = TimestampedSampleSource(origin: 9_000, frameDuration: CMTime(value: 1, timescale: 2))
            var previous = 0
            // Truncated warmup; then each window and expiry; all trigger mid-segment.
            for endpoint in [3, Int(window * 2) + 7, Int(window * 2) + 11] {
                try await h.feed(source, previous..<endpoint)
                let snapshot = try await h.experiment.snapshot(.continuousMOV)
                XCTAssertEqual(snapshot.end, source.origin + Double(endpoint) / 2, accuracy: 0.0001)
                let first = max(0, endpoint - Int(window * 2))
                let staging = root.appendingPathComponent("stage-" + UUID().uuidString)
                try ProtectedFiles.directory(staging)
                let output = staging.appendingPathComponent("clip.partial")
                // Feed during export; no unintended post-trigger frames may leak.
                async let exported: Void = ClipComposer().compose(snapshot, to: output)
                try await h.feed(source, endpoint..<(endpoint + 1))
                let inFlight = try await h.experiment.workingSet(stagingDirectory: staging)
                XCTAssertLessThan(inFlight.totalBytes, 192 * 1_024 * 1_024)
                try await exported
                let census = try await h.experiment.workingSet(stagingDirectory: staging)
                XCTAssertEqual(census.stagingBytes, ProtectedFiles.bytes(output))
                XCTAssertGreaterThan(census.stagingBytes, 0)
                XCTAssertLessThan(census.captureBytes, 192 * 1_024 * 1_024)
                // Measured fixture bound includes export staging, not only index bytes.
                XCTAssertLessThan(census.totalBytes, 192 * 1_024 * 1_024)
                try assertMedia(output, markers: Array(first..<endpoint), sourceStart: Double(first) / 2,
                                duration: Double(endpoint - first) / 2, frameDuration: 0.5)
                await h.recorder.release(snapshot)
                try FileManager.default.removeItem(at: staging)
                previous = endpoint + 1
            }
            await h.stop()
            let final = try await h.recorder.diagnostics()
            XCTAssertTrue(final.files.isEmpty); XCTAssertEqual(final.leaseCount, 0)
        }
    }

    func testDelayedFinalizationDeadlineAndStopDoNotLeakOrRestart() async throws {
        for stop in [false, true] {
            let gate = Gate(), h = await harness(gate: gate)
            try await h.feed(TimestampedSampleSource(), 0..<7)
            let pending = Task { try await h.experiment.snapshot(.continuousMOV) }
            try await wait { gate.count == 1 }
            if stop {
                await h.stop()
                gate.open()
                // Interruption ends intake immediately, while accepted media may
                // finish safely and return its already fixed retrospective range.
                let snapshot = try await pending.value
                XCTAssertEqual(snapshot.end, 1_000.7, accuracy: 0.0001)
                await h.recorder.release(snapshot)
            } else {
                await h.perform { h.clock.value += 6; h.recorder.pollHealth() }
                do { _ = try await pending.value; XCTFail("Finalization deadline must settle") } catch { }
                gate.open()
            }
            await h.stop()
            try await wait { try await h.recorder.diagnostics().files.isEmpty }
            let state = try await h.recorder.diagnostics()
            XCTAssertFalse(state.running); XCTAssertEqual(state.leaseCount, 0)
            do { _ = try await h.experiment.snapshot(.continuousMOV); XCTFail("Explicit restart required") } catch { }
        }
    }

    func testLowDiskDuringPendingSaveCleansFinalizersAndLeases() async throws {
        let clock = Clock(), gate = Gate()
        // Reuse clock's value as a test-only capacity switch.
        let h = await harness(gate: gate, capacity: { clock.value > 50 ? 1 : Int64.max })
        try await h.feed(TimestampedSampleSource(), 0..<7)
        let pending = Task { try await h.experiment.snapshot(.continuousMOV) }
        try await wait { gate.count == 1 }
        let sample = try TimestampedSampleSource().video(frame: 7)
        await h.perform { clock.value = 51; h.clock.value += 1; h.recorder.ingest(sample, isAudio: false) }
        gate.open()
        // A storage stop can safely finish already accepted media. It must not
        // restart intake or retain the lease after the caller releases it.
        do {
            let snapshot = try await pending.value
            await h.recorder.release(snapshot)
        } catch { }
        try await wait { try await h.recorder.diagnostics().files.isEmpty }
        let state = try await h.recorder.diagnostics()
        XCTAssertFalse(state.running); XCTAssertEqual(state.leaseCount, 0)
    }


    func testStopAfterCutoffCleansFutureAudioBoundaryOnDeliveryOrCancellation() async throws {
        for cancel in [false, true] {
            let gate = Gate(), h = await harness(gate: gate)
            let source = TimestampedSampleSource()
            try await h.feed(source, 0..<7)
            let pending = Task { try await h.experiment.snapshot(.continuousMOV) }
            try await wait { gate.count == 1 }
            // While the fixed 0.7s snapshot awaits completion, the future writer
            // rotates with no microphone watermark. The boundary holds that
            // writer separately from the finalizer and active writer.
            try await h.feed(source, 7..<29, audio: false)
            await h.stop()
            if cancel {
                pending.cancel()
                do { _ = try await pending.value; XCTFail("Canceled stopped request must fail") } catch { }
                gate.open()
            } else {
                gate.open()
                let snapshot = try await pending.value
                XCTAssertEqual(snapshot.end, source.origin + 0.7, accuracy: 0.0001)
                await h.recorder.release(snapshot)
            }
            try await wait { try await h.recorder.diagnostics().files.isEmpty }
            let state = try await h.recorder.diagnostics()
            XCTAssertFalse(state.running)
            XCTAssertEqual(state.pending, 0); XCTAssertEqual(state.finalizingWriters, 0)
            XCTAssertEqual(state.leaseCount, 0)
        }
    }

    func testExportFailureRemovesStagingAndReleasesCaptureLease() async throws {
        let h = await harness()
        try await h.feed(TimestampedSampleSource(), 0..<7)
        let snapshot = try await h.experiment.snapshot(.continuousMOV)
        let staging = root.appendingPathComponent("failed-export")
        try ProtectedFiles.directory(staging)
        let output = staging.appendingPathComponent("failed.partial")
        // Actual composer failure after acquisition of a real production lease.
        ProtectedFiles.remove(snapshot.segments.map(\.url))
        do {
            try await ClipComposer().compose(snapshot, to: output)
            XCTFail("Missing source must fail export")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        await h.recorder.release(snapshot); await h.stop()
        let census = try await h.experiment.workingSet(stagingDirectory: staging)
        XCTAssertEqual(census.totalBytes, 0); XCTAssertEqual(census.fileCount, 0)
        let state = try await h.recorder.diagnostics(); XCTAssertEqual(state.leaseCount, 0)
    }

    func testExportDestinationDiskFailureCleansLeaseAndOutput() async throws {
        let h = await harness()
        try await h.feed(TimestampedSampleSource(), 0..<7)
        let snapshot = try await h.experiment.snapshot(.continuousMOV)
        let output = root.appendingPathComponent("missing-directory/clip.partial")
        // A real export backend write failure, with valid leased source movies.
        do {
            try await ClipComposer().compose(snapshot, to: output)
            XCTFail("A missing destination directory must fail")
        } catch { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        await h.recorder.release(snapshot); await h.stop()
        let state = try await h.recorder.diagnostics()
        XCTAssertEqual(state.leaseCount, 0); XCTAssertTrue(state.files.isEmpty)
    }

    private func assertMedia(_ url: URL, markers: [Int], sourceStart: Double,
                             duration: Double, frameDuration: Double) throws {
        let asset = AVURLAsset(url: url)
        let video = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var decoded: [Int] = [], times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            let image = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
            CVPixelBufferLockBaseAddress(image, .readOnly)
            let pixels = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(image) * (CVPixelBufferGetHeight(image) / 2)
            var marker = 0
            for bit in 0..<16 where pixels[row + (bit * 8 + 4) * 4 + 1] > 128 { marker |= 1 << bit }
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
            decoded.append(marker); times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        }
        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(decoded, markers)
        for (index, time) in times.enumerated() {
            XCTAssertEqual(time, Double(index) * frameDuration, accuracy: 0.003)
        }
        let audio = try XCTUnwrap(asset.tracks(withMediaType: .audio).first)
        let audioReader = try AVAssetReader(asset: asset)
        let pcm = AVAssetReaderTrackOutput(track: audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false])
        audioReader.add(pcm); XCTAssertTrue(audioReader.startReading())
        var expectedTime = 0.0, packets = 0, verifiedTones = 0
        while let sample = pcm.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            var values = [Int16](repeating: 0, count: CMBlockBufferGetDataLength(block) / 2)
            let status = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            XCTAssertEqual(status, kCMBlockBufferNoErr)
            let length = Double(values.count) / 44_100
            XCTAssertEqual(time, expectedTime, accuracy: 0.03)
            expectedTime = time + length; packets += 1
            let phase = (sourceStart + time).truncatingRemainder(dividingBy: 1)
            if phase > 0.1 && phase < 0.85 && length > 0.01 {
                let rms = sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(values.count, 1)))
                let crossings = zip(values, values.dropFirst()).filter { $0.0 <= 0 && $0.1 > 0 }.count
                XCTAssertGreaterThan(rms, 3_000)
                XCTAssertEqual(Double(crossings) / length, TimestampedSampleSource.frequency(at: sourceStart + time), accuracy: 65)
                verifiedTones += 1
            }
        }
        XCTAssertEqual(audioReader.status, .completed)
        XCTAssertGreaterThan(packets, 0); XCTAssertGreaterThan(verifiedTones, 0)
        XCTAssertEqual(expectedTime, duration, accuracy: 0.06)
    }
}
