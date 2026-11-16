import AVFoundation
import Foundation

struct BufferSnapshot {
    let token: UUID
    let segments: [VideoSegment]
    let end: Double
    let window: Double
}
struct CameraStatistics {
    let seconds: Double
    let bytes: Int64
}
enum CameraError: LocalizedError {
    case permission, unavailable, empty, busy, storage, writer(String)
    var errorDescription: String? {
        switch self {
        case .permission: return "Camera access is required. Enable it in Settings. You can also turn audio off if microphone access is denied."
        case .unavailable: return "This camera is unavailable. Try again on an iPhone."
        case .empty: return "The buffer is still warming up. Wait a moment and try again."
        case .busy: return "A clip is already being saved."
        case .storage: return "Temporary storage is full or disk space is low. Buffering has stopped."
        case .writer(let message): return message
        }
    }
}
protocol CameraService: AnyObject {
    var session: AVCaptureSession? { get }
    var onStatistics: ((CameraStatistics) -> Void)? { get set }
    var onInterruption: ((String) -> Void)? { get set }
    func start(audio: Bool, front: Bool, duration: Double) async throws
    func stop() async
    func snapshot() async throws -> BufferSnapshot
    func release(_ snapshot: BufferSnapshot) async
}
