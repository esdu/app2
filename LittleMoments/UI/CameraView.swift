import SwiftUI

struct CameraView: View {
    @ObservedObject var model: CameraModel
    @State private var showingLibrary = false
    private let accent = Color(red: 0.91, green: 0.80, blue: 0.61)
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
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
                        }.accessibilityLabel("Saved clips").accessibilityIdentifier("libraryButton")
                    }
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
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text("Keep the last").font(.subheadline.weight(.medium)); Spacer(); Text("\(Int(model.duration)) seconds").foregroundStyle(accent) }
                        Picker("Buffer duration", selection: $model.duration) {
                            ForEach([15.0, 30, 60, 120], id: \.self) { duration in Text("\(Int(duration))s").tag(duration) }
                        }.pickerStyle(.segmented).accessibilityIdentifier("durationPicker")
                            .disabled(model.phase == .buffering || model.transitioning)
                    }
                    Button { model.save() } label: {
                        HStack(spacing: 12) {
                            if model.saving { ProgressView().tint(.black) } else { Image(systemName: "arrow.down.to.line") }
                            Text(model.saving ? "SAVING…" : "SAVE MOMENT").tracking(1.5)
                        }.font(.headline).frame(maxWidth: .infinity).frame(minHeight: 70)
                    }.buttonStyle(.plain).background(accent, in: RoundedRectangle(cornerRadius: 24)).foregroundStyle(.black)
                        .opacity(model.phase == .buffering && model.seconds > 0 ? 1 : 0.4)
                        .disabled(model.phase != .buffering || model.seconds <= 0 || model.saving)
                        .accessibilityIdentifier("saveButton").accessibilityHint("Saves the most recent buffer to your local clip library")
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
                    if model.phase == .denied {
                        Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                            .accessibilityIdentifier("settingsButton")
                    }
                    Text("Private by design. Saved only on this iPhone.\nForeground use only. Always supervise your child.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.padding(22)
            }.background(Color(white: 0.045)).toolbar(.hidden, for: .navigationBar)
                .navigationDestination(isPresented: $showingLibrary) { LibraryView(library: model.library) }
                .onChange(of: showingLibrary) { _, shown in if shown { model.stop() } }
                .alert("Little Moments", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                    Button("OK") { model.message = nil }
                } message: { Text(model.message ?? "") }
        }.tint(accent)
    }
}
