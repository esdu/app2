import AVKit
import SwiftUI
import UIKit

extension CameraModel {
    var hardwareSaveEnabled: Bool {
        HardwareSaveAvailability.allows(testing: testing, foreground: foreground,
            cameraScreenVisible: cameraScreenVisible, canSave: canSave,
            sessionRunning: camera.session?.isRunning == true)
    }
}

/// Unsupported systems retain the onscreen Save Moment control.
struct HardwareSaveInteraction: View {
    @ObservedObject var model: CameraModel
    var body: some View {
        if #available(iOS 17.2, *) {
            CaptureButtonHost(enabled: model.hardwareSaveEnabled,
                canSave: { model.hardwareSaveEnabled }, save: {
                    guard model.hardwareSaveEnabled else { return }
                    model.save()
                })
        } else {
            EmptyView()
        }
    }
}

/// Keep the view interactive for UIInteraction delivery, while passing all touches
/// through to SwiftUI controls, including a dim-screen wake surface.
final class CaptureButtonPassthroughView: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }
}

@available(iOS 17.2, *)
struct CaptureButtonHost: UIViewRepresentable {
    let enabled: Bool
    let canSave: @MainActor () -> Bool
    let save: @MainActor () -> Void

    @MainActor final class Coordinator {
        private let router = CapturePressRouter()
        private var interaction: AVCaptureEventInteraction?

        func update(_ view: UIView, enabled: Bool,
                    canSave: @escaping @MainActor () -> Bool, save: @escaping @MainActor () -> Void) {
            router.update(enabled: enabled, canSave: canSave, save: save)
            guard enabled else { removeInteraction(from: view); return }
            guard interaction == nil else { return }
            let handler = router.makeHandler()
            let interaction = AVCaptureEventInteraction { event in
                // UIKit delivers capture interaction callbacks on the main thread.
                MainActor.assumeIsolated {
                    switch event.phase {
                    case .began: handler(.began)
                    case .ended: handler(.ended)
                    case .cancelled: handler(.cancelled)
                    @unknown default: handler(.cancelled)
                    }
                }
            }
            interaction.isEnabled = true
            self.interaction = interaction
            view.addInteraction(interaction)
        }
        func dismantle(_ view: UIView) {
            router.invalidate()
            removeInteraction(from: view)
        }
        private func removeInteraction(from view: UIView) {
            interaction?.isEnabled = false
            if let interaction { view.removeInteraction(interaction) }
            interaction = nil
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> CaptureButtonPassthroughView {
        let view = CaptureButtonPassthroughView()
        view.backgroundColor = .clear
        view.isAccessibilityElement = false
        context.coordinator.update(view, enabled: enabled, canSave: canSave, save: save)
        return view
    }
    func updateUIView(_ uiView: CaptureButtonPassthroughView, context: Context) {
        context.coordinator.update(uiView, enabled: enabled, canSave: canSave, save: save)
    }
    static func dismantleUIView(_ uiView: CaptureButtonPassthroughView, coordinator: Coordinator) {
        coordinator.dismantle(uiView)
    }
}
