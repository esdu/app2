import AVFoundation
import Foundation
import SwiftUI

/// Capture callbacks originate off-main. Capture their lifecycle at invocation,
/// before hopping to MainActor, so queued events cannot affect a later start.
private final class CaptureCallbackGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value = UUID()
    var current: UUID { lock.withLock { value } }
    func invalidate() { lock.withLock { value = UUID() } }
}

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
    @Published private(set) var thermalState: ThermalLevel
    @Published var message: String?
    @Published private(set) var saveStatus: String?
    @Published private(set) var foreground = true
    @Published private(set) var cameraScreenVisible = true
    let camera: CameraService
    let library: ClipLibrary
    let testing: Bool
    private let saver: any MomentSaving
    private let haptics: any SaveHaptics
    private let announcer: any SaveAnnouncing
    private let feedbackScheduler: any FeedbackScheduling
    private var feedbackDismissal: (any FeedbackCancellation)?
    private var feedbackToken = UUID()
    private var pendingSaveOutcome: SaveOutcome?
    private var operation = UUID()
    private var transitionCount = 0
    private let preferencesStore: CameraPreferencesStore
    private let thermalMonitor: ThermalMonitoring
    private var stoppedStartupOperation: UUID?
    private var stopping = false
    private let callbackGeneration = CaptureCallbackGeneration()

    init(camera: CameraService, library: ClipLibrary, testing: Bool = false,
         preferencesStore: CameraPreferencesStore = MemoryCameraPreferencesStore(),
         saver: (any MomentSaving)? = nil, haptics: (any SaveHaptics)? = nil,
         announcer: (any SaveAnnouncing)? = nil, feedbackScheduler: (any FeedbackScheduling)? = nil,
         thermalMonitor: ThermalMonitoring? = nil) {
        self.preferencesStore = preferencesStore
        let monitor = thermalMonitor ?? MutableThermalMonitor()
        self.thermalMonitor = monitor
        self.thermalState = monitor.state
        var initialPreferences = CameraPreferences.defaults
        var preferencesError: String?
        do { initialPreferences = try preferencesStore.load().validated() }
        catch { preferencesError = "Your preferences could not be loaded. Default settings are selected." }
        self.preferences = initialPreferences
        self.camera = camera; self.library = library; self.testing = testing
        self.saver = saver ?? library
        self.haptics = haptics ?? SystemSaveHaptics()
        self.announcer = announcer ?? VoiceOverSaveAnnouncer()
        self.feedbackScheduler = feedbackScheduler ?? TaskFeedbackScheduler()
        message = preferencesError
        monitor.onChange = { [weak self] in self?.refreshThermalState() }
        let callbackGeneration = self.callbackGeneration
        camera.onStatistics = { [weak self] statistics in
            let token = callbackGeneration.current
            Task { @MainActor in
                guard let self, callbackGeneration.current == token else { return }
                // A stopped recorder may still report leased bytes while a save drains.
                // Its old ready duration must never enable a new save after capture exits.
                self.bytes = statistics.bytes
                self.seconds = self.phase == .buffering || self.phase == .starting ? statistics.seconds : 0
            }
        }
        camera.onInterruption = { [weak self] reason in
            let token = callbackGeneration.current
            Task { @MainActor in
                guard let self, callbackGeneration.current == token,
                      self.phase == .buffering || self.phase == .starting else { return }
                callbackGeneration.invalidate()
                self.operation = UUID(); self.phase = .paused; self.seconds = 0; self.message = reason
            }
        }
        do { try library.load() } catch { message = error.localizedDescription }
    }
    func start() {
        refreshThermalState()
        guard canStart else { return }
        callbackGeneration.invalidate()
        seconds = 0
        beginTransition(); phase = .starting
        let token = UUID(); operation = token
        Task {
            defer {
                if stoppedStartupOperation == token { stoppedStartupOperation = nil }
                endTransition()
            }
            guard operation == token, foreground, cameraScreenVisible, !ThermalPolicy(state: thermalMonitor.state).blocksCapture else {
                refreshThermalState()
                return
            }
            do {
                try await camera.start(audio: audio, front: front, duration: duration)
                refreshThermalState()
                if operation == token && foreground && cameraScreenVisible && !ThermalPolicy(state: thermalState).blocksCapture { phase = .buffering }
                else if stoppedStartupOperation != token { await camera.stop() }
            } catch {
                refreshThermalState()
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
        let needsStop = phase == .buffering || phase == .starting
        if phase == .starting { stoppedStartupOperation = operation }
        callbackGeneration.invalidate()
        operation = UUID()
        phase = paused ? .paused : .stopped
        seconds = 0
        guard needsStop, !stopping else { return }
        stopping = true
        beginTransition()
        Task { defer { stopping = false; endTransition() }; await camera.stop() }
    }
    func setForeground(_ active: Bool) {
        foreground = active
        if !active {
            clearSaveStatus()
            if phase == .buffering || phase == .starting { stop(paused: true) }
        } else if let outcome = pendingSaveOutcome {
            pendingSaveOutcome = nil
            presentSaveOutcome(outcome, playHaptics: false)
        }
    }
    var thermalWarning: String? { ThermalPolicy(state: thermalState).warning }
    var canStart: Bool {
        foreground && cameraScreenVisible && !transitioning && phase != .buffering && !ThermalPolicy(state: thermalState).blocksCapture
    }
    private func refreshThermalState() {
        let current = thermalMonitor.state
        if thermalState != current { thermalState = current }
        guard ThermalPolicy(state: current).blocksCapture, phase == .buffering || phase == .starting else { return }
        // CameraService.stop invalidates pending production startup and preserves pinned sources.
        // Keep the save task alive so its existing success/failure path releases its own lease.
        stop(paused: true)
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
    func setCameraScreenVisible(_ visible: Bool) { cameraScreenVisible = visible }
    var canSave: Bool {
        foreground && cameraScreenVisible && !transitioning && phase == .buffering && seconds > 0 && !saving
    }

    func save() {
        guard canSave else { return }
        saving = true
        Task {
            let outcome: SaveOutcome
            do {
                let snapshot = try await camera.snapshot()
                do { try await saver.save(snapshot); outcome = .success }
                catch { outcome = .failure(error.localizedDescription) }
                await camera.release(snapshot)
            } catch { outcome = .failure(error.localizedDescription) }
            saving = false
            if foreground { presentSaveOutcome(outcome, playHaptics: true) }
            else { pendingSaveOutcome = outcome }
        }
    }
    private func presentSaveOutcome(_ outcome: SaveOutcome, playHaptics: Bool) {
        if playHaptics { haptics.notify(outcome) }
        announcer.announce(outcome.text)
        switch outcome {
        case .success:
            clearSaveStatus()
            saveStatus = outcome.text
            let token = feedbackToken
            feedbackDismissal = feedbackScheduler.schedule(after: .seconds(5)) { [weak self] in
                guard let self, self.feedbackToken == token else { return }
                self.clearSaveStatus()
            }
        case .failure(let reason):
            clearSaveStatus()
            message = reason
        }
    }
    private func clearSaveStatus() {
        feedbackToken = UUID()
        feedbackDismissal?.cancel()
        feedbackDismissal = nil
        saveStatus = nil
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
