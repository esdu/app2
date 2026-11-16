import AVFoundation
import Foundation
import Combine

struct SavedClip: Identifiable {
    let url: URL
    let created: Date
    let bytes: Int64
    var id: String { url.lastPathComponent }
}
@MainActor final class ClipLibrary: ObservableObject {
    @Published private(set) var clips: [SavedClip] = []
    let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SavedClips", isDirectory: true)
    }
    func load() throws {
        try ProtectedFiles.directory(directory)
        // A crash during export can leave only a staging file, never a completed clip.
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])
        ProtectedFiles.remove(urls.filter { $0.pathExtension == "partial" })
        clips = urls.filter { $0.pathExtension == "mp4" }.map {
            SavedClip(url: $0, created: (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast,
                      bytes: ProtectedFiles.bytes($0))
        }.sorted { $0.created > $1.created }
    }
    func save(_ snapshot: BufferSnapshot) async throws {
        try ProtectedFiles.directory(directory)
        let id = UUID().uuidString
        let staging = directory.appendingPathComponent(id + ".partial")
        let final = directory.appendingPathComponent(id + ".mp4")
        do {
            try await ClipComposer().compose(snapshot, to: staging)
            try FileManager.default.moveItem(at: staging, to: final)
            try load()
        } catch { ProtectedFiles.remove([staging]); throw error }
    }
    func delete(_ clip: SavedClip) throws {
        try FileManager.default.removeItem(at: clip.url)
        clips.removeAll { $0.id == clip.id }
    }
}
