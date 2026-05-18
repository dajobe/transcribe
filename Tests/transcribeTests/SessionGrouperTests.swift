import Foundation
import XCTest
@testable import transcribe

final class SessionGrouperTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testEmptyInputProducesEmptyOutput() {
        let sessions = SessionGrouper.groupIntoSessions([], maxGapSeconds: 600)
        XCTAssertTrue(sessions.isEmpty)
    }

    func testSingleClipProducesOneSession() {
        let clip = AudioClip(path: "/x/a.m4a", recordedAt: base, durationSeconds: 30)
        let sessions = SessionGrouper.groupIntoSessions([clip], maxGapSeconds: 600)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.files, ["/x/a.m4a"])
        XCTAssertEqual(sessions.first?.recordedAt, base)
    }

    func testTwoClipsWithSmallGapStayInOneSession() {
        let a = AudioClip(path: "/x/a.m4a", recordedAt: base, durationSeconds: 30)
        let b = AudioClip(path: "/x/b.m4a", recordedAt: base.addingTimeInterval(60), durationSeconds: 30)
        let sessions = SessionGrouper.groupIntoSessions([a, b], maxGapSeconds: 600)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].files, ["/x/a.m4a", "/x/b.m4a"])
    }

    func testTwoClipsWithLargeGapSplitIntoTwoSessions() {
        let a = AudioClip(path: "/x/a.m4a", recordedAt: base, durationSeconds: 30)
        let b = AudioClip(path: "/x/b.m4a", recordedAt: base.addingTimeInterval(3600), durationSeconds: 30)
        let sessions = SessionGrouper.groupIntoSessions([a, b], maxGapSeconds: 600)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].files, ["/x/a.m4a"])
        XCTAssertEqual(sessions[1].files, ["/x/b.m4a"])
    }

    func testGapBetweenMiddleClipsSplitsCleanly() {
        // 5 clips, big gap between clip 2 and clip 3 only.
        let clips = [
            AudioClip(path: "/1.m4a", recordedAt: base, durationSeconds: 60),
            AudioClip(path: "/2.m4a", recordedAt: base.addingTimeInterval(120), durationSeconds: 60),
            AudioClip(path: "/3.m4a", recordedAt: base.addingTimeInterval(7200), durationSeconds: 60),
            AudioClip(path: "/4.m4a", recordedAt: base.addingTimeInterval(7320), durationSeconds: 60),
            AudioClip(path: "/5.m4a", recordedAt: base.addingTimeInterval(7440), durationSeconds: 60),
        ]
        let sessions = SessionGrouper.groupIntoSessions(clips, maxGapSeconds: 600)
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions[0].files, ["/1.m4a", "/2.m4a"])
        XCTAssertEqual(sessions[1].files, ["/3.m4a", "/4.m4a", "/5.m4a"])
    }

    func testMissingRecordedAtKeepsClipInPreviousSession() {
        let a = AudioClip(path: "/a.m4a", recordedAt: base, durationSeconds: 30)
        let b = AudioClip(path: "/b.m4a", recordedAt: nil, durationSeconds: 30)
        let c = AudioClip(path: "/c.m4a", recordedAt: base.addingTimeInterval(7200), durationSeconds: 30)
        // a -> b: missing recordedAt on b, no split.
        // b -> c: missing recordedAt on b, no split (conservative).
        let sessions = SessionGrouper.groupIntoSessions([a, b, c], maxGapSeconds: 600)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].files, ["/a.m4a", "/b.m4a", "/c.m4a"])
    }

    func testMissingDurationKeepsClipInPreviousSession() {
        let a = AudioClip(path: "/a.m4a", recordedAt: base, durationSeconds: nil)
        let b = AudioClip(path: "/b.m4a", recordedAt: base.addingTimeInterval(7200), durationSeconds: 30)
        let sessions = SessionGrouper.groupIntoSessions([a, b], maxGapSeconds: 600)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].files, ["/a.m4a", "/b.m4a"])
    }

    func testZeroGapSplitsEveryRecording() {
        let a = AudioClip(path: "/a.m4a", recordedAt: base, durationSeconds: 30)
        let b = AudioClip(path: "/b.m4a", recordedAt: base.addingTimeInterval(60), durationSeconds: 30)
        let c = AudioClip(path: "/c.m4a", recordedAt: base.addingTimeInterval(120), durationSeconds: 30)
        let sessions = SessionGrouper.groupIntoSessions([a, b, c], maxGapSeconds: 0)
        XCTAssertEqual(sessions.count, 3)
        XCTAssertEqual(sessions[0].files, ["/a.m4a"])
        XCTAssertEqual(sessions[1].files, ["/b.m4a"])
        XCTAssertEqual(sessions[2].files, ["/c.m4a"])
    }

    func testNegativeGapDisablesSplitting() {
        let a = AudioClip(path: "/a.m4a", recordedAt: base, durationSeconds: 30)
        let b = AudioClip(path: "/b.m4a", recordedAt: base.addingTimeInterval(86_400), durationSeconds: 30)
        let sessions = SessionGrouper.groupIntoSessions([a, b], maxGapSeconds: -1)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].files, ["/a.m4a", "/b.m4a"])
    }

    func testFirstRecordedAtIsCarriedThroughEvenIfFirstClipMissing() {
        let a = AudioClip(path: "/a.m4a", recordedAt: nil, durationSeconds: 30)
        let b = AudioClip(path: "/b.m4a", recordedAt: base, durationSeconds: 30)
        let sessions = SessionGrouper.groupIntoSessions([a, b], maxGapSeconds: 600)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].recordedAt, base)
    }
}
