import Foundation

struct VideoSegment: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let start: Double
    let end: Double
    let bytes: Int64
    var duration: Double { max(0, end - start) }
}

/// Confined to the capture queue. Leases prevent eviction while an export reads files.
struct SegmentIndex {
    private(set) var segments: [VideoSegment] = []
    private var leases: [UUID: Set<UUID>] = [:]
    private var retired: Set<UUID> = []
    var window: Double = 30
    let byteLimit: Int64
    init(byteLimit: Int64 = 160 * 1_024 * 1_024) { self.byteLimit = byteLimit }
    var bytes: Int64 { segments.reduce(0) { $0 + $1.bytes } }
    var duration: Double {
        let current = segments.filter { !retired.contains($0.id) }
        guard let first = current.first, let last = current.last else { return 0 }
        return min(window, max(0, last.end - first.start))
    }
    mutating func insert(_ segment: VideoSegment) {
        guard segment.start.isFinite, segment.end.isFinite, segment.end > segment.start,
              segment.bytes >= 0, !segments.contains(where: { $0.id == segment.id }) else { return }
        segments.append(segment)
        segments.sort { $0.start < $1.start }
    }
    mutating func pin(endingAt end: Double) -> (UUID, [VideoSegment]) {
        let selection = segments.filter { !retired.contains($0.id) && $0.end > end - window && $0.start < end }
        let token = UUID()
        leases[token] = Set(selection.map(\.id))
        return (token, selection)
    }
    mutating func release(_ token: UUID) { leases.removeValue(forKey: token) }
    mutating func prune(now: Double) -> [VideoSegment] {
        let pinned = leases.values.reduce(into: Set<UUID>()) { $0.formUnion($1) }
        var removed: [VideoSegment] = []
        // Keep a boundary segment for exact trimming at export time.
        for segment in segments where (retired.contains(segment.id) || segment.end <= now - window) && !pinned.contains(segment.id) {
            removed.append(segment)
        }
        segments.removeAll { s in removed.contains { $0.id == s.id } }
        while bytes > byteLimit, let oldest = segments.first(where: { !pinned.contains($0.id) }) {
            removed.append(oldest)
            segments.removeAll { $0.id == oldest.id }
        }
        retired.subtract(removed.map(\.id))
        return removed
    }
    mutating func clearUnpinned() -> [VideoSegment] {
        let pinned = leases.values.reduce(into: Set<UUID>()) { $0.formUnion($1) }
        let removed = segments.filter { !pinned.contains($0.id) }
        segments.removeAll { !pinned.contains($0.id) }
        // Leased files survive stop, but cannot enter a subsequent capture session.
        retired = Set(segments.map(\.id))
        return removed
    }
}

struct Timeline {
    private(set) var lastVideo: Double?
    private(set) var lastAudio: Double?
    mutating func accept(_ seconds: Double, audio: Bool) -> Bool {
        guard seconds.isFinite, seconds >= 0 else { return false }
        let previous = audio ? lastAudio : lastVideo
        guard previous == nil || seconds > previous! else { return false }
        if audio { lastAudio = seconds } else { lastVideo = seconds }
        return true
    }
}

enum CapturePhase: String { case stopped, starting, buffering, paused, denied, failed }
