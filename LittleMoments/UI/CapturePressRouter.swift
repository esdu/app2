import Foundation

/// An activation owns its callbacks; disabling it invalidates even retained handlers.
@MainActor final class CapturePressRouter {
    enum Phase { case began, ended, cancelled }
    private var generation = UUID()
    private var enabled = false
    private var inProgress = false
    private var armed = false
    private var canSave: @MainActor () -> Bool = { false }
    private var save: @MainActor () -> Void = {}

    func update(enabled: Bool, canSave: @escaping @MainActor () -> Bool,
                save: @escaping @MainActor () -> Void) {
        self.canSave = canSave
        self.save = save
        if self.enabled != enabled {
            self.enabled = enabled
            generation = UUID()
            clearPress()
        }
    }
    func makeHandler() -> @MainActor (Phase) -> Void {
        let token = generation
        return { [weak self] phase in self?.receive(phase, generation: token) }
    }
    func invalidate() {
        enabled = false
        generation = UUID()
        clearPress()
        canSave = { false }
        save = {}
    }
    private func clearPress() { inProgress = false; armed = false }
    private func receive(_ phase: Phase, generation token: UUID) {
        guard enabled, token == generation else { return }
        switch phase {
        case .began:
            guard !inProgress else { return } // Holding a button does not re-arm it.
            inProgress = true
            armed = canSave()
        case .ended:
            let completed = inProgress && armed
            clearPress() // Clear before calling out, including reentrant callbacks.
            guard completed, canSave() else { return }
            save()
        case .cancelled:
            clearPress()
        }
    }
}

enum HardwareSaveAvailability {
    static func allows(testing: Bool, foreground: Bool, cameraScreenVisible: Bool,
                       canSave: Bool, sessionRunning: Bool) -> Bool {
        !testing && foreground && cameraScreenVisible && canSave && sessionRunning
    }
}
