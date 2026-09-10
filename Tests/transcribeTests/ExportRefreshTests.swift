import Foundation
import XCTest
@testable import transcribe

final class ExportRefreshTests: XCTestCase {
    private var directory: URL!
    private var previousState: String?
    private var previousConfig: String?
    private var previousRefreshEnv: String?

    override func setUpWithError() throws {
        previousState = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        previousConfig = ProcessInfo.processInfo.environment["TRANSCRIBE_CONFIG"]
        previousRefreshEnv = ProcessInfo.processInfo.environment["TRANSCRIBE_REFRESH_EXPORTS"]
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("export-refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("XDG_STATE_HOME", directory.path, 1)
        setenv("TRANSCRIBE_CONFIG", directory.appendingPathComponent("missing-config.json").path, 1)
        unsetenv("TRANSCRIBE_REFRESH_EXPORTS")
    }

    override func tearDownWithError() throws {
        for (name, value) in [
            ("XDG_STATE_HOME", previousState),
            ("TRANSCRIBE_CONFIG", previousConfig),
            ("TRANSCRIBE_REFRESH_EXPORTS", previousRefreshEnv),
        ] {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    private func confirmedMatch(_ name: String) -> SpeakerMatch {
        SpeakerMatch(profileID: "p1", name: name, distance: 0.1, margin: nil, confirmedExampleCount: 1, status: .confirmed)
    }

    private func document(
        _ name: String, hash: String, matches: [String: SpeakerMatch] = [:]
    ) throws -> (document: CanonicalTranscript, url: URL) {
        let hashes = [String(repeating: hash, count: 64)]
        let result = CanonicalTranscript(
            evidenceID: CanonicalTranscript.evidenceID(forSourceHashes: hashes), sourceHashes: hashes,
            model: "intentionally-unavailable-model", transcribeVersion: Transcribe.version,
            audioPath: "/does/not/exist.wav", basename: name,
            output: TranscriptionOutput(
                segments: [TranscriptSegment(speaker: "SPEAKER_0", start: 1, end: 3, text: "Hello world.", words: nil)],
                language: "en", durationSeconds: 4, diarizationEnabled: true, speakersDetected: 1,
                speakerEmbeddings: ["SPEAKER_0": [1, 0]]
            ),
            speakerMatches: matches
        )
        let url = directory.appendingPathComponent(name + ".transcript.json")
        _ = try CanonicalTranscriptStore.save(result, to: url)
        return (try CanonicalTranscriptStore.load(from: url), url)
    }

    /// Renders `format` for the document's plain local-label output (the
    /// content an export before any confirmation would hold).
    private func localLabelData(_ document: CanonicalTranscript, format: String) throws -> Data {
        try XCTUnwrap(renderOutputData(
            format: format, output: document.output, audioPath: document.audioPath,
            model: document.model, version: document.transcribeVersion,
            createdAt: document.createdAt
        ))
    }

    /// Writes `data` as a recorded export beside the test directory and
    /// returns the matching record.
    private func seededExport(_ data: Data, at path: String, format: String) throws -> ExportRecord {
        try data.write(to: URL(fileURLWithPath: path))
        return ExportRecord(path: path, format: format, sha256: sha256Hex(data), exportedAt: Date())
    }

    // MARK: - Decision table

    func testStaleExportIsRewrittenWithConfirmedNames() throws {
        var (document, url) = try document("meeting", hash: "a", matches: ["SPEAKER_0": confirmedMatch("Dave")])
        let path = directory.appendingPathComponent("meeting.txt").path
        var plain = document
        plain.speakerMatches = [:]
        let stale = try localLabelData(plain, format: "txt")
        document.exports = [try seededExport(stale, at: path, format: "txt")]

        let summary = ExportRefresh.refresh(document: &document, documentURL: url)

        let refreshed = try String(contentsOfFile: path)
        XCTAssertTrue(refreshed.contains("Dave"), refreshed)
        XCTAssertFalse(refreshed.contains("SPEAKER_0"), refreshed)
        XCTAssertEqual(summary.refreshedFormats, ["txt"])
        XCTAssertTrue(summary.recordsChanged)
        let record = try XCTUnwrap(document.exports?.first)
        XCTAssertEqual(record.sha256, sha256Hex(try Data(contentsOf: URL(fileURLWithPath: path))))
    }

    func testLocallyModifiedExportIsSkippedAndKept() throws {
        var (document, url) = try document("meeting", hash: "a", matches: ["SPEAKER_0": confirmedMatch("Dave")])
        let path = directory.appendingPathComponent("meeting.txt").path
        let stale = try localLabelData(document, format: "txt")
        var record = try seededExport(stale, at: path, format: "txt")
        let edited = Data("hand-edited transcript\n".utf8)
        try edited.write(to: URL(fileURLWithPath: path))
        record.sha256 = sha256Hex(stale)
        document.exports = [record]

        let summary = ExportRefresh.refresh(document: &document, documentURL: url)

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), edited, "edited file must stay untouched")
        XCTAssertEqual(summary.modifiedPaths, [path])
        XCTAssertTrue(summary.refreshedFormats.isEmpty)
        XCTAssertEqual(document.exports?.count, 1, "record survives so a restored file refreshes later")
        XCTAssertFalse(summary.recordsChanged)
    }

    func testMissingExportFileDropsItsRecord() throws {
        var (document, url) = try document("meeting", hash: "a", matches: ["SPEAKER_0": confirmedMatch("Dave")])
        let path = directory.appendingPathComponent("deleted.txt").path
        document.exports = [ExportRecord(path: path, format: "txt", sha256: String(repeating: "0", count: 64), exportedAt: Date())]

        let summary = ExportRefresh.refresh(document: &document, documentURL: url)

        XCTAssertEqual(summary.droppedPaths, [path])
        XCTAssertEqual(document.exports, [])
        XCTAssertTrue(summary.recordsChanged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "refresh must not resurrect a deleted file")
    }

    func testSymlinkAtRecordedPathIsNeverReplaced() throws {
        var (document, url) = try document("meeting", hash: "a", matches: ["SPEAKER_0": confirmedMatch("Dave")])
        var plain = document
        plain.speakerMatches = [:]
        let stale = try localLabelData(plain, format: "txt")
        let targetPath = directory.appendingPathComponent("target.txt").path
        try stale.write(to: URL(fileURLWithPath: targetPath))
        let linkPath = directory.appendingPathComponent("meeting.txt").path
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: targetPath)
        document.exports = [ExportRecord(path: linkPath, format: "txt", sha256: sha256Hex(stale), exportedAt: Date())]

        let summary = ExportRefresh.refresh(document: &document, documentURL: url)

        XCTAssertTrue(summary.refreshedFormats.isEmpty)
        XCTAssertEqual(document.exports?.count, 1, "record is kept, only the write is refused")
        let attributes = try FileManager.default.attributesOfItem(atPath: linkPath)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink, "the symlink must survive")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: targetPath)), stale, "the target must stay untouched")
    }

    func testUpToDateExportIsLeftAloneQuietly() throws {
        var (document, url) = try document("meeting", hash: "a", matches: ["SPEAKER_0": confirmedMatch("Dave")])
        let path = directory.appendingPathComponent("meeting.srt").path
        let current = try XCTUnwrap(renderOutputData(
            format: "srt", output: document.renderedOutput(), audioPath: document.audioPath,
            model: document.model, version: document.transcribeVersion, createdAt: document.createdAt
        ))
        document.exports = [try seededExport(current, at: path, format: "srt")]
        let before = document.exports

        let summary = ExportRefresh.refresh(document: &document, documentURL: url)

        XCTAssertTrue(summary.isQuiet)
        XCTAssertFalse(summary.recordsChanged)
        XCTAssertEqual(document.exports, before)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), current)
        XCTAssertNil(ExportRefresh.summaryLine(summary, basename: "meeting", color: .disabled))
    }

    // MARK: - Preference resolution

    func testEnabledPrecedenceAcrossFlagEnvironmentAndConfig() throws {
        XCTAssertTrue(ExportRefresh.enabled(flag: nil), "default is on")
        XCTAssertFalse(ExportRefresh.enabled(flag: false))

        setenv("TRANSCRIBE_REFRESH_EXPORTS", "0", 1)
        XCTAssertFalse(ExportRefresh.enabled(flag: nil), "env 0 disables")
        XCTAssertTrue(ExportRefresh.enabled(flag: true), "explicit flag beats env")
        unsetenv("TRANSCRIBE_REFRESH_EXPORTS")

        let configURL = directory.appendingPathComponent("config.json")
        var config = UserConfigFile()
        config.speakers = UserConfigFile.SpeakersSection(
            enabled: nil, merge: nil, min: nil, max: nil, refreshExports: false
        )
        try UserConfigFile.save(config, to: configURL)
        setenv("TRANSCRIBE_CONFIG", configURL.path, 1)
        XCTAssertFalse(ExportRefresh.enabled(flag: nil), "config false disables")
        XCTAssertTrue(ExportRefresh.enabled(flag: true), "flag beats config")

        setenv("TRANSCRIBE_REFRESH_EXPORTS", "0", 1)
        config.speakers?.refreshExports = true
        try UserConfigFile.save(config, to: configURL)
        XCTAssertFalse(ExportRefresh.enabled(flag: nil), "env beats config true")
    }

    // MARK: - Legacy hint

    func testStaleExportHintRebuildsTheExportCommandFromHistory() throws {
        let (document, url) = try document("meeting", hash: "a")
        let fingerprint = SourceFingerprint(files: [
            FileFingerprint(path: "/audio/meeting.m4a", sha256: String(repeating: "a", count: 64), bytes: 5, mtime: nil),
        ])
        try ProcessingStore.append(ProcessingRecord(
            completed_at: iso8601String(Date()),
            history_reason: .firstRun,
            source_kind: .file,
            source_id: sourceIDForFiles(kind: .file, files: ["/audio/meeting.m4a"]),
            source_fingerprint: fingerprint,
            settings_signature: nil,
            output_dir: "/notes",
            basename: "meeting",
            output_paths: ["/notes/meeting.md", "/notes/meeting.srt"],
            audio_duration_s: 4,
            warning_count: 0,
            recording_title: nil,
            recorded_at: nil,
            voice_memos_unique_id: nil,
            voice_memos_path: nil
        ))

        let hint = try XCTUnwrap(ExportRefresh.staleExportHint(for: document, at: url))
        XCTAssertTrue(hint.contains("transcribe export \(url.path)"), hint)
        XCTAssertTrue(hint.contains("--format md,srt"), hint)
        XCTAssertTrue(hint.contains("-o /notes"), hint)
        XCTAssertTrue(hint.contains("--overwrite"), hint)
    }

    func testStaleExportHintFallsBackWithoutMatchingHistory() throws {
        let (document, url) = try document("meeting", hash: "b")
        XCTAssertEqual(
            ExportRefresh.staleExportHint(for: document, at: url),
            "Export again to update rendered files."
        )
    }
}
