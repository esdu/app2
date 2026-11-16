import UIKit

/// The save boundary returns only after its persistent commit has completed.
@MainActor protocol MomentSaving {
    func save(_ snapshot: BufferSnapshot) async throws
}
extension ClipLibrary: MomentSaving {}

enum SaveOutcome: Equatable {
    case success
    case failure(String)
    var text: String {
        switch self {
        case .success: return "Moment saved to your library"
        case .failure(let reason): return reason
        }
    }
}

@MainActor protocol SaveHaptics {
    func notify(_ outcome: SaveOutcome)
}
@MainActor final class SystemSaveHaptics: SaveHaptics {
    func notify(_ outcome: SaveOutcome) {
        UINotificationFeedbackGenerator().notificationOccurred(outcome == .success ? .success : .error)
    }
}

@MainActor protocol SaveAnnouncing {
    func announce(_ text: String)
}
@MainActor final class VoiceOverSaveAnnouncer: SaveAnnouncing {
    func announce(_ text: String) {
        // An announcement leaves the user's current VoiceOver focus in place.
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}

@MainActor protocol FeedbackCancellation: AnyObject {
    func cancel()
}
@MainActor protocol FeedbackScheduling {
    func schedule(after delay: Duration, action: @escaping @MainActor () -> Void) -> any FeedbackCancellation
}
@MainActor final class TaskFeedbackScheduler: FeedbackScheduling {
    private final class Cancellation: FeedbackCancellation {
        let task: Task<Void, Never>
        init(_ task: Task<Void, Never>) { self.task = task }
        func cancel() { task.cancel() }
        deinit { task.cancel() }
    }
    func schedule(after delay: Duration, action: @escaping @MainActor () -> Void) -> any FeedbackCancellation {
        Cancellation(Task { @MainActor in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            action()
        })
    }
}
