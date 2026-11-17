#if DEBUG
import Foundation

/// Explicit test/measurement opt-in. No application factory selects this path.
/// This is still the production two-second MOV recorder, not an fMP4 writer.
struct ContinuousSnapshotExperiment {
    enum Mode: CaseIterable, Equatable { case freezingBaseline, continuousMOV }
    let recorder: RollingRecorder

    func snapshot(_ mode: Mode) async throws -> BufferSnapshot {
        switch mode {
        case .freezingBaseline: return try await recorder.snapshot()
        case .continuousMOV: return try await recorder.snapshotKeepingIntake()
        }
    }

    struct WorkingSet {
        /// Includes active/finalizing files and all leased/retired capture files.
        let captureBytes: Int64
        /// Includes partial export output and completed output pending publication.
        let stagingBytes: Int64
        let fileCount: Int
        var totalBytes: Int64 { captureBytes + stagingBytes }
    }

    /// Metadata-only census: no fragment/sample Data copies or unbounded history.
    /// Staging must be a separate experiment-owned directory. Capture leases are
    /// already counted by directory enumeration and must NOT be added twice.
    /// This reports actual bytes, not an enforcement mechanism or a peak estimate.
    func workingSet(stagingDirectory: URL) async throws -> WorkingSet {
        precondition(stagingDirectory.standardizedFileURL != recorder.directory.standardizedFileURL)
        let capture = try await recorder.diagnostics()
        let files = try FileManager.default.contentsOfDirectory(at: stagingDirectory,
            includingPropertiesForKeys: [.isRegularFileKey])
            .filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
        return WorkingSet(captureBytes: capture.diskBytes,
                          stagingBytes: files.reduce(0) { $0 + ProtectedFiles.bytes($1) },
                          fileCount: capture.files.count + files.count)
    }
}
#endif
