import AVFoundation
import SwiftUI

@MainActor final class CameraModel: ObservableObject {
    @Published private(set) var preferences: CameraPreferences
    var duration: Double { preferences.duration }
    var audio: Bool { preferences.audio }
    var front: Bool { preferences.camera == .front }
    @Published private(set) var phase: CapturePhase = .stopped
    @Published private(set) var seconds = 0.0
    @Published private(set) var bytes: Int64 = 0
    @Published private(set) var transitioning = false
    @Published private(set) var saving = false
    @Published var message: String?
    let camera: CameraService
    let library: ClipLibrary
    let testing: Bool
    private var foreground = true
    private var operation = UUID()
    private var transitionCount = 0
    private let preferencesStore: CameraPreferencesStore

    init(camera: CameraService, library: ClipLibrary, testing: Bool = false,
         preferencesStore: CameraPreferencesStore = MemoryCameraPreferencesStore()) {
        self.preferencesStore = preferencesStore
        var initialPreferences = CameraPreferences.defaults
        var preferencesError: String?
        do { initialPreferences = try preferencesStore.load().validated() }
        catch { preferencesError = "Your preferences could not be loaded. Default settings are selected." }
        self.preferences = initialPreferences
        self.camera = camera; self.library = library; self.testing = testing
        message = preferencesError
        camera.onStatistics = { [weak self] statistics in Task { @MainActor in
            self?.seconds = statistics.seconds; self?.bytes = statistics.bytes
        } }
        camera.onInterruption = { [weak self] reason in Task { @MainActor in
            self?.operation = UUID(); self?.phase = .paused; self?.message = reason
        } }
        do { try library.load() } catch { message = error.localizedDescription }
    }
    func start() {
        guard foreground, !transitioning, phase != .buffering else { return }
        beginTransition(); phase = .starting
        let token = UUID(); operation = token
        Task {
            defer { endTransition() }
            do {
                try await camera.start(audio: audio, front: front, duration: duration)
                if operation == token && foreground { phase = .buffering }
                else { await camera.stop() }
            } catch {
                if operation == token {
                    phase = (error as? CameraError).map { if case .permission = $0 { return .denied }; return .failed } ?? .failed
                    message = error.localizedDescription
                }
            }
        }
    }
    private func beginTransition() { transitionCount += 1; transitioning = true }
    private func endTransition() { transitionCount -= 1; transitioning = transitionCount > 0 }
    func stop(paused: Bool = false) {
        operation = UUID()
        phase = paused ? .paused : .stopped
        beginTransition()
        Task { defer { endTransition() }; await camera.stop() }
    }
    func setForeground(_ active: Bool) {
        foreground = active
        if !active { stop(paused: phase == .buffering || phase == .starting || phase == .paused) }
    }
    var canChangePreferences: Bool { phase != .buffering && phase != .starting && !transitioning }
    func updatePreferences(_ edit: (inout CameraPreferences) -> Void) {
        guard canChangePreferences else { return }
        var updated = preferences
        edit(&updated)
        updated = updated.validated()
        guard updated != preferences else { return }
        preferences = updated
        do { try preferencesStore.save(updated) }
        catch { message = "Your preferences could not be saved. They will apply until the app closes." }
    }
    func setDuration(_ duration: Double) {
        guard CameraPreferences.supportedDurations.contains(duration) else { return }
        updatePreferences { $0.duration = duration }
    }
    func setAudio(_ audio: Bool) { updatePreferences { $0.audio = audio } }
    func switchCamera() { updatePreferences { $0.camera = $0.camera == .front ? .rear : .front } }
    func save() {
        guard !saving, phase == .buffering else { return }
        saving = true
        Task {
            do {
                let snapshot = try await camera.snapshot()
                do { try await library.save(snapshot); message = "Moment saved to your library." }
                catch { message = error.localizedDescription }
                await camera.release(snapshot)
            } catch { message = error.localizedDescription }
            saving = false
        }
    }
    var status: String {
        switch phase {
        case .buffering: return "Buffering"
        case .starting: return "Starting camera…"
        case .paused: return "Paused · Tap Start to resume"
        case .denied: return "Camera permission required"
        case .failed: return "Camera unavailable"
        case .stopped: return "Buffer stopped"
        }
    }
}
