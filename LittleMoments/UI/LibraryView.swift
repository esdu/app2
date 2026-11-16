import AVKit
import SwiftUI

struct LibraryView: View {
    @ObservedObject var library: ClipLibrary
    @State private var selected: SavedClip?
    @State private var pendingDelete: SavedClip?
    @State private var message: String?
    @State private var exporting: Set<String> = []
    var body: some View {
        List {
            Section {
                if library.clips.isEmpty {
                    ContentUnavailableView("Your moments live here", systemImage: "photo.on.rectangle.angled",
                                           description: Text("Start a buffer and save your first moment."))
                }
                ForEach(library.clips) { clip in
                    VStack(alignment: .leading, spacing: 14) {
                        Button { selected = clip } label: {
                            HStack(spacing: 16) {
                                Image(systemName: "play.circle.fill").font(.largeTitle)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(clip.created, format: .dateTime.month().day().hour().minute()).font(.headline)
                                    Text(ByteCountFormatter.string(fromByteCount: clip.bytes, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                        }.buttonStyle(.plain).accessibilityLabel("Play saved moment").accessibilityIdentifier("clipRow")
                        HStack(spacing: 24) {
                            ShareLink(item: clip.url) { Label("Share", systemImage: "square.and.arrow.up") }
                            Button {
                                exporting.insert(clip.id)
                                Task {
                                    do { try await Permissions.exportToPhotos(clip.url); message = "Exported to Photos." }
                                    catch { message = error.localizedDescription }
                                    exporting.remove(clip.id)
                                }
                            } label: { Label("Photos", systemImage: "photo") }.disabled(exporting.contains(clip.id))
                            Spacer()
                            Button(role: .destructive) { pendingDelete = clip } label: { Image(systemName: "trash").frame(width: 44, height: 44) }
                                .disabled(exporting.contains(clip.id)).accessibilityLabel("Delete clip").accessibilityIdentifier("deleteClip")
                        }.font(.subheadline).buttonStyle(.borderless)
                    }.padding(.vertical, 8)
                }
            } header: { Text("\(library.clips.count) saved clips · kept until you delete them").accessibilityIdentifier("clipCount") }
        }.navigationTitle("Saved moments").accessibilityIdentifier("libraryScreen")
            .sheet(item: $selected) { clip in ClipPlayer(url: clip.url) }
            .confirmationDialog("Delete this saved moment?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
                Button("Delete Moment", role: .destructive) {
                    if let clip = pendingDelete { do { try library.delete(clip) } catch { message = error.localizedDescription } }
                    pendingDelete = nil
                }
            }
            .alert("Little Moments", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK") { message = nil }
            } message: { Text(message ?? "") }
    }
}
private struct ClipPlayer: View {
    @State private var player: AVPlayer
    @Environment(\.dismiss) private var dismiss
    init(url: URL) { _player = State(initialValue: AVPlayer(url: url)) }
    var body: some View {
        NavigationStack {
            VideoPlayer(player: player).onAppear { player.play() }.onDisappear { player.pause() }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
