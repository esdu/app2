import SwiftUI

@MainActor struct CameraView: View {
    @ObservedObject var model: CameraModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var dimScreen = DimScreenCoordinator()
    @State private var showingLibrary = false
    private let accent = Color(red: 0.91, green: 0.80, blue: 0.61)
    var body: some View {
        cameraNavigation.tint(accent)
            .safeAreaInset(edge: .top) { saveFeedback }
            .background(CameraSceneReader { dimScreen.attach(to: $0) }.frame(width: 0, height: 0))
            .overlay { dimOverlay }
            .onAppear { dimScreen.setUIActive(scenePhase == .active && !showingLibrary) }
            .onDisappear { dimScreen.setUIActive(false) }
            .onChange(of: scenePhase) { _, phase in dimScreen.setUIActive(phase == .active && !showingLibrary) }
            .onChange(of: model.phase) { _, phase in dimScreen.capturePhaseChanged(phase) }
    }

    private var cameraNavigation: some View {
        NavigationStack { cameraScroll }
    }

    private var cameraScroll: some View {
        ScrollView { cameraSections }.background(Color(white: 0.045)).toolbar(.hidden, for: .navigationBar)
            .accessibilityHidden(dimScreen.isDimmed)
            .navigationDestination(isPresented: $showingLibrary) { LibraryView(library: model.library) }
            .onChange(of: showingLibrary) { _, shown in
                model.setCameraScreenVisible(!shown)
                dimScreen.setUIActive(!shown && scenePhase == .active)
                if shown { model.stop() }
            }
            .alert("Little Moments", isPresented: Binding(get: { model.foreground && model.message != nil }, set: { if !$0 && model.foreground { model.message = nil } })) {
                Button("OK") { model.message = nil }
            } message: { Text(model.message ?? "") }
    }

    private var cameraSections: some View {
        VStack(spacing: 22) {
            header
            preview
            preferencesSection
            saveButton
            captureActions
            dimActions
            permissionHelp
            privacyFooter
        }.padding(22)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Little Moments").font(.title2.weight(.semibold))
                Text("Be here. Keep the moment.").font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showingLibrary = true } label: {
                VStack(spacing: 3) {
                    Image(systemName: "square.stack").font(.title2)
                    Text("\(model.library.clips.count) saved").font(.caption2)
                }.frame(minWidth: 48, minHeight: 48)
            }.accessibilityLabel("Saved clips").accessibilityValue("\(model.library.clips.count) saved").accessibilityIdentifier("libraryButton")
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28).fill(Color(white: 0.10))
            if let session = model.camera.session {
                CameraPreview(session: session).clipShape(RoundedRectangle(cornerRadius: 28))
            }
            if model.phase != .buffering {
                VStack(spacing: 12) {
                    Image(systemName: model.phase == .denied ? "camera.badge.ellipsis" : "camera.aperture").font(.system(size: 42, weight: .ultraLight))
                    Text(model.phase == .paused ? "Your camera is paused" : "Ready for the little things").font(.headline)
                    Text("Tap Start Buffer to turn on the camera.").font(.subheadline).foregroundStyle(.secondary)
                }.multilineTextAlignment(.center).padding().background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20)).padding()
            } else if model.testing {
                VStack(spacing: 12) {
                    Image(systemName: "sparkles.tv").font(.largeTitle)
                    Text("Simulator test camera").font(.headline)
                    Text("Deterministic 2-second video fixture").font(.caption)
                }
            }
            VStack {
                HStack(spacing: 8) {
                    Circle().fill(model.phase == .buffering ? .red : .gray).frame(width: 8, height: 8)
                    Text(model.status).font(.caption.weight(.semibold)).accessibilityIdentifier("bufferStatus")
                    Spacer()
                }.padding(14).background(.black.opacity(0.65), in: Capsule())
                Spacer()
                Text("\(Int(model.seconds))s ready · \(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file)) temporary")
                    .font(.caption.monospacedDigit()).padding(12).background(.black.opacity(0.65), in: Capsule())
            }.padding(16)
        }.frame(height: 330).accessibilityElement(children: .contain)
    }

    private var preferencesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Keep the last").font(.subheadline.weight(.medium)); Spacer(); Text("\(Int(model.duration)) seconds").foregroundStyle(accent) }
            Picker("Buffer duration", selection: $model.duration) {
                ForEach([15.0, 30, 60, 120], id: \.self) { duration in Text("\(Int(duration))s").tag(duration) }
            }.pickerStyle(.segmented).accessibilityIdentifier("durationPicker")
                .disabled(model.phase == .buffering || model.transitioning)
        }
    }

    private var saveButton: some View {
        Button { model.save() } label: {
            HStack(spacing: 12) {
                if model.saving { ProgressView().tint(.black) } else { Image(systemName: "arrow.down.to.line") }
                Text(model.saving ? "SAVING…" : "SAVE MOMENT").tracking(1.5)
            }.font(.headline).frame(maxWidth: .infinity).frame(minHeight: 70)
        }.buttonStyle(.plain).background(accent, in: RoundedRectangle(cornerRadius: 24)).foregroundStyle(.black)
            .opacity(model.canSave || model.saving ? 1 : 0.4)
            .disabled(!model.canSave)
            .accessibilityIdentifier("saveButton").accessibilityHint("Saves the most recent buffer to your local clip library")
    }

    private var captureActions: some View {
        HStack(spacing: 16) {
            Toggle(isOn: $model.audio) { Image(systemName: model.audio ? "mic" : "mic.slash") }
                .toggleStyle(.button).frame(width: 48, height: 48)
                .accessibilityLabel("Record audio").accessibilityIdentifier("audioToggle")
                .disabled(model.phase == .buffering || model.transitioning)
            Button(model.phase == .buffering ? "Stop Buffer" : "Start Buffer") {
                if model.phase == .buffering { model.stop() } else { model.start() }
            }.font(.headline).frame(maxWidth: .infinity, minHeight: 52)
                .background(.white.opacity(0.10), in: Capsule()).disabled(model.transitioning)
                .accessibilityIdentifier("bufferButton")
            Button { model.switchCamera() } label: {
                Image(systemName: "arrow.triangle.2.circlepath.camera").font(.title2).frame(width: 48, height: 48)
            }.disabled(model.phase == .buffering || model.transitioning)
                .accessibilityLabel("Switch camera").accessibilityValue(model.front ? "Front" : "Rear")
        }
    }

    private var dimActions: some View {
        VStack(spacing: 12) {
            Text(dimScreen.battery.text).font(.footnote)
                .accessibilityIdentifier("batteryStatus")
            Button("Dim screen") { dimScreen.dim(while: model.phase) }
                .frame(minHeight: 48).buttonStyle(.bordered)
                .disabled(model.phase != .buffering || model.transitioning)
                .accessibilityIdentifier("dimScreenButton")
                .accessibilityHint("Lowers brightness and shows recording status, Save moment, and Wake screen")
        }
    }

    @ViewBuilder private var permissionHelp: some View {
        if model.phase == .denied {
            Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                .accessibilityIdentifier("settingsButton")
        }
    }

    private var privacyFooter: some View {
        Text("Private by design. Saved only on this iPhone.\nForeground use only. Always supervise your child.")
            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
    }

    @ViewBuilder private var saveFeedback: some View {
        if let status = model.saveStatus, !dimScreen.isDimmed {
            Label(status, systemImage: "checkmark.circle.fill")
                .font(.body.weight(.semibold)).foregroundStyle(.white)
                .padding().frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(white: 0.16))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("saveStatus")
        }
    }

    @ViewBuilder private var dimOverlay: some View {
        if dimScreen.isDimmed {
            DimRecordingView(status: model.status, seconds: model.seconds, battery: dimScreen.battery,
                             canSave: model.canSave, saving: model.saving, saveStatus: model.saveStatus,
                             save: { model.save() }, wake: { dimScreen.wake() })
                .background { Color.black.ignoresSafeArea() }
        }
    }
}
