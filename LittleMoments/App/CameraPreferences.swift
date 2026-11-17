import Foundation

/// Durable user choices only. Capture phase, permissions and clip metadata belong elsewhere.
struct CameraPreferences: Codable, Equatable {
    enum Camera: String, Codable { case rear, front }

    static let supportedDurations: [Double] = [15, 30, 60, 120]
    static let defaults = CameraPreferences()
    var duration: Double = 30
    var audio = true
    var camera: Camera = .rear

    init(duration: Double = 30, audio: Bool = true, camera: Camera = .rear) {
        self.duration = Self.supportedDurations.contains(duration) ? duration : 30
        self.audio = audio
        self.camera = camera
    }

    private enum CodingKeys: String, CodingKey { case duration, audio, camera }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        // Decode independently so an old, corrupt or future field cannot erase valid choices.
        self.init(duration: (try? fields.decode(Double.self, forKey: .duration)) ?? 30,
                  audio: (try? fields.decode(Bool.self, forKey: .audio)) ?? true,
                  camera: (try? fields.decode(Camera.self, forKey: .camera)) ?? .rear)
    }

    func validated() -> CameraPreferences {
        var result = self
        if !Self.supportedDurations.contains(result.duration) { result.duration = 30 }
        return result
    }
}

protocol CameraPreferencesStore {
    func load() throws -> CameraPreferences
    func save(_ preferences: CameraPreferences) throws
}

/// Used by model tests and previews unless the app explicitly injects durable storage.
final class MemoryCameraPreferencesStore: CameraPreferencesStore {
    private var preferences: CameraPreferences
    init(_ preferences: CameraPreferences = .defaults) { self.preferences = preferences }
    func load() throws -> CameraPreferences { preferences }
    func save(_ preferences: CameraPreferences) throws { self.preferences = preferences }
}

final class UserDefaultsCameraPreferencesStore: CameraPreferencesStore {
    // Add optional/defaulted fields to v1. Incompatible representations require a new key
    // and an explicit migration; never infer or restore recording state from this record.
    static let storageKey = "LittleMoments.cameraPreferences.v1"
    private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }

    func load() throws -> CameraPreferences {
        guard let data = defaults.data(forKey: Self.storageKey) else { return .defaults }
        return (try? JSONDecoder().decode(CameraPreferences.self, from: data)) ?? .defaults
    }
    func save(_ preferences: CameraPreferences) throws {
        defaults.set(try JSONEncoder().encode(preferences.validated()), forKey: Self.storageKey)
    }

    #if DEBUG
    /// The default UI-test domain resets on every launch. A test may supply its own
    /// namespaced domain to preserve settings across a deliberate relaunch.
    static func forUITesting(arguments: [String]) -> CameraPreferencesStore {
        let prefix = "--uitest-preferences-suite="
        let requested = arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        let namespace = "org.littlemoments.UITests."
        let suite = requested.flatMap { $0.hasPrefix(namespace) ? $0 : nil } ?? namespace + "Transient"
        guard let defaults = UserDefaults(suiteName: suite) else { return MemoryCameraPreferencesStore() }
        if requested == nil || suite == namespace + "Transient" || arguments.contains("--reset-uitest-preferences") {
            defaults.removePersistentDomain(forName: suite)
        }
        return UserDefaultsCameraPreferencesStore(defaults: defaults)
    }
    #endif
}
