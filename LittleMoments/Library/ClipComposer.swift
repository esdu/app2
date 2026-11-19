import AVFoundation

enum ClipExportStrategy: Equatable {
    case highestQuality
    /// Internal evaluation only. No app preference or production caller selects it.
    case evaluatePassthrough
}

enum ClipExportFailure: Error {
    case incompatible
}

protocol ClipExportBackend {
    func supportsPassthrough(_ asset: AVAsset) async -> Bool
    func export(_ asset: AVAsset, preset: String, to destination: URL) async throws
}

struct SystemClipExportBackend: ClipExportBackend {
    func supportsPassthrough(_ asset: AVAsset) async -> Bool {
        await withCheckedContinuation { continuation in
            AVAssetExportSession.determineCompatibility(ofExportPreset: AVAssetExportPresetPassthrough,
                with: asset, outputFileType: .mp4) { continuation.resume(returning: $0) }
        }
    }
    func export(_ asset: AVAsset, preset: String, to destination: URL) async throws {
        try Task.checkCancellation()
        // Every attempt owns a fresh session. Sessions cannot be reused after failure.
        guard let session = AVAssetExportSession(asset: asset, presetName: preset),
              session.supportedFileTypes.contains(.mp4) else { throw ClipExportFailure.incompatible }
        session.outputURL = destination
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = false
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            await session.export()
            try Task.checkCancellation()
            guard session.status == .completed else {
                if session.status == .cancelled { throw CancellationError() }
                throw session.error ?? CameraError.writer("The clip could not be exported.")
            }
        } onCancel: { session.cancelExport() }
    }
}

struct ClipComposer {
    let strategy: ClipExportStrategy
    let backend: any ClipExportBackend
    init(strategy: ClipExportStrategy = .highestQuality, backend: any ClipExportBackend = SystemClipExportBackend()) {
        self.strategy = strategy; self.backend = backend
    }

    /// Only explicit incompatibility and the AVFoundation unsupported-operation
    /// error qualify for retry. Unknown export failures stay actionable.
    static func allowsPassthroughFallback(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let failure = error as? ClipExportFailure, case .incompatible = failure { return true }
        let failure = error as NSError
        // Never hide a causal filesystem/cancellation/unknown failure behind a
        // generic compatibility wrapper. Conservative retry is intentional.
        if let underlying = failure.userInfo[NSUnderlyingErrorKey] as? Error,
           !allowsPassthroughFallback(underlying) { return false }
        return failure.domain == AVFoundationErrorDomain &&
            failure.code == AVError.operationNotSupportedForAsset.rawValue
    }
    /// Source timestamps remain on the shared capture clock; each source range is
    /// translated once, including its audio. Gaps are collapsed without A/V drift.
    func compose(_ snapshot: BufferSnapshot, to destination: URL) async throws {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw CameraError.empty }
        // Empty audio tracks can make otherwise valid silent assets non-exportable.
        var audio: AVMutableCompositionTrack?
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
            let range = CMTimeRangeGetIntersection(desired, otherRange: videoRange)
            guard range.duration.isNumeric, range.duration > .zero else { continue }
            try video.insertTimeRange(range, of: sourceVideo, at: cursor)
            video.preferredTransform = try await sourceVideo.load(.preferredTransform)
            if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                let audioRange = CMTimeRangeGetIntersection(range, otherRange: try await sourceAudio.load(.timeRange))
                if audioRange.duration.isNumeric, audioRange.duration > .zero {
                    if audio == nil { audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
                    guard let audio else { throw CameraError.unavailable }
                    try audio.insertTimeRange(audioRange, of: sourceAudio, at: cursor + audioRange.start - range.start)
                }
            }
            cursor = cursor + range.duration
        }
        guard cursor > .zero else { throw CameraError.empty }
        do {
            try Task.checkCancellation()
            let usePassthrough: Bool
            if strategy == .evaluatePassthrough { usePassthrough = await backend.supportsPassthrough(composition) }
            else { usePassthrough = false }
            if usePassthrough {
                do {
                    try await backend.export(composition, preset: AVAssetExportPresetPassthrough, to: destination)
                } catch {
                    try Task.checkCancellation()
                    guard Self.allowsPassthroughFallback(error) else { throw error }
                    // Keep the same immutable source composition/lease; remove only
                    // this attempt's partial destination before making a fresh session.
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try await backend.export(composition, preset: AVAssetExportPresetHighestQuality, to: destination)
                }
            } else {
                try await backend.export(composition, preset: AVAssetExportPresetHighestQuality, to: destination)
            }
            try Task.checkCancellation()
            try ProtectedFiles.protect(destination)
        } catch { ProtectedFiles.remove([destination]); throw error }
    }
}
