import SwiftUI

@main struct LittleMomentsApp: App {
    @StateObject private var model: CameraModel
    @Environment(\.scenePhase) private var scenePhase
    init() {
        let library = ClipLibrary()
        #if DEBUG
        let testing = ProcessInfo.processInfo.arguments.contains("--uitesting")
        if testing {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("UITestLibrary")
            try? FileManager.default.removeItem(at: root)
            let service = SyntheticCamera(denied: ProcessInfo.processInfo.arguments.contains("--deny-camera"))
            _model = StateObject(wrappedValue: CameraModel(camera: service, library: ClipLibrary(directory: root), testing: true))
        } else {
            _model = StateObject(wrappedValue: CameraModel(camera: CaptureEngine(), library: library))
        }
        #else
        _model = StateObject(wrappedValue: CameraModel(camera: CaptureEngine(), library: library))
        #endif
    }
    var body: some Scene {
        WindowGroup {
            CameraView(model: model).preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    model.setForeground(phase == .active)
                    UIApplication.shared.isIdleTimerDisabled = phase == .active && model.phase == .buffering
                }
                .onChange(of: model.phase) { _, phase in
                    UIApplication.shared.isIdleTimerDisabled = phase == .buffering && scenePhase == .active
                }
        }
    }
}
