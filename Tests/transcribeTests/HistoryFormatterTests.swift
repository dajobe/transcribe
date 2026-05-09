import Foundation
import XCTest
@testable import transcribe

final class HistoryFormatterTests: XCTestCase {
    func testRelativeTimePhrases() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        XCTAssertEqual(format(secondsAgo: 0, now: now), "just now")
        XCTAssertEqual(format(secondsAgo: 4, now: now), "just now")
        XCTAssertEqual(format(secondsAgo: 5, now: now), "5 secs ago")
        XCTAssertEqual(format(secondsAgo: 1, now: now), "just now")
        XCTAssertEqual(format(secondsAgo: 59, now: now), "59 secs ago")
        XCTAssertEqual(format(secondsAgo: 60, now: now), "1 min ago")
        XCTAssertEqual(format(secondsAgo: 5 * 60, now: now), "5 mins ago")
        XCTAssertEqual(format(secondsAgo: 59 * 60, now: now), "59 mins ago")
        XCTAssertEqual(format(secondsAgo: 60 * 60, now: now), "1 hour ago")
        XCTAssertEqual(format(secondsAgo: 3 * 3600, now: now), "3 hours ago")
        XCTAssertEqual(format(secondsAgo: 24 * 3600, now: now), "1 day ago")
        XCTAssertEqual(format(secondsAgo: 3 * 86400, now: now), "3 days ago")
        XCTAssertEqual(format(secondsAgo: 6 * 86400, now: now), "6 days ago")
    }

    func testOlderThanSevenDaysFallsBackToISO() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let stored = isoString(now.addingTimeInterval(-7 * 86400 - 1))
        XCTAssertEqual(HistoryFormatter.formatTimestamp(stored, now: now), stored)
    }

    func testFutureTimestampShowsRawISO() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let stored = isoString(now.addingTimeInterval(60))
        XCTAssertEqual(HistoryFormatter.formatTimestamp(stored, now: now), stored)
    }

    func testUnparseableTimestampPassesThrough() {
        let now = Date()
        XCTAssertEqual(HistoryFormatter.formatTimestamp("not-a-date", now: now), "not-a-date")
    }

    func testKindDisplayCoversEveryCase() {
        XCTAssertEqual(HistoryFormatter.displayKind(.file), "transcribed file")
        XCTAssertEqual(HistoryFormatter.displayKind(.directorySession), "transcribed dir")
        XCTAssertEqual(HistoryFormatter.displayKind(.voiceMemos), "transcribed voice")
        XCTAssertEqual(HistoryFormatter.displayKind(.importedBaseline), "imported")
        XCTAssertEqual(HistoryFormatter.displayKind(.voiceMemosBaseline), "imported voice")
    }

    func testLabelPrefersFilenameFromFingerprint() {
        let single = makeRecord(files: [fingerprintFile("/tmp/recordings/Memo5.m4a")])
        XCTAssertEqual(HistoryFormatter.displayLabel(single), "Memo5.m4a")

        let multiWithBasename = makeRecord(
            basename: "2026-05-07 standup-week",
            files: [
                fingerprintFile("/tmp/clips/a.m4a"),
                fingerprintFile("/tmp/clips/b.m4a"),
                fingerprintFile("/tmp/clips/c.m4a"),
            ]
        )
        XCTAssertEqual(HistoryFormatter.displayLabel(multiWithBasename), "2026-05-07 standup-week (3 clips)")

        let multiNoBasename = makeRecord(
            basename: nil,
            files: [
                fingerprintFile("/tmp/x/first.m4a"),
                fingerprintFile("/tmp/x/second.m4a"),
            ]
        )
        XCTAssertEqual(HistoryFormatter.displayLabel(multiNoBasename), "first.m4a (+1 more)")

        let noFingerprintFallsBack = makeRecord(
            recording_title: "Title Wins",
            basename: "should-not-show",
            files: []
        )
        XCTAssertEqual(HistoryFormatter.displayLabel(noFingerprintFallsBack), "Title Wins")

        let noFingerprintNoTitle = makeRecord(
            recording_title: nil,
            basename: "basename-fallback",
            files: []
        )
        XCTAssertEqual(HistoryFormatter.displayLabel(noFingerprintNoTitle), "basename-fallback")

        let onlySourceID = makeRecord(recording_title: nil, basename: nil, files: [])
        XCTAssertEqual(HistoryFormatter.displayLabel(onlySourceID), "file:/tmp/x.m4a")
    }

    func testRecordedAtShowsDateOrEmDash() {
        let withDate = makeRecord(recorded_at: "2014-05-13T00:30:35Z")
        XCTAssertEqual(HistoryFormatter.displayRecordedAt(withDate), "2014-05-13")

        let withoutDate = makeRecord(recorded_at: nil)
        XCTAssertEqual(HistoryFormatter.displayRecordedAt(withoutDate), "—")

        let malformed = makeRecord(recorded_at: "garbage")
        XCTAssertEqual(HistoryFormatter.displayRecordedAt(malformed), "—")
    }

    func testLineFormatPadsAllColumns() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let record = makeRecord(
            completed_at: isoString(now.addingTimeInterval(-300)),
            recorded_at: "2014-05-13T00:30:35Z",
            files: [fingerprintFile("/tmp/Memo5.m4a")]
        )
        let line = HistoryFormatter.line(for: record, now: now)
        XCTAssertTrue(line.hasPrefix("5 mins ago        "), "line: \(line)")
        XCTAssertTrue(line.contains("transcribed voice "), "line: \(line)")
        XCTAssertTrue(line.contains("2014-05-13  "), "line: \(line)")
        XCTAssertTrue(line.hasSuffix("Memo5.m4a"), "line: \(line)")
    }

    // MARK: - helpers

    private func format(secondsAgo: Int, now: Date) -> String {
        let then = now.addingTimeInterval(-Double(secondsAgo))
        return HistoryFormatter.formatTimestamp(isoString(then), now: now)
    }

    private func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private func makeRecord(
        completed_at: String = "2026-05-09T18:00:00Z",
        kind: ProcessingSourceKind = .voiceMemos,
        recording_title: String? = nil,
        basename: String? = nil,
        recorded_at: String? = nil,
        files: [FileFingerprint] = []
    ) -> ProcessingRecord {
        ProcessingRecord(
            completed_at: completed_at,
            source_kind: kind,
            source_id: "file:/tmp/x.m4a",
            source_fingerprint: SourceFingerprint(files: files),
            settings_signature: nil,
            output_dir: nil,
            basename: basename,
            output_paths: [],
            audio_duration_s: nil,
            warning_count: 0,
            recording_title: recording_title,
            recorded_at: recorded_at,
            voice_memos_unique_id: nil,
            voice_memos_path: nil
        )
    }

    private func fingerprintFile(_ path: String) -> FileFingerprint {
        FileFingerprint(path: path, sha256: "0", bytes: 0, mtime: nil)
    }
}
