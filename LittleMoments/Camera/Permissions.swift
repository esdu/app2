import AVFoundation
import Photos

struct Permissions {
    static func capture(audio: Bool) async -> Bool {
        guard await access(.video) else { return false }
        if audio { return await access(.audio) }
        return true
    }
    private static func access(_ type: AVMediaType) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: type)
        default: return false
        }
    }
    static func exportToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw CameraError.writer("Photos access was denied. You can enable it in Settings or share the clip instead.")
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}
