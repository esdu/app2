import XCTest
@testable import LittleMoments

final class SegmentIndexTests: XCTestCase {
    private func segment(_ start: Double, _ end: Double, bytes: Int64 = 10) -> VideoSegment {
        VideoSegment(id: UUID(), url: URL(fileURLWithPath: "/tmp/\(UUID()).mov"), start: start, end: end, bytes: bytes)
    }
    func testWatchdogTimesOutWithoutVideoAndResetsOnFrames() {
        var watchdog = CaptureWatchdog(startedAt: 100)
        XCTAssertFalse(watchdog.timedOut(at: 104.9))
        XCTAssertTrue(watchdog.timedOut(at: 105))
        watchdog.sawVideo(at: 104)
        XCTAssertFalse(watchdog.timedOut(at: 108.9))
        XCTAssertTrue(watchdog.timedOut(at: 109))
    }
    func testDefaultWindow() { XCTAssertEqual(SegmentIndex().window, 30) }
    func testDurationChoicesAndBoundarySegment() {
        for window in [15.0, 30, 60, 120] {
            var index = SegmentIndex(); index.window = window
            for start in stride(from: 0.0, to: 150, by: 2) { index.insert(segment(start, start + 2)); _ = index.prune(now: start + 2) }
            XCTAssertEqual(index.duration, window)
            XCTAssertLessThanOrEqual(index.segments.count, Int(ceil(window / 2)))
            XCTAssertTrue(index.segments.allSatisfy { $0.end > 150 - window })
        }
    }
    func testExpiredSegmentsRemovedAtExactBoundary() {
        var index = SegmentIndex(); index.window = 4
        index.insert(segment(0, 2)); index.insert(segment(2, 4)); index.insert(segment(4, 6))
        let removed = index.prune(now: 6)
        XCTAssertEqual(removed.map(\.start), [0]); XCTAssertEqual(index.segments.map(\.start), [2, 4])
    }
    func testStorageLimitEvictsOldest() {
        var index = SegmentIndex(byteLimit: 15)
        index.insert(segment(0, 2)); index.insert(segment(2, 4))
        XCTAssertEqual(index.prune(now: 4).count, 1); XCTAssertLessThanOrEqual(index.bytes, 15)
    }
    func testSegmentsSortedDespiteCompletionOrder() {
        var index = SegmentIndex()
        index.insert(segment(4, 6)); index.insert(segment(0, 2)); index.insert(segment(2, 4))
        XCTAssertEqual(index.segments.map(\.start), [0, 2, 4])
    }
    func testSaveLeaseSurvivesExpirationAndReleases() {
        var index = SegmentIndex(); index.window = 4
        let saved = segment(0, 2); index.insert(saved)
        let (token, selected) = index.pin(endingAt: 2)
        XCTAssertEqual(selected, [saved]); XCTAssertTrue(index.prune(now: 100).isEmpty)
        index.release(token); XCTAssertEqual(index.prune(now: 100), [saved])
    }
    func testOverlappingLeases() {
        var index = SegmentIndex(); let saved = segment(0, 2); index.insert(saved)
        let (a, _) = index.pin(endingAt: 2); let (b, _) = index.pin(endingAt: 2)
        index.release(a); XCTAssertTrue(index.clearUnpinned().isEmpty)
        index.release(b); XCTAssertEqual(index.clearUnpinned(), [saved])
    }
    func testStopDoesNotRemovePinnedFiles() {
        var index = SegmentIndex(); index.insert(segment(0, 2))
        let (token, _) = index.pin(endingAt: 2); index.insert(segment(2, 4))
        XCTAssertEqual(index.clearUnpinned().count, 1)
        index.release(token); XCTAssertEqual(index.clearUnpinned().count, 1)
    }
    func testRestartDoesNotIncludePreviouslyPinnedSession() {
        var index = SegmentIndex(); index.insert(segment(0, 2))
        let (previousSave, _) = index.pin(endingAt: 2)
        _ = index.clearUnpinned()
        XCTAssertEqual(index.duration, 0)
        index.insert(segment(3, 5))
        XCTAssertEqual(index.pin(endingAt: 5).1.map(\.start), [3])
        index.release(previousSave)
        XCTAssertEqual(index.prune(now: 5).map(\.start), [0])
    }
    func testPinSelectsOnlyWindowAtTrigger() {
        var index = SegmentIndex(); index.window = 3
        for start in [0.0, 2, 4, 6] { index.insert(segment(start, start + 2)) }
        XCTAssertEqual(index.pin(endingAt: 6).1.map(\.start), [2, 4])
    }
    func testInvalidAndDuplicateSegmentsRejected() {
        var index = SegmentIndex(); let valid = segment(0, 2)
        index.insert(valid); index.insert(valid); index.insert(segment(2, 1)); index.insert(segment(.nan, 2))
        index.insert(segment(0, 2, bytes: -1)); XCTAssertEqual(index.segments, [valid])
    }
    func testPinnedStorageIsAccountedFor() {
        var index = SegmentIndex(byteLimit: 15); index.insert(segment(0, 2))
        let (token, _) = index.pin(endingAt: 2); index.insert(segment(2, 4))
        _ = index.prune(now: 100); XCTAssertEqual(index.bytes, 10)
        index.release(token); _ = index.prune(now: 100); XCTAssertEqual(index.bytes, 0)
    }
    func testIndependentMonotonicAudioVideoClocks() {
        var timeline = Timeline()
        XCTAssertTrue(timeline.accept(100, audio: false)); XCTAssertTrue(timeline.accept(100.01, audio: true))
        XCTAssertTrue(timeline.accept(100.02, audio: false)); XCTAssertFalse(timeline.accept(100, audio: false))
        XCTAssertFalse(timeline.accept(.infinity, audio: true)); XCTAssertFalse(timeline.accept(-1, audio: true))
    }
}
