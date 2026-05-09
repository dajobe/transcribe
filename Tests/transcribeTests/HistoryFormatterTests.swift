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

    func testLabelPrefersTitleThenBasenameThenSourceID() {
        let recordWithTitle = makeRecord(recording_title: "Daily Standup", basename: "2026-05-09-standup")
        XCTAssertEqual(HistoryFormatter.displayLabel(recordWithTitle), "Daily Standup")

        let recordWithBasename = makeRecord(recording_title: nil, basename: "meeting-q2")
        XCTAssertEqual(HistoryFormatter.displayLabel(recordWithBasename), "meeting-q2")

        let recordWithEmptyTitle = makeRecord(recording_title: "", basename: "fallback-basename")
        XCTAssertEqual(HistoryFormatter.displayLabel(recordWithEmptyTitle), "fallback-basename")

        let recordOnlySourceID = makeRecord(recording_title: nil, basename: nil)
        XCTAssertEqual(HistoryFormatter.displayLabel(recordOnlySourceID), "file:/tmp/x.m4a")
    }

    func testLineFormatPadsColumns() {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let record = makeRecord(
            completed_at: isoString(now.addingTimeInterval(-300)),
            recording_title: "Daily Standup"
        )
        let line = HistoryFormatter.line(for: record, now: now)
        // "5 mins ago" padded to 18, then "transcribed voice" padded to 18.
        XCTAssertTrue(line.hasPrefix("5 mins ago        "), "line: \(line)")
        XCTAssertTrue(line.contains("transcribed voice "), "line: \(line)")
        XCTAssertTrue(line.hasSuffix("Daily Standup"), "line: \(line)")
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
        basename: String? = nil
    ) -> ProcessingRecord {
        ProcessingRecord(
            completed_at: completed_at,
            source_kind: kind,
            source_id: "file:/tmp/x.m4a",
            source_fingerprint: SourceFingerprint(files: []),
            settings_signature: nil,
            output_dir: nil,
            basename: basename,
            output_paths: [],
            audio_duration_s: nil,
            warning_count: 0,
            recording_title: recording_title,
            recorded_at: nil,
            voice_memos_unique_id: nil,
            voice_memos_path: nil
        )
    }
}
