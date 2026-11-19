import AVFoundation
import XCTest
@testable import LittleMoments

/// Real codecs, production segment writer/index/leases/composer/library. The
/// smaller image/cadence accelerates logical time; this is not a device benchmark.
final class RollingRecorderTests: XCTestCase {
    private var directory: URL!
    private var timing: [String] = []
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Recorder-" + UUID().uuidString)
        try ProtectedFiles.directory(directory)
    }
    override func tearDownWithError() throws {
        if let run = testRun, run.failureCount > 0 {
            let log = XCTAttachment(string: timing.joined(separator: "\n")); log.lifetime = .keepAlways; add(log)
            let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                if ["mov", "mp4", "partial"].contains(url.pathExtension) {
                    let attachment = XCTAttachment(contentsOfFile: url); attachment.lifetime = .keepAlways; add(attachment)
                }
            }
        }
        try FileManager.default.removeItem(at: directory)
    }

    private final class Clock { var value: Double = 50 }
    private struct Harness {
        let recorder: RollingRecorder
        let clock: Clock
        func perform(_ body: @escaping () -> Void) async {
            await withCheckedContinuation { continuation in recorder.queue.async { body(); continuation.resume() } }
        }
        func start(audio: Bool, window: Double) async {
            await perform { recorder.start(audio: audio, duration: window) }
        }
        func stop() async { await perform { recorder.stop() } }
        func feed(_ source: TimestampedSampleSource, frames: Range<Int>, audio: Bool) async throws {
            for frame in frames {
                // Host time advances independently, not by copying a media PTS.
                await perform { clock.value += 0.001 }
                try await recorder.appendManually(source.video(frame: frame), isAudio: false)
                if audio { try await recorder.appendManually(source.audio(frame: frame), isAudio: true) }
            }
        }
    }
    private func harness(capacity: (() throws -> Int64)? = nil,
                         makeWriter: @escaping (CMSampleBuffer, Bool, URL) throws -> SegmentWriting = {
                             try SegmentWriter(sample: $0, audioEnabled: $1, directory: $2)
                         }, deliver: @escaping (@escaping () -> Void) -> Void = { $0() }) -> Harness {
        let clock = Clock()
        let recorder = RollingRecorder(queue: DispatchQueue(label: "RecorderTest." + UUID().uuidString),
            directory: directory.appendingPathComponent("buffer"), now: { clock.value }, capacity: capacity,
            makeWriter: makeWriter, deliverCompletion: deliver)
        return Harness(recorder: recorder, clock: clock)
    }

    func testFiveMinuteRetention15SecondsSilent() async throws { try await retention(window: 15, audio: false) }
    func testFiveMinuteRetention30SecondsSilent() async throws { try await retention(window: 30, audio: false) }
    func testFiveMinuteRetention60SecondsSilent() async throws { try await retention(window: 60, audio: false) }
    func testFiveMinuteRetention120SecondsSilent() async throws { try await retention(window: 120, audio: false) }
    func testFiveMinuteRetention15SecondsAudio() async throws { try await retention(window: 15, audio: true) }
    func testFiveMinuteRetention30SecondsAudio() async throws { try await retention(window: 30, audio: true) }
    func testFiveMinuteRetention60SecondsAudio() async throws { try await retention(window: 60, audio: true) }
    func testFiveMinuteRetention120SecondsAudio() async throws { try await retention(window: 120, audio: true) }

    private func retention(window: Double, audio: Bool) async throws {
        let h = harness()
        // 600 real encoded frames / 300 seconds in each of eight configurations.
        let source = TimestampedSampleSource(frameDuration: CMTime(value: 1, timescale: 2))
        await h.start(audio: audio, window: window)
        try await h.feed(source, frames: 0..<600, audio: audio)
        let snapshot = try await h.recorder.snapshot()
        timing.append("window=\(window) audio=\(audio) end=\(snapshot.end) segments=\(snapshot.segments)")
        XCTAssertEqual(snapshot.end, source.origin + 300, accuracy: 0.001)
        XCTAssertTrue(snapshot.segments.allSatisfy { $0.end > snapshot.end - window && $0.start < snapshot.end })
        XCTAssertLessThanOrEqual(snapshot.segments.first!.start, snapshot.end - window)
        let state = try await h.recorder.diagnostics()
        XCTAssertLessThanOrEqual(state.segments.reduce(Int64(0)) { $0 + $1.bytes }, 160 * 1_024 * 1_024)
        XCTAssertLessThan(state.diskBytes, 192 * 1_024 * 1_024)
        XCTAssertEqual(Set(state.files), Set(state.segments.map(\.url)))
        XCTAssertEqual(state.diskBytes, state.segments.reduce(0) { $0 + $1.bytes })
        XCTAssertTrue(state.segments.allSatisfy { ProtectedFiles.bytes($0.url) == $0.bytes && $0.bytes > 0 })
        // Expired unleased media must have actually disappeared, not just left
        // the in-memory index. Stop must retain this leased export's files.
        XCTAssertTrue(state.segments.allSatisfy { $0.end > snapshot.end - window - 2 })
        await h.stop()
        XCTAssertTrue(snapshot.segments.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
        let output = directory.appendingPathComponent("retention.mp4")
        try await ClipComposer().compose(snapshot, to: output)
        let frames = try decodeVideo(output)
        let first = Int((300 - window) * 2)
        XCTAssertEqual(frames.map(\.marker), Array(first..<600))
        XCTAssertEqual(frames.count, Int(window * 2))
        XCTAssertEqual(try XCTUnwrap(frames.first).time, 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(frames.last).time, window - 0.5, accuracy: 0.002)
        if audio { try assertAudio(output, sourceStart: 300 - window, duration: window) }
        else { XCTAssertTrue(AVURLAsset(url: output).tracks(withMediaType: .audio).isEmpty) }
        await h.recorder.release(snapshot)
        let cleared = try await h.recorder.diagnostics()
        XCTAssertTrue(cleared.files.isEmpty); XCTAssertTrue(cleared.segments.isEmpty)
    }

    func testRolloverAndRepeatedSnapshotsPreserveFrameMarkers() async throws {
        let h = harness()
        let source = TimestampedSampleSource(frameDuration: CMTime(value: 1, timescale: 30))
        await h.start(audio: true, window: 15)
        var previous = 0
        // Warmup, just before/after a two-second rollover, and a nonboundary save.
        for endpoint in [17, 59, 61, 97, 183] {
            try await h.feed(source, frames: previous..<endpoint, audio: true)
            let snapshot = try await h.recorder.snapshot()
            let url = directory.appendingPathComponent("save-\(endpoint).mp4")
            // Export and feed concurrently: lease protects the asynchronous read.
            async let exported: Void = ClipComposer().compose(snapshot, to: url)
            try await h.feed(source, frames: endpoint..<(endpoint + 2), audio: true)
            try await exported
            XCTAssertTrue(snapshot.segments.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
            let frames = try decodeVideo(url)
            XCTAssertEqual(frames.map(\.marker), Array(0..<endpoint))
            XCTAssertEqual(try XCTUnwrap(frames.first).marker, 0)
            XCTAssertEqual(try XCTUnwrap(frames.last).marker, endpoint - 1)
            XCTAssertEqual(try XCTUnwrap(frames.last).time, Double(endpoint - 1) / 30, accuracy: 0.002)
            try assertAudio(url, sourceStart: 0, duration: Double(endpoint) / 30)
            await h.recorder.release(snapshot)
            previous = endpoint + 2
        }
        await h.stop()
        let state = try await h.recorder.diagnostics(); XCTAssertTrue(state.files.isEmpty)
    }

    func testOffsetAudioAndIntentionalGapKeepIdentifiableContent() async throws {
        let h = harness()
        let source = TimestampedSampleSource(audioOffset: 0.025, gaps: [23: 0.3])
        await h.start(audio: true, window: 15)
        try await h.feed(source, frames: 0..<47, audio: true)
        let snapshot = try await h.recorder.snapshot()
        let url = directory.appendingPathComponent("offset-gap.mp4")
        try await ClipComposer().compose(snapshot, to: url)
        let video = try decodeVideo(url)
        XCTAssertEqual(video.map(\.marker), Array(0..<47))
        let audio = try decodeAudio(url)
        XCTAssertFalse(audio.isEmpty)
        XCTAssertEqual(try XCTUnwrap(audio.first).time - XCTUnwrap(video.first).time, 0.025, accuracy: 0.03)
        XCTAssertTrue(audio.contains { $0.rms > 3_000 })
        // Every decoded packet remains ordered; the intentional capture gap may
        // be represented as silence or collapsed by composition, never overlap.
        for pair in zip(audio, audio.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1.time + 0.001, pair.0.time + pair.0.duration)
        }
        await h.recorder.release(snapshot); await h.stop()
    }

    private final class CompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var work: [() -> Void] = []
        private var held = true
        func deliver(_ body: @escaping () -> Void) {
            lock.lock()
            if held { work.append(body); lock.unlock() } else { lock.unlock(); body() }
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return work.count }
        func open() {
            lock.lock(); held = false; let callbacks = work; work = []; lock.unlock()
            callbacks.forEach { $0() }
        }
    }
    private func waitUntil(_ predicate: @escaping () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !(try await predicate()) {
            guard ContinuousClock.now < deadline else { XCTFail("Timed out waiting for recorder callback"); throw CameraError.busy }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private final class HeldWriter: SegmentWriting {
        let start: CMTime
        var end: CMTime
        let url: URL
        var cancellations = 0
        var completion: ((Result<VideoSegment, Error>) -> Void)?
        init(sample: CMSampleBuffer, directory: URL) throws {
            start = CMSampleBufferGetPresentationTimeStamp(sample); end = start
            url = directory.appendingPathComponent(UUID().uuidString + ".mov")
            try Data([0]).write(to: url)
        }
        func append(_ sample: CMSampleBuffer, isAudio: Bool) throws -> Bool {
            if !isAudio { end = CMSampleBufferGetPresentationTimeStamp(sample) + CMSampleBufferGetDuration(sample) }
            return true
        }
        func finish(completion: @escaping (Result<VideoSegment, Error>) -> Void) { self.completion = completion }
        func cancel() { cancellations += 1; ProtectedFiles.remove([url]) }
    }

    func testSnapshotPrunesExpiredFilesAfterOutOfOrderFinalization() async throws {
        var writers: [HeldWriter] = []
        let h = harness(makeWriter: { sample, _, directory in
            let writer = try HeldWriter(sample: sample, directory: directory)
            writers.append(writer); return writer
        })
        await h.start(audio: false, window: 30)
        let source = TimestampedSampleSource()
        // Two old finalizers remain pending across a logical media gap. The
        // hardware limit permits these two plus the current writer.
        for frame in [0, 20, 400] {
            try await h.feed(source, frames: frame..<(frame + 1), audio: false)
        }
        let saving = Task { try await h.recorder.snapshot() }
        try await waitUntil { try await h.recorder.diagnostics().freezing }
        await h.perform {
            XCTAssertEqual(writers.count, 3)
            // Complete newest first and oldest last, entirely while freezing.
            // Every success corresponds to an actual file in the buffer.
            for writer in writers.reversed() {
                writer.completion?(.success(VideoSegment(id: UUID(), url: writer.url,
                    start: writer.start.seconds, end: writer.end.seconds,
                    bytes: ProtectedFiles.bytes(writer.url))))
            }
        }
        let snapshot = try await saving.value
        let state = try await h.recorder.diagnostics()
        XCTAssertEqual(snapshot.segments.count, 1)
        XCTAssertEqual(snapshot.end, source.origin + 40.1, accuracy: 0.001)
        XCTAssertEqual(Set(state.files), Set(snapshot.segments.map(\.url)))
        XCTAssertEqual(state.segments, snapshot.segments)
        XCTAssertEqual(state.diskBytes, snapshot.segments.reduce(0) { $0 + $1.bytes })
        XCTAssertEqual(state.pending, 0)
        await h.perform {
            XCTAssertTrue(writers.prefix(2).allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) })
            XCTAssertTrue(writers.allSatisfy { $0.cancellations == 0 })
        }
        await h.stop()
        XCTAssertTrue(snapshot.segments.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
        await h.recorder.release(snapshot)
        let cleared = try await h.recorder.diagnostics()
        XCTAssertTrue(cleared.files.isEmpty); XCTAssertTrue(cleared.segments.isEmpty)
        XCTAssertEqual(cleared.pending, 0)
    }

    func testDelayedCompletionCannotCrossGeneration() async throws {
        let gate = CompletionGate()
        let h = harness(deliver: { gate.deliver($0) })
        let source = TimestampedSampleSource()
        await h.start(audio: false, window: 15)
        try await h.feed(source, frames: 0..<23, audio: false)
        try await waitUntil { gate.count == 1 }
        await h.stop()
        await h.start(audio: false, window: 15)
        let next = TimestampedSampleSource(origin: 2_000)
        try await h.feed(next, frames: 0..<7, audio: false)
        gate.open()
        let snapshot = try await h.recorder.snapshot()
        XCTAssertTrue(snapshot.segments.allSatisfy { $0.start >= 2_000 })
        let state = try await h.recorder.diagnostics()
        XCTAssertEqual(Set(state.files), Set(snapshot.segments.map(\.url)))
        await h.stop(); await h.recorder.release(snapshot)
        let cleared = try await h.recorder.diagnostics(); XCTAssertTrue(cleared.files.isEmpty)
    }

    func testStopDuringPendingSnapshotSettlesOnceAndRequiresExplicitRestart() async throws {
        let gate = CompletionGate()
        let h = harness(deliver: { gate.deliver($0) })
        await h.start(audio: true, window: 15)
        try await h.feed(TimestampedSampleSource(), frames: 0..<7, audio: true)
        let saving = Task { try await h.recorder.snapshot() }
        try await waitUntil { gate.count == 1 }
        // This is the same stop boundary used by interruption/background routing.
        await h.stop()
        do { _ = try await saving.value; XCTFail("Stopped snapshot must fail") } catch { }
        gate.open()
        try await waitUntil { try await h.recorder.diagnostics().files.isEmpty }
        await h.perform { h.recorder.pollHealth() }
        let state = try await h.recorder.diagnostics(); XCTAssertFalse(state.running)
        do { _ = try await h.recorder.snapshot(); XCTFail("No automatic restart") } catch { }
    }

    func testBoundedPendingWritersStopOnOverload() async throws {
        let gate = CompletionGate()
        let h = harness(deliver: { gate.deliver($0) })
        await h.start(audio: false, window: 15)
        let source = TimestampedSampleSource()
        for frame in [0, 20, 40, 60] {
            let sample = try source.video(frame: frame)
            // This deliberately uses the nonwaiting hardware path, bypassing
            // manual pacing, to hold three genuine finalizations outstanding.
            await h.perform { h.recorder.ingest(sample, isAudio: false) }
        }
        let state = try await h.recorder.diagnostics(); XCTAssertFalse(state.running)
        try await waitUntil { gate.count == 3 }
        gate.open()
        try await waitUntil { try await h.recorder.diagnostics().files.isEmpty }
    }

    func testWatchdogUsesHostClockAndNeverRestarts() async throws {
        let h = harness()
        await h.start(audio: false, window: 15)
        try await h.feed(TimestampedSampleSource(origin: 90_000), frames: 0..<2, audio: false)
        await h.perform { h.clock.value += 4.99; h.recorder.pollHealth() }
        let live = try await h.recorder.diagnostics(); XCTAssertTrue(live.running)
        await h.perform { h.clock.value += 0.02; h.recorder.pollHealth() }
        let stopped = try await h.recorder.diagnostics(); XCTAssertFalse(stopped.running); XCTAssertTrue(stopped.files.isEmpty)
        await h.perform { h.clock.value += 100; h.recorder.pollHealth() }
        let later = try await h.recorder.diagnostics(); XCTAssertFalse(later.running)
    }

    func testLowDiskAndWriterFailureStopWithoutLeakingFiles() async throws {
        let lowDisk = harness(capacity: { 1 })
        await lowDisk.start(audio: false, window: 15)
        do { try await lowDisk.feed(TimestampedSampleSource(), frames: 0..<1, audio: false); XCTFail("Expected low disk stop") } catch { }
        let diskState = try await lowDisk.recorder.diagnostics(); XCTAssertFalse(diskState.running); XCTAssertTrue(diskState.files.isEmpty)
        let broken = harness(makeWriter: { _, _, _ in throw CameraError.writer("Injected writer failure") })
        await broken.start(audio: false, window: 15)
        do { try await broken.feed(TimestampedSampleSource(), frames: 0..<1, audio: false); XCTFail("Expected writer failure") } catch { }
        let brokenState = try await broken.recorder.diagnostics(); XCTAssertFalse(brokenState.running); XCTAssertTrue(brokenState.files.isEmpty)
    }

    @MainActor func testLibraryFailureRemovesStagingAndLeaseCanBeReleased() async throws {
        let h = harness()
        await h.start(audio: true, window: 15)
        try await h.feed(TimestampedSampleSource(), frames: 0..<13, audio: true)
        let snapshot = try await h.recorder.snapshot()
        // Real source failure during export, after a production lease exists.
        ProtectedFiles.remove(snapshot.segments.map(\.url))
        let library = ClipLibrary(directory: directory.appendingPathComponent("library"))
        do { try await library.save(snapshot); XCTFail("Missing source must fail export") } catch { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: library.directory, includingPropertiesForKeys: nil).isEmpty)
        await h.stop(); await h.recorder.release(snapshot)
        let state = try await h.recorder.diagnostics(); XCTAssertTrue(state.segments.isEmpty); XCTAssertTrue(state.files.isEmpty)
    }

    @MainActor func testLeaseSurvivesEvictionDuringLibrarySave() async throws {
        let h = harness()
        let source = TimestampedSampleSource()
        await h.start(audio: true, window: 15)
        try await h.feed(source, frames: 0..<43, audio: true)
        let snapshot = try await h.recorder.snapshot()
        let library = ClipLibrary(directory: directory.appendingPathComponent("library"))
        async let save: Void = library.save(snapshot)
        try await h.feed(source, frames: 43..<243, audio: true)
        try await save
        // All source files have expired by time, but this export's lease owns
        // them until release, even if the asynchronous save completed earlier.
        XCTAssertTrue(snapshot.segments.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
        await h.recorder.release(snapshot)
        XCTAssertTrue(snapshot.segments.allSatisfy { !FileManager.default.fileExists(atPath: $0.url.path) })
        XCTAssertEqual(library.clips.count, 1)
        let frames = try decodeVideo(library.clips[0].url)
        XCTAssertEqual(frames.map(\.marker), Array(0..<43))
        await h.stop()
        let state = try await h.recorder.diagnostics(); XCTAssertTrue(state.files.isEmpty)
        let reloaded = ClipLibrary(directory: library.directory); try reloaded.load()
        XCTAssertEqual(reloaded.clips.count, 1)
    }

    private final class BackpressuredWriter: SegmentWriting {
        let real: SegmentWriter
        var start: CMTime { real.start }
        var end: CMTime { real.end }
        var url: URL { real.url }
        init(sample: CMSampleBuffer, audio: Bool, directory: URL) throws {
            real = try SegmentWriter(sample: sample, audioEnabled: audio, directory: directory)
        }
        func append(_ sample: CMSampleBuffer, isAudio: Bool) throws -> Bool { false }
        func finish(completion: @escaping (Result<VideoSegment, Error>) -> Void) { real.finish(completion: completion) }
        func cancel() { real.cancel() }
    }
    func testManualEncoderWaitIsBoundedAndRealTimeIngestionNeverWaits() async throws {
        let h = harness(makeWriter: { try BackpressuredWriter(sample: $0, audio: $1, directory: $2) })
        await h.start(audio: false, window: 15)
        let sample = try TimestampedSampleSource().video(frame: 0)
        let start = ContinuousClock.now
        do {
            try await h.recorder.appendManually(sample, isAudio: false, timeout: .milliseconds(20))
            XCTFail("Backpressure must time out")
        } catch { }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        // Hundreds of real-time delegate-style calls do not poll or sleep.
        await h.perform { for _ in 0..<1_000 { h.recorder.ingest(sample, isAudio: false) } }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        await h.stop()
        let state = try await h.recorder.diagnostics(); XCTAssertTrue(state.files.isEmpty)
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
            CVPixelBufferLockBaseAddress(image, .readOnly)
            let pixels = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
            let row = CVPixelBufferGetBytesPerRow(image) * (CVPixelBufferGetHeight(image) / 2)
            var marker = 0
            for bit in 0..<16 where pixels[row + (bit * 8 + 4) * 4 + 1] > 128 { marker |= 1 << bit }
            CVPixelBufferUnlockBaseAddress(image, .readOnly)
            frames.append(Frame(marker: marker, time: CMSampleBufferGetPresentationTimeStamp(sample).seconds))
        }
        XCTAssertEqual(reader.status, .completed)
        timing.append("video \(url.lastPathComponent): frames=\(frames.count) first=\(String(describing: frames.first)) last=\(String(describing: frames.last))")
        return frames
    }
    private struct AudioPacket {
        let time: Double
        let duration: Double
        let rms: Double
        let frequency: Double
    }
    private func decodeAudio(_ url: URL) throws -> [AudioPacket] {
        let asset = AVURLAsset(url: url)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .audio).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var packets: [AudioPacket] = []
        while let sample = output.copyNextSampleBuffer() {
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            var values = [Int16](repeating: 0, count: CMBlockBufferGetDataLength(block) / 2)
            let status = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            XCTAssertEqual(status, kCMBlockBufferNoErr)
            let rms = sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, values.count)))
            let crossings = zip(values, values.dropFirst()).filter { $0.0 <= 0 && $0.1 > 0 }.count
            let duration = Double(values.count) / 44_100
            packets.append(AudioPacket(time: CMSampleBufferGetPresentationTimeStamp(sample).seconds,
                duration: duration, rms: rms, frequency: Double(crossings) / max(duration, 0.000001)))
        }
        XCTAssertEqual(reader.status, .completed)
        timing.append("audio \(url.lastPathComponent): packets=\(packets.count) first=\(String(describing: packets.first)) last=\(String(describing: packets.last))")
        return packets
    }
    private func assertAudio(_ url: URL, sourceStart: Double, duration: Double) throws {
        let packets = try decodeAudio(url)
        XCTAssertFalse(packets.isEmpty)
        guard let first = packets.first, let last = packets.last else { return }
        XCTAssertEqual(first.time, 0, accuracy: 0.03)
        XCTAssertEqual(last.time + last.duration, duration, accuracy: 0.06)
        for pair in zip(packets, packets.dropFirst()) {
            XCTAssertEqual(pair.1.time, pair.0.time + pair.0.duration, accuracy: 0.03)
        }
        // Avoid AAC priming and frequency transitions. Verify identifiable tone
        // markers throughout the clip, including either side of each rollover.
        let stable = packets.filter {
            let phase = (sourceStart + $0.time).truncatingRemainder(dividingBy: 1)
            return phase > 0.1 && phase < 0.85 && $0.duration > 0.01
        }
        XCTAssertFalse(stable.isEmpty)
        for packet in stable {
            XCTAssertGreaterThan(packet.rms, 3_000)
            XCTAssertEqual(packet.frequency, TimestampedSampleSource.frequency(at: sourceStart + packet.time), accuracy: 65)
        }
    }
}
