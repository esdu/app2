import SwiftUI

struct DimRecordingView: View {
    @AccessibilityFocusState private var statusFocused: Bool
    let status: String
    let seconds: Double
    let battery: BatteryReading
    let canSave: Bool
    let saving: Bool
    let saveStatus: String?
    let postRollRemaining: Double?
    let save: () -> Void
    let wake: () -> Void
    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                Image(systemName: "record.circle").font(.title).accessibilityHidden(true)
                Text(status).font(.title2.weight(.semibold))
                    .accessibilityIdentifier("dimStatus")
                    .accessibilityFocused($statusFocused)
                Text("\(Int(seconds)) seconds ready")
                    .font(.title.monospacedDigit()).accessibilityIdentifier("dimReady")
                Text(battery.text).font(.body).accessibilityIdentifier("dimBattery")
                if saving, let remaining = postRollRemaining, remaining > 0 {
                    Text("Keeping \(Int(ceil(remaining))) more seconds…")
                        .font(.body.monospacedDigit())
                        .accessibilityLabel("Post-roll remaining")
                        .accessibilityValue("\(Int(ceil(remaining))) seconds")
                        .accessibilityIdentifier("dimPostRollStatus")
                }
                if let saveStatus {
                    Text(saveStatus).font(.headline).accessibilityIdentifier("dimSaveStatus")
                }
                Button(action: save) {
                    Label(saving ? "Saving moment…" : "Save moment", systemImage: "arrow.down.to.line")
                        .frame(maxWidth: .infinity, minHeight: 60)
                }.buttonStyle(.bordered).disabled(!canSave)
                    .accessibilityIdentifier("dimSaveButton")
                    .accessibilityHint("Saves the most recent buffer without leaving the dim screen")
                Button("Wake screen", action: wake)
                    .frame(maxWidth: .infinity, minHeight: 60).buttonStyle(.bordered)
                    .accessibilityIdentifier("wakeScreenButton")
                    .accessibilityHint("Shows the camera controls and leaves dim mode")
                Text("Recording continues while this screen is open. Leaving the app pauses the camera.")
                    .font(.footnote)
            }.multilineTextAlignment(.center).padding(28).frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
        }.background(.black).foregroundStyle(.white).tint(.white)
            .accessibilityAddTraits(.isModal)
            .accessibilityAction(.escape, wake)
            .onAppear { statusFocused = true }
    }
}

/// Resolves this view's scene; never picks an arbitrary connected scene or UIScreen.main.
struct CameraSceneReader: UIViewRepresentable {
    let onSceneChange: (UIWindowScene?) -> Void
    func makeUIView(context: Context) -> SceneView {
        let view = SceneView(); view.onSceneChange = onSceneChange; return view
    }
    func updateUIView(_ uiView: SceneView, context: Context) { uiView.onSceneChange = onSceneChange }
    static func dismantleUIView(_ uiView: SceneView, coordinator: ()) { uiView.onSceneChange?(nil) }
    final class SceneView: UIView {
        var onSceneChange: ((UIWindowScene?) -> Void)?
        override func didMoveToWindow() { super.didMoveToWindow(); onSceneChange?(window?.windowScene) }
    }
}
