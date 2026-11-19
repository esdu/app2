import AVFoundation
import XCTest
@testable import LittleMoments

final class MediaIntegrationTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try ProtectedFiles.directory(directory)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func fixture(audio: Bool = false) async throws -> VideoSegment {
        let url = directory.appendingPathComponent(UUID().uuidString + ".mov")
        try await SyntheticMovie.write(to: url, audio: audio)
        return VideoSegment(id: UUID(), url: url, start: 100, end: 102, bytes: ProtectedFiles.bytes(url))
    }

    func testSyntheticFixtureStalledReadinessTimesOutWithProgressAndRemovesOutput() async throws {
        let url = directory.appendingPathComponent("stalled.mov")
        do {
            try await SyntheticMovie.write(to: url, timeout: 0.05, readiness: { _ in false })
            XCTFail("A permanently backpressured input must fail")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("Synthetic media encoder timed out:"), message)
            XCTAssertTrue(message.contains("stage=feeding video=0/60 ready=false"), message)
            XCTAssertTrue(message.contains("audio=off writerStatus="), message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testSyntheticFixtureCancellationStopsWaitingAndRemovesOutput() async throws {
        let url = directory.appendingPathComponent("cancelled.mov")
        let requested = expectation(description: "Encoder requested its first input")
        let writing = Task {
            try await SyntheticMovie.write(to: url, readiness: { _ in requested.fulfill(); return false })
        }
        await fulfillment(of: [requested], timeout: 5)
        writing.cancel()
        do {
            try await writing.value
            XCTFail("Canceled fixture must fail")
        } catch is CancellationError { } catch { XCTFail("Unexpected cancellation error: \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testProductionSegmentWriterProducesDecodableVideo() async throws {
        let source = try await fixture()
        let asset = AVURLAsset(url: source.url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); XCTAssertTrue(reader.startReading())
        let first = try XCTUnwrap(output.copyNextSampleBuffer())
        let writer = try SegmentWriter(sample: first, audioEnabled: false, directory: directory)
        try writer.append(first, isAudio: false)
        while let sample = output.copyNextSampleBuffer() {
            while !writer.video.isReadyForMoreMediaData {
                guard writer.writer.status == .writing else { throw writer.writer.error ?? CameraError.unavailable }
                try await Task.sleep(for: .milliseconds(2))
            }
            try writer.append(sample, isAudio: false)
        }
        let result: VideoSegment = try await withCheckedThrowingContinuation { c in
            writer.finish { c.resume(with: $0) }
        }
        XCTAssertGreaterThan(result.bytes, 0)
        XCTAssertEqual(result.duration, 2, accuracy: 0.06)
        try assertDecodable(AVURLAsset(url: result.url))
    }
    func testCompositionTrimsAndPreservesAudio() async throws {
        let source = try await fixture(audio: true)
        let destination = directory.appendingPathComponent("clip.mp4")
        try await ClipComposer().compose(BufferSnapshot(token: UUID(), segments: [source], end: 101.8, window: 1.2), to: destination)
        let asset = AVURLAsset(url: destination)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 1.2, accuracy: 0.06)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(video.count, 1); XCTAssertEqual(audio.count, 1)
        let videoRange = try await video[0].load(.timeRange)
        let audioRange = try await audio[0].load(.timeRange)
        XCTAssertEqual(audioRange.start.seconds, videoRange.start.seconds, accuracy: 0.06)
        XCTAssertEqual(audioRange.duration.seconds, videoRange.duration.seconds, accuracy: 0.08)
        try assertDecodable(asset)
    }
    func testCompositionSortsSegmentsAndCombinesThem() async throws {
        let a = try await fixture()
        let b = VideoSegment(id: UUID(), url: a.url, start: 102, end: 104, bytes: a.bytes)
        let destination = directory.appendingPathComponent("combined.mp4")
        try await ClipComposer().compose(BufferSnapshot(token: UUID(), segments: [b, a], end: 104, window: 3), to: destination)
        let asset = AVURLAsset(url: destination)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 3, accuracy: 0.06)
        try assertDecodable(asset)
    }
    func testEmptyCompositionFailsWithoutOutput() async throws {
        let destination = directory.appendingPathComponent("empty.mp4")
        do {
            try await ClipComposer().compose(BufferSnapshot(token: UUID(), segments: [], end: 2, window: 30), to: destination)
            XCTFail("An empty buffer must not create a clip")
        } catch { XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path)) }
    }
    @MainActor func testLibraryPersistsAcrossReloadAndDoesNotDependOnBuffer() async throws {
        let source = try await fixture()
        let clips = directory.appendingPathComponent("clips")
        let library = ClipLibrary(directory: clips)
        try await library.save(BufferSnapshot(token: UUID(), segments: [source], end: 102, window: 30))
        ProtectedFiles.remove([source.url])
        let reloaded = ClipLibrary(directory: clips); try reloaded.load()
        XCTAssertEqual(reloaded.clips.count, 1)
        try assertDecodable(AVURLAsset(url: reloaded.clips[0].url))
        try reloaded.delete(reloaded.clips[0]); XCTAssertTrue(reloaded.clips.isEmpty)
    }
    @MainActor func testCrashStagingCleanupPreservesSavedClips() throws {
        let partial = directory.appendingPathComponent("abandoned.partial")
        let saved = directory.appendingPathComponent("saved.mp4")
        try Data([1, 2, 3]).write(to: partial); try Data([4, 5, 6]).write(to: saved)
        let library = ClipLibrary(directory: directory); try library.load()
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path)); XCTAssertEqual(library.clips.count, 1)
    }
    func testTemporaryCleanupRemovesOnlyRequestedFiles() throws {
        let buffer = directory.appendingPathComponent("buffer.mov")
        let saved = directory.appendingPathComponent("saved.mp4")
        try Data([1]).write(to: buffer); try Data([2]).write(to: saved)
        ProtectedFiles.remove([buffer]); XCTAssertFalse(FileManager.default.fileExists(atPath: buffer.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
    }
    private func assertDecodable(_ asset: AVAsset) throws {
        let reader = try AVAssetReader(asset: asset)
        // This synchronous track lookup is intentionally used only in test verification.
        let video = try XCTUnwrap(asset.tracks(withMediaType: .video).first)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var count = 0
        while output.copyNextSampleBuffer() != nil { count += 1 }
        XCTAssertEqual(reader.status, .completed); XCTAssertGreaterThan(count, 0)
    }
}
