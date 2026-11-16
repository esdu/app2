import AVFoundation

struct ClipComposer {
    /// Source timestamps remain on the shared capture clock; each source range is
    /// translated once, including its audio. Gaps are collapsed without A/V drift.
    func compose(_ snapshot: BufferSnapshot, to destination: URL) async throws {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw CameraError.empty }
        var cursor = CMTime.zero
        for segment in snapshot.segments.sorted(by: { $0.start < $1.start }) {
            let asset = AVURLAsset(url: segment.url)
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let videoRange = try await sourceVideo.load(.timeRange)
            let localStart = max(0, snapshot.end - snapshot.window - segment.start)
            let length = min(segment.duration, snapshot.end - segment.start) - localStart
            guard length > 0 else { continue }
            let desired = CMTimeRange(start: CMTime(seconds: localStart, preferredTimescale: 60_000),
                                      duration: CMTime(seconds: length, preferredTimescale: 60_000))
            let range = CMTimeRangeGetIntersection(desired, videoRange)
            guard range.duration.isNumeric, range.duration > .zero else { continue }
            try video.insertTimeRange(range, of: sourceVideo, at: cursor)
            video.preferredTransform = try await sourceVideo.load(.preferredTransform)
            if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                let audioRange = CMTimeRangeGetIntersection(range, try await sourceAudio.load(.timeRange))
                if audioRange.duration.isNumeric, audioRange.duration > .zero {
                    try audio.insertTimeRange(audioRange, of: sourceAudio, at: cursor + audioRange.start - range.start)
                }
            }
            cursor = cursor + range.duration
        }
        guard cursor > .zero else { throw CameraError.empty }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw CameraError.unavailable }
        export.outputURL = destination
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = false
        do {
            await export.export()
            guard export.status == .completed else { throw export.error ?? CameraError.writer("The clip could not be exported.") }
            try ProtectedFiles.protect(destination)
        } catch { ProtectedFiles.remove([destination]); throw error }
    }
}
