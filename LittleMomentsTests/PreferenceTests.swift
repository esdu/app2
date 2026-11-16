import AVFoundation
import XCTest
@testable import LittleMoments

private final class PreferenceCamera: CameraService {
    var session: AVCaptureSession? { nil }
    var onStatistics: ((CameraStatistics) -> Void)?
    var onInterruption: ((String) -> Void)?
    var starts = 0
    var lastSettings: CameraPreferences?
    func start(audio: Bool, front: Bool, duration: Double) async throws {
        starts += 1
        lastSettings = CameraPreferences(duration: duration, audio: audio, camera: front ? .front : .rear)
    }
    func stop() async { }
    func snapshot() async throws -> BufferSnapshot { throw CameraError.empty }
    func release(_ snapshot: BufferSnapshot) async { }
}

private final class FailingPreferenceStore: CameraPreferencesStore {
    enum Failure: Error { case unavailable }
    var failLoad = false
    var saves = 0
    func load() throws -> CameraPreferences {
        if failLoad { throw Failure.unavailable }
        return .defaults
    }
    func save(_ preferences: CameraPreferences) throws { saves += 1; throw Failure.unavailable }
}

@MainActor final class PreferenceTests: XCTestCase {
    private func disposableDefaults() -> UserDefaults {
        let suite = "org.littlemoments.PreferenceTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
    private func model(_ camera: PreferenceCamera = PreferenceCamera(),
                       store: CameraPreferencesStore = MemoryCameraPreferencesStore()) -> CameraModel {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return CameraModel(camera: camera, library: ClipLibrary(directory: directory), preferencesStore: store)
    }
    private func waitUntil(_ condition: @escaping @MainActor () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), file: file, line: line)
    }

    func testFreshInstallDefaultsAndRoundTrip() throws {
        let defaults = disposableDefaults()
        let store = UserDefaultsCameraPreferencesStore(defaults: defaults)
        XCTAssertEqual(try store.load(), CameraPreferences(duration: 30, audio: true, camera: .rear))
        let selected = CameraPreferences(duration: 120, audio: false, camera: .front)
        try store.save(selected)
        XCTAssertEqual(try UserDefaultsCameraPreferencesStore(defaults: defaults).load(), selected)
        let data = try XCTUnwrap(defaults.data(forKey: UserDefaultsCameraPreferencesStore.storageKey))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), Set(["duration", "audio", "camera"]))
    }

    func testInvalidFieldsFallBackIndependently() throws {
        let defaults = disposableDefaults()
        let store = UserDefaultsCameraPreferencesStore(defaults: defaults)
        let records: [(String, CameraPreferences)] = [
            (#"{"duration":999,"audio":false,"camera":"front"}"#, .init(duration: 30, audio: false, camera: .front)),
            (#"{"duration":60,"audio":"invalid","camera":"front"}"#, .init(duration: 60, audio: true, camera: .front)),
            (#"{"duration":15,"audio":false,"camera":"futureCamera"}"#, .init(duration: 15, audio: false, camera: .rear)),
            (#"{"duration":"120","audio":false,"camera":"front"}"#, .init(duration: 30, audio: false, camera: .front))
        ]
        for (record, expected) in records {
            defaults.set(Data(record.utf8), forKey: UserDefaultsCameraPreferencesStore.storageKey)
            XCTAssertEqual(try store.load(), expected, record)
        }
    }

    func testMissingFieldsAndUnknownFieldsPreserveOtherChoices() throws {
        let defaults = disposableDefaults()
        let store = UserDefaultsCameraPreferencesStore(defaults: defaults)
        defaults.set(Data(#"{"duration":60,"camera":"front","futureOption":5}"#.utf8),
                     forKey: UserDefaultsCameraPreferencesStore.storageKey)
        XCTAssertEqual(try store.load(), CameraPreferences(duration: 60, audio: true, camera: .front))
        defaults.set(Data(#"{"audio":false}"#.utf8), forKey: UserDefaultsCameraPreferencesStore.storageKey)
        XCTAssertEqual(try store.load(), CameraPreferences(duration: 30, audio: false, camera: .rear))
    }

    func testCorruptAndWrongTypeRecordsUseDefaults() throws {
        let defaults = disposableDefaults()
        let store = UserDefaultsCameraPreferencesStore(defaults: defaults)
        let corruptValues: [Any] = [Data("not JSON".utf8), Data("[]".utf8), Data("null".utf8), "not data"]
        for value in corruptValues {
            defaults.set(value, forKey: UserDefaultsCameraPreferencesStore.storageKey)
            XCTAssertEqual(try store.load(), .defaults)
        }
    }

    func testRelaunchRestoresChoicesButNeverStartsCapture() async throws {
        let defaults = disposableDefaults()
        let camera = PreferenceCamera()
        let first = model(camera, store: UserDefaultsCameraPreferencesStore(defaults: defaults))
        first.setDuration(60); first.setAudio(false); first.switchCamera()
        first.start(); await waitUntil { !first.transitioning }
        XCTAssertEqual(camera.lastSettings, CameraPreferences(duration: 60, audio: false, camera: .front))
        first.stop(); await waitUntil { !first.transitioning }

        let relaunchedCamera = PreferenceCamera()
        let relaunched = model(relaunchedCamera, store: UserDefaultsCameraPreferencesStore(defaults: defaults))
        XCTAssertEqual(relaunched.preferences, first.preferences)
        XCTAssertEqual(relaunched.phase, .stopped)
        XCTAssertEqual(relaunchedCamera.starts, 0)
        XCTAssertFalse(relaunched.transitioning)
        XCTAssertFalse(relaunched.saving)
        XCTAssertEqual(relaunched.seconds, 0)
    }

    func testUpdatesAreRejectedDuringStartupCaptureAndStop() async throws {
        let store = MemoryCameraPreferencesStore()
        let subject = model(store: store)
        func attemptChanges() {
            subject.setDuration(120); subject.setAudio(false); subject.switchCamera()
            XCTAssertEqual(subject.preferences, .defaults)
        }
        subject.start(); attemptChanges()
        await waitUntil { !subject.transitioning }
        XCTAssertEqual(subject.phase, .buffering)
        attemptChanges()
        subject.stop(); attemptChanges()
        await waitUntil { !subject.transitioning }
        XCTAssertEqual(try store.load(), .defaults)
        subject.setDuration(15); subject.setAudio(false); subject.switchCamera()
        XCTAssertEqual(try store.load(), CameraPreferences(duration: 15, audio: false, camera: .front))
        subject.setDuration(999)
        XCTAssertEqual(subject.duration, 15)
    }

    func testPersistenceFailuresKeepLaunchStoppedAndCurrentChoicesUsable() {
        let store = FailingPreferenceStore(); store.failLoad = true
        let camera = PreferenceCamera(); let subject = model(camera, store: store)
        XCTAssertEqual(subject.phase, .stopped)
        XCTAssertEqual(camera.starts, 0)
        XCTAssertEqual(subject.preferences, .defaults)
        XCTAssertNotNil(subject.message)
        subject.setAudio(false)
        XCTAssertFalse(subject.audio)
        XCTAssertEqual(store.saves, 1)
        XCTAssertNotNil(subject.message)
    }

    func testModelDefaultsAndUITestDomainsAreIsolated() throws {
        let first = model(); first.setAudio(false); first.setDuration(120); first.switchCamera()
        XCTAssertEqual(model().preferences, .defaults)
        let domain = "org.littlemoments.UITests." + UUID().uuidString
        let args = ["--uitest-preferences-suite=" + domain]
        addTeardownBlock { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        let selected = CameraPreferences(duration: 15, audio: false, camera: .front)
        try UserDefaultsCameraPreferencesStore.forUITesting(arguments: args).save(selected)
        XCTAssertEqual(try UserDefaultsCameraPreferencesStore.forUITesting(arguments: args).load(), selected)
        XCTAssertEqual(try UserDefaultsCameraPreferencesStore.forUITesting(arguments: args + ["--reset-uitest-preferences"]).load(), .defaults)
        let transient = UserDefaultsCameraPreferencesStore.forUITesting(arguments: [])
        try transient.save(selected)
        XCTAssertEqual(try UserDefaultsCameraPreferencesStore.forUITesting(arguments: []).load(), .defaults)
    }
}
