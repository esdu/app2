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
