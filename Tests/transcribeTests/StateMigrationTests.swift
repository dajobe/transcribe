import Foundation
import SQLite3
import XCTest
@testable import transcribe

/// Phase 4 of specs/sqlite-state-store.md: 2.x JSON state on disk migrates
/// into the state database on first open, the originals move under
/// `migrated-v1/`, and every step is recorded in `migration_sources`.
/// Fixtures are written in the real 2.x formats: portable-writer documents,
/// a `speaker_profiles.json` in the old store layout, and JSONL ledgers.
final class StateMigrationTests: XCTestCase {
    private var root: URL!
    private var state: URL!
    private var previousState: String?

    override func setUpWithError() throws {
        previousState = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        root = FileManager.default.temporaryDirectory.appendingPathComponent("state-migration-\(UUID().uuidString)")
        state = root.appendingPathComponent("transcribe", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        setenv("XDG_STATE_HOME", root.path, 1)
    }

    override func tearDownWithError() throws {
        // Drop the shared connection before its directory disappears.
        StateStore.closeShared()
        if let previousState { setenv("XDG_STATE_HOME", previousState, 1) } else { unsetenv("XDG_STATE_HOME") }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private let idA = UUID(uuidString: "aaaaaaaa-0000-4000-8000-000000000001")!
    private let idB = UUID(uuidString: "bbbbbbbb-0000-4000-8000-000000000002")!
    private let idC = UUID(uuidString: "cccccccc-0000-4000-8000-000000000003")!

    private var transcriptsDirectory: URL { state.appendingPathComponent("transcripts", isDirectory: true) }
    private var archive: URL { state.appendingPathComponent("migrated-v1", isDirectory: true) }
    private var profilesURL: URL { state.appendingPathComponent("speaker_profiles.json") }
    private var processingURL: URL { state.appendingPathComponent("processing_history.jsonl") }
    private var timingURL: URL { state.appendingPathComponent("timing_history.jsonl") }
    private var databaseURL: URL { state.appendingPathComponent("state.db") }

    private func document(
        id: UUID, hash: Character, basename: String = "meeting", rich: Bool = false
    ) -> CanonicalTranscript {
        let sourceHashes = [String(repeating: String(hash), count: 64)]
        var output = TranscriptionOutput(
            segments: [
                TranscriptSegment(speaker: "SPEAKER_0", start: 0, end: 1.5, text: "Hello",
                                  words: [WordSegment(word: "Hello", start: 0, end: 1.5)]),
                TranscriptSegment(speaker: "SPEAKER_1", start: 2, end: 3, text: "There", words: nil),
            ],
            language: "en",
            durationSeconds: 3,
            diarizationEnabled: true,
            speakersDetected: 2,
            speakerEmbeddings: ["SPEAKER_0": [0.25, 0.75], "SPEAKER_1": [0.5, 0.5]]
        )
        if rich {
            output.speakerStrategy = "segment"
            output.warnings = ["a warning"]
        }
        return CanonicalTranscript(
            id: id,
            evidenceID: CanonicalTranscript.evidenceID(forSourceHashes: sourceHashes),
            sourceHashes: sourceHashes,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            model: "whisper-test",
            transcribeVersion: "2.7.0",
            audioPath: "/audio/\(basename).m4a",
            basename: basename,
            output: output,
            speakerMatches: rich ? [
                "SPEAKER_0": SpeakerMatch(profileID: "p-ada", name: "Ada", distance: 0, margin: nil,
                                          confirmedExampleCount: 1, status: .confirmed),
            ] : [:],
            dismissedSpeakers: rich ? ["SPEAKER_1"] : nil,
            exports: rich ? [
                ExportRecord(path: "/notes/\(basename).txt", format: "txt",
                             sha256: String(repeating: "1", count: 64),
                             exportedAt: Date(timeIntervalSince1970: 1_700_000_100)),
            ] : nil
        )
    }

    /// Writes a document the way 2.x did: the portable JSON writer, named
    /// `<name>.transcript.json` in the managed directory, with a lock
    /// sidecar beside it, and a fixed mtime.
    @discardableResult
    private func writeTranscript(
        _ document: CanonicalTranscript, name: String? = nil, mtime: TimeInterval = 1_750_000_000,
        lockSidecar: Bool = true
    ) throws -> URL {
        let file = transcriptsDirectory.appendingPathComponent(
            "\(name ?? document.id.uuidString.lowercased()).transcript.json"
        )
        _ = try CanonicalTranscriptStore.save(document, to: file)
        if lockSidecar { try Data().write(to: URL(fileURLWithPath: file.path + ".lock")) }
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: mtime)], ofItemAtPath: file.path
        )
        return file
    }

    private struct LegacyProfileFile: Encodable {
        let schemaVersion = 1
        let profiles: [SpeakerProfile]
        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case profiles
        }
    }

    private func legacyProfiles(name: String = "Ada") -> [SpeakerProfile] {
        let evidence = CanonicalTranscript.evidenceID(forSourceHashes: [String(repeating: "a", count: 64)])
        return [
            SpeakerProfile(id: "p-ada", name: name, examples: [
                SpeakerProfileExample(transcriptID: evidence, speakerID: "SPEAKER_0",
                                      modelID: CanonicalTranscript.speakerEmbeddingModelID,
                                      embedding: [0.25, 0.75], sourceHashes: [String(repeating: "a", count: 64)]),
            ]),
            SpeakerProfile(id: "p-bob", name: "Bob", examples: []),
        ]
    }

    private func writeProfiles(_ profiles: [SpeakerProfile]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(LegacyProfileFile(profiles: profiles)).write(to: profilesURL)
        try Data().write(to: URL(fileURLWithPath: profilesURL.path + ".lock"))
    }

    private func processingLine(_ name: String, extra: String = "") -> String {
        let fingerprint = "{\"files\":[{\"path\":\"/rec/\(name)\",\"sha256\":\"0\",\"bytes\":0,\"mtime\":null}]}"
        return "{\(extra)\"basename\":\"\(name)\",\"completed_at\":\"2026-06-01T10:00:00Z\",\"output_paths\":[],\"recorded_at\":null,\"recording_title\":null,\"schema_version\":1,\"source_fingerprint\":\(fingerprint),\"source_id\":\"file:/rec/\(name)\",\"source_kind\":\"file\",\"voice_memos_path\":null,\"voice_memos_unique_id\":null,\"warning_count\":0}"
    }

    private func timingLine(_ name: String) -> String {
        "{\"schema_version\":1,\"ended_at\":\"2026-05-28T12:00:00.000Z\",\"transcribe_version\":\"2.7.0\",\"model\":\"model-a\",\"diarization_enabled\":false,\"input_basename\":\"\(name)\",\"file_bytes\":1000,\"audio_duration_s\":10,\"segment_count\":1,\"speakers_detected\":null,\"audio_load_ms\":100,\"whisper_init_ms\":100,\"speaker_init_ms\":0,\"parallel_ms\":0,\"transcribe_only_ms\":1000,\"merge_ms\":0,\"write_outputs_ms\":10,\"total_ms\":1210,\"decoding_windows\":1}"
    }

    /// The good processing lines: one carries a field this binary does not
    /// know. The file ends with a torn line, as a crash mid-append leaves it.
    private var processingLines: [String] {
        [processingLine("a.m4a"), processingLine("b.m4a", extra: "\"unknown_field\":{\"nested\":[1,2.50]},")]
    }
    private let tornLine = "{\"basename\":\"c.m4a\",\"completed_"

    private func writeLedgers() throws {
        try Data((processingLines.joined(separator: "\n") + "\n" + tornLine).utf8).write(to: processingURL)
        try Data((timingLine("t.wav") + "\n").utf8).write(to: timingURL)
    }

    /// The complete 2.x fixture: two managed documents, profiles, ledgers.
    @discardableResult
    private func writeFullFixture() throws -> [CanonicalTranscript] {
        let documents = [document(id: idA, hash: "a", basename: "alpha", rich: true),
                         document(id: idB, hash: "b", basename: "beta")]
        try writeTranscript(documents[0], mtime: 1_750_000_000)
        try writeTranscript(documents[1], mtime: 1_760_000_000)
        try writeProfiles(legacyProfiles())
        try writeLedgers()
        return documents
    }

    private func bytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func manifest(_ database: StateDatabase) throws -> [MigrationSourceRow] {
        try StateMigration.manifestRows(in: database)
    }

    private func row(_ rows: [MigrationSourceRow], _ url: URL) -> MigrationSourceRow? {
        rows.first { $0.sourcePath == url.path }
    }

    private func updatedAt(_ id: UUID, _ database: StateDatabase) throws -> String? {
        try database.query("SELECT updated_at FROM documents WHERE id = ?", [.text(id.uuidString.lowercased())]) {
            $0.text(0)
        }.first ?? nil
    }

    // MARK: - Fresh and full migration

    func testFreshMachineCreatesFreshMarkersAndNoArchive() throws {
        let database = try StateDatabase()
        XCTAssertEqual(try database.metaValue("import_complete"), "fresh")
        XCTAssertEqual(try database.metaValue("archive_complete"), "fresh")
        XCTAssertEqual(try manifest(database), [])
        XCTAssertFalse(exists(archive), "nothing to archive on a fresh machine")
    }

    func testFullMigrationImportsEveryStoreAndArchivesOriginals() throws {
        let documents = try writeFullFixture()
        let originals = try [
            transcriptsDirectory.appendingPathComponent("\(idA.uuidString.lowercased()).transcript.json"),
            transcriptsDirectory.appendingPathComponent("\(idB.uuidString.lowercased()).transcript.json"),
            profilesURL, processingURL, timingURL,
        ].map { ($0, try bytes($0)) }

        let database = try StateDatabase()
        XCTAssertEqual(try database.metaValue("import_complete"), "migrated")
        XCTAssertEqual(try database.metaValue("archive_complete"), "migrated")
        XCTAssertEqual(try database.metaValue("schema_version"), "1")
        XCTAssertEqual(try database.metaValue("created_by"), Transcribe.version)

        // Documents keep their own IDs and every field.
        XCTAssertEqual(try CanonicalTranscriptStore.listing().map(\.id), [idA, idB])
        XCTAssertEqual(try CanonicalTranscriptStore.load(id: idA), documents[0])
        XCTAssertEqual(try CanonicalTranscriptStore.load(id: idB), documents[1])
        // updated_at seeds from the file mtime, so newest-first order holds.
        XCTAssertEqual(try updatedAt(idA, database), iso8601String(Date(timeIntervalSince1970: 1_750_000_000)))
        XCTAssertEqual(try updatedAt(idB, database), iso8601String(Date(timeIntervalSince1970: 1_760_000_000)))
        XCTAssertEqual(try CanonicalTranscriptStore.listing(order: .recentlyUpdated).map(\.id), [idB, idA])

        XCTAssertEqual(try SpeakerProfileStore.profiles(), legacyProfiles())
        XCTAssertEqual(try ProcessingStore.recordLines(), processingLines, "verbatim, torn line dropped")
        XCTAssertEqual(try ProcessingStore.loadRecords().map(\.source_id), ["file:/rec/a.m4a", "file:/rec/b.m4a"])
        XCTAssertEqual(try TimingStore.loadRecent(model: "model-a", diarizationEnabled: false).map(\.input_basename), ["t.wav"])
        // The confirmed match still matches its profile example.
        let matches = try SpeakerProfileStore.matches(
            embeddings: ["SPEAKER_0": [0.25, 0.75]], modelID: CanonicalTranscript.speakerEmbeddingModelID
        )
        XCTAssertEqual(matches["SPEAKER_0"]?.profileID, "p-ada")

        // Originals moved under migrated-v1/ with the same layout and bytes.
        for (source, data) in originals {
            XCTAssertFalse(exists(source), "source moved: \(source.lastPathComponent)")
            let relative = String(source.path.dropFirst(state.path.count + 1))
            let destination = archive.appendingPathComponent(relative)
            XCTAssertEqual(try bytes(destination), data, relative)
            XCTAssertFalse(exists(URL(fileURLWithPath: source.path + ".lock")), "sidecar removed: \(relative)")
        }
        XCTAssertFalse(exists(transcriptsDirectory), "the emptied legacy directory is removed")

        // Permissions.
        XCTAssertEqual(try mode(of: archive), 0o700)
        XCTAssertEqual(try mode(of: archive.appendingPathComponent("transcripts")), 0o700)
        XCTAssertEqual(try mode(of: archive.appendingPathComponent("MANIFEST.tsv")), 0o600)
        XCTAssertEqual(try mode(of: databaseURL), 0o600)

        // The manifest, in the database and as plain text.
        let rows = try manifest(database)
        XCTAssertEqual(rows.count, 5)
        XCTAssertTrue(rows.allSatisfy { $0.status == "imported" && $0.archivedPath == $0.plannedPath })
        XCTAssertEqual(row(rows, processingURL)?.detail, "2 rows; 1 unreadable line kept only in the archive")
        XCTAssertEqual(row(rows, timingURL)?.detail, "1 row")
        XCTAssertEqual(row(rows, profilesURL)?.detail, "2 profiles")
        let tsv = try String(contentsOf: archive.appendingPathComponent("MANIFEST.tsv"), encoding: .utf8)
        let lines = tsv.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "source_path\tstatus\tarchived_path\tdetail")
        XCTAssertEqual(lines.count, 6)
        XCTAssertTrue(lines.contains(
            "\(processingURL.path)\timported\t\(archive.appendingPathComponent("processing_history.jsonl").path)\t2 rows; 1 unreadable line kept only in the archive"
        ), tsv)

        // A second open migrates nothing more.
        StateStore.closeShared()
        database.close()
        let reopened = try StateDatabase()
        XCTAssertEqual(try manifest(reopened), rows)
        XCTAssertEqual(try ProcessingStore.recordLines(), processingLines)
    }

    func testDuplicateEvidenceAndForeignNamesResolveToFirstUUIDNamedFile() throws {
        // UUID-named files win over foreign-named ones even when a foreign
        // name sorts first.
        let winner = try writeTranscript(document(id: idA, hash: "a", basename: "alpha"))
        let sameEvidence = try writeTranscript(document(id: idB, hash: "a", basename: "alpha-rerun"))
        let earlyForeignSameID = try writeTranscript(document(id: idA, hash: "d", basename: "copy"), name: "0-early")
        let foreign = try writeTranscript(document(id: idC, hash: "c", basename: "gamma"), name: "meeting")

        let database = try StateDatabase()
        XCTAssertEqual(try CanonicalTranscriptStore.listing().map(\.id), [idA, idC])
        XCTAssertEqual(try CanonicalTranscriptStore.load(id: idA).basename, "alpha")

        let rows = try manifest(database)
        XCTAssertEqual(row(rows, winner)?.status, "imported")
        XCTAssertNil(row(rows, winner)?.detail)
        XCTAssertEqual(row(rows, sameEvidence)?.status, "conflict")
        XCTAssertEqual(row(rows, sameEvidence)?.detail, "same recording (evidence ID) was already imported from \(winner.path)")
        XCTAssertEqual(row(rows, earlyForeignSameID)?.status, "conflict")
        XCTAssertEqual(row(rows, earlyForeignSameID)?.detail, "document ID \(idA.uuidString.lowercased()) was already imported from \(winner.path)")
        XCTAssertEqual(row(rows, foreign)?.status, "imported")
        XCTAssertEqual(row(rows, foreign)?.detail, "filename stem differs from document ID \(idC.uuidString.lowercased()); address it by that ID")

        // Conflicts stay where they were, unarchived, lock sidecars too.
        for url in [sameEvidence, earlyForeignSameID] {
            XCTAssertTrue(exists(url))
            XCTAssertNil(row(rows, url)?.archivedPath)
            XCTAssertNil(row(rows, url)?.plannedPath)
        }
        XCTAssertFalse(exists(winner))
        XCTAssertFalse(exists(foreign))
        XCTAssertTrue(exists(archive.appendingPathComponent("transcripts/meeting.transcript.json")))
        XCTAssertEqual(try database.metaValue("archive_complete"), "migrated")
    }

    func testUnreadableTranscriptIsSkippedAndLeftInPlace() throws {
        let good = try writeTranscript(document(id: idA, hash: "a"))
        let bad = transcriptsDirectory.appendingPathComponent("\(idB.uuidString.lowercased()).transcript.json")
        try Data("{\"schema_version\": 1, \"id\": ".utf8).write(to: bad)
        let invalid = try writeTranscript(document(id: idC, hash: "c"))
        // Valid JSON that fails semantic validation.
        try Data(try String(contentsOf: invalid, encoding: .utf8)
            .replacingOccurrences(of: "\"model\" : \"whisper-test\"", with: "\"model\" : \"\"").utf8).write(to: invalid)

        let database = try StateDatabase()
        XCTAssertEqual(try CanonicalTranscriptStore.listing().map(\.id), [idA])
        let rows = try manifest(database)
        XCTAssertEqual(row(rows, bad)?.status, "skipped")
        XCTAssertTrue(row(rows, bad)?.detail?.hasPrefix("unreadable: ") ?? false, "\(rows)")
        XCTAssertEqual(row(rows, invalid)?.status, "skipped")
        XCTAssertEqual(row(rows, invalid)?.detail, "unreadable: Invalid canonical transcript: required string is empty")
        XCTAssertTrue(exists(bad))
        XCTAssertTrue(exists(invalid))
        XCTAssertFalse(exists(good))
        let tsv = try String(contentsOf: archive.appendingPathComponent("MANIFEST.tsv"), encoding: .utf8)
        XCTAssertTrue(tsv.contains("\(bad.path)\tskipped\t\tunreadable: "), tsv)
    }

    func testDuplicateExportPathsKeepTheLastRecord() throws {
        var duplicate = document(id: idA, hash: "a", basename: "alpha", rich: true)
        let first = ExportRecord(path: "/notes/alpha.txt", format: "txt", sha256: String(repeating: "1", count: 64),
                                 exportedAt: Date(timeIntervalSince1970: 1_700_000_100))
        let other = ExportRecord(path: "/notes/alpha.srt", format: "srt", sha256: String(repeating: "3", count: 64),
                                 exportedAt: Date(timeIntervalSince1970: 1_700_000_150))
        let last = ExportRecord(path: "/notes/alpha.txt", format: "txt", sha256: String(repeating: "2", count: 64),
                                exportedAt: Date(timeIntervalSince1970: 1_700_000_200))
        duplicate.exports = [first, other, last]
        let file = try writeTranscript(duplicate)

        let database = try StateDatabase()
        XCTAssertEqual(try CanonicalTranscriptStore.load(id: idA).exports, [other, last])
        XCTAssertEqual(row(try manifest(database), file)?.detail, "duplicate export records; kept the last one per path")
    }

    // MARK: - Abort and rebuild

    func testInvalidProfileStoreAbortsWithoutLeavingADatabase() throws {
        try writeTranscript(document(id: idA, hash: "a"))
        try writeLedgers()
        var profiles = legacyProfiles()
        profiles[1] = SpeakerProfile(id: "p-ada", name: "Duplicate", examples: [])
        try writeProfiles(profiles)
        let sources = [profilesURL, processingURL, timingURL,
                       transcriptsDirectory.appendingPathComponent("\(idA.uuidString.lowercased()).transcript.json")]
        let before = try sources.map { try bytes($0) }

        XCTAssertThrowsError(try StateDatabase()) { error in
            XCTAssertEqual(
                error as? StateMigrationError,
                .invalidProfileStore(path: profilesURL.path, reason: "Invalid speaker profile store: duplicate profile ID")
            )
        }
        for suffix in ["", "-wal", "-shm", "-journal"] {
            XCTAssertFalse(exists(URL(fileURLWithPath: databaseURL.path + suffix)), "no state.db\(suffix) left behind")
        }
        XCTAssertEqual(try sources.map { try bytes($0) }, before, "sources untouched")
        XCTAssertFalse(exists(archive))

        // Unparseable JSON aborts the same way.
        try Data("{\"schema_version\": 1, \"profiles\": [".utf8).write(to: profilesURL)
        XCTAssertThrowsError(try StateDatabase()) { error in
            guard case .invalidProfileStore(let path, _) = error as? StateMigrationError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(path, profilesURL.path)
        }
        XCTAssertFalse(exists(databaseURL))

        // After repair the next attempt migrates everything.
        try writeProfiles(legacyProfiles())
        let database = try StateDatabase()
        XCTAssertEqual(try database.metaValue("import_complete"), "migrated")
        XCTAssertEqual(try SpeakerProfileStore.profiles(), legacyProfiles())
        XCTAssertEqual(try CanonicalTranscriptStore.listing().map(\.id), [idA])
        XCTAssertEqual(try ProcessingStore.recordLines(), processingLines)
    }

    func testTornLedgerLinesAreCountedAndSurviveInTheArchive() throws {
        let good = (1...3).map { processingLine("\($0).m4a") }
        let original = Data((good.joined(separator: "\n") + "\n\n" + "not json at all\n" + tornLine).utf8)
        try original.write(to: processingURL)

        let database = try StateDatabase()
        XCTAssertEqual(try ProcessingStore.recordLines(), good)
        XCTAssertEqual(row(try manifest(database), processingURL)?.detail,
                       "3 rows; 2 unreadable lines kept only in the archive")
        XCTAssertEqual(try bytes(archive.appendingPathComponent("processing_history.jsonl")), original)
        // The absent timing ledger was created only to hold its lock: it is
        // neither imported nor left behind.
        XCTAssertFalse(exists(timingURL))
        XCTAssertNil(row(try manifest(database), timingURL))
        XCTAssertFalse(exists(archive.appendingPathComponent("timing_history.jsonl")))
    }

    /// A database whose import never committed (no `import_complete`) is
    /// deleted and rebuilt from the sources, which the interrupted attempt
    /// never touched.
    func testInterruptedImportIsRebuiltFromUntouchedSources() throws {
        let documents = try writeFullFixture()
        let processingBytes = try bytes(processingURL)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, """
            PRAGMA user_version = 1;
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            INSERT INTO meta VALUES ('schema_version', '1');
            CREATE TABLE documents (id TEXT PRIMARY KEY);
            INSERT INTO documents VALUES ('half-imported');
            """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        let database = try StateDatabase()
        XCTAssertEqual(try database.metaValue("import_complete"), "migrated")
        XCTAssertEqual(try database.metaValue("archive_complete"), "migrated")
        XCTAssertEqual(try CanonicalTranscriptStore.listing().map(\.id), [idA, idB])
        XCTAssertEqual(try CanonicalTranscriptStore.load(id: idA), documents[0])
        XCTAssertEqual(try ProcessingStore.recordLines(), processingLines)
        XCTAssertEqual(try bytes(archive.appendingPathComponent("processing_history.jsonl")), processingBytes)
    }

    // MARK: - Archive resume

    func testInterruptedArchiveResumesWithoutDoubleMoving() throws {
        try writeFullFixture()
        let transcriptA = transcriptsDirectory.appendingPathComponent("\(idA.uuidString.lowercased()).transcript.json")
        let archivedA = archive.appendingPathComponent("transcripts/\(idA.uuidString.lowercased()).transcript.json")
        let archivedProcessing = archive.appendingPathComponent("processing_history.jsonl")
        do {
            let database = try StateDatabase()
            // Simulate a crash part-way through phase 2: transcript A was
            // renamed but the rename not yet recorded; the processing ledger
            // was not even planned; the rest are done.
            try FileManager.default.moveItem(at: archivedProcessing, to: processingURL)
            try database.inTransaction(.write) {
                try database.execute("UPDATE migration_sources SET archived_path = NULL WHERE source_path = ?",
                                     [.text(transcriptA.path)])
                try database.execute(
                    "UPDATE migration_sources SET archived_path = NULL, planned_path = NULL WHERE source_path = ?",
                    [.text(processingURL.path)]
                )
                try database.execute("DELETE FROM meta WHERE key = 'archive_complete'")
            }
            try FileManager.default.removeItem(at: archive.appendingPathComponent("MANIFEST.tsv"))
            database.close()
        }
        StateStore.closeShared()
        // An older binary also recreated an already-archived ledger before
        // the recovering open; that same open must import it.
        let lateTiming = Data((timingLine("late.wav") + "\n").utf8)
        try lateTiming.write(to: timingURL)

        let resumed = try StateDatabase()
        XCTAssertEqual(try resumed.metaValue("archive_complete"), "migrated")
        let rows = try manifest(resumed)
        XCTAssertTrue(rows.allSatisfy { $0.archivedPath != nil && $0.archivedPath == $0.plannedPath }, "\(rows)")
        XCTAssertEqual(row(rows, transcriptA)?.archivedPath, archivedA.path)
        XCTAssertEqual(row(rows, processingURL)?.archivedPath, archivedProcessing.path)
        XCTAssertTrue(exists(archivedA))
        XCTAssertTrue(exists(archivedProcessing))
        XCTAssertFalse(exists(processingURL))
        XCTAssertFalse(exists(timingURL))
        XCTAssertEqual(try bytes(archive.appendingPathComponent("timing_history.2.jsonl")), lateTiming)
        XCTAssertEqual(try TimingStore.loadRecent(model: "model-a").map(\.input_basename), ["t.wav", "late.wav"])
        let archived = try FileManager.default.subpathsOfDirectory(atPath: archive.path).sorted()
        XCTAssertEqual(archived, [
            "MANIFEST.tsv", "processing_history.jsonl", "speaker_profiles.json", "timing_history.2.jsonl",
            "timing_history.jsonl",
            "transcripts", "transcripts/\(idA.uuidString.lowercased()).transcript.json",
            "transcripts/\(idB.uuidString.lowercased()).transcript.json",
        ], "nothing moved twice; only the recreated ledger takes a suffixed name")
        let tsv = try String(contentsOf: archive.appendingPathComponent("MANIFEST.tsv"), encoding: .utf8)
        XCTAssertEqual(tsv.split(separator: "\n").count, 7)
        XCTAssertNil(try resumed.metaValue(StateMigration.manifestDirtyKey))
        XCTAssertEqual(try ProcessingStore.recordLines(), processingLines, "resume does not re-import")
    }

    /// A crash after the rename but before `archived_path` committed, and
    /// then an older binary recreating the ledger: the planned destination
    /// is the completed move, and the recreated file — never imported — is
    /// imported as a reappearance rather than archived unread.
    func testResumeWithBothSourceAndPlannedDestinationImportsTheRecreatedLedger() throws {
        try writeFullFixture()
        let archivedProcessing = archive.appendingPathComponent("processing_history.jsonl")
        let originalBytes = try bytes(processingURL)
        do {
            let database = try StateDatabase()
            try database.inTransaction(.write) {
                try database.execute("UPDATE migration_sources SET archived_path = NULL WHERE source_path = ?",
                                     [.text(processingURL.path)])
                try database.execute("DELETE FROM meta WHERE key = 'archive_complete'")
            }
            database.close()
        }
        StateStore.closeShared()
        let later = processingLine("recreated.m4a")
        let recreated = Data((later + "\n").utf8)
        try recreated.write(to: processingURL)

        let database = try StateDatabase()
        XCTAssertEqual(try database.metaValue("archive_complete"), "migrated")
        let rows = try manifest(database)
        XCTAssertEqual(row(rows, processingURL)?.archivedPath, archivedProcessing.path)
        XCTAssertEqual(try bytes(archivedProcessing), originalBytes, "the original archive is untouched")
        XCTAssertEqual(try bytes(archive.appendingPathComponent("processing_history.2.jsonl")), recreated)
        XCTAssertFalse(exists(processingURL))
        XCTAssertEqual(try ProcessingStore.recordLines(), processingLines + [later])
    }

    /// A 2.x writer holding the ledger's flock mid-append must finish before
    /// migration reads the file, so its line is imported, not lost.
    func testReappearedLedgerImportWaitsForTheLegacyWriterLock() throws {
        try writeFullFixture()
        try StateDatabase().close()
        StateStore.closeShared()

        let first = processingLine("first.m4a")
        try Data((first + "\n").utf8).write(to: processingURL)
        let fd = open(processingURL.path, O_WRONLY | O_APPEND)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX), 0)

        let finished = DispatchSemaphore(value: 0)
        var openError: Error?
        DispatchQueue.global().async {
            do { try StateDatabase().close() } catch { openError = error }
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 0.5), .timedOut, "migration waits for the writer's lock")
        let second = processingLine("second.m4a")
        XCTAssertEqual(write(fd, second + "\n", second.utf8.count + 1), second.utf8.count + 1)
        XCTAssertEqual(flock(fd, LOCK_UN), 0)
        XCTAssertEqual(finished.wait(timeout: .now() + 30), .success)
        XCTAssertNil(openError)

        XCTAssertEqual(try ProcessingStore.recordLines(), processingLines + [first, second])
        XCTAssertEqual(
            try String(contentsOf: archive.appendingPathComponent("processing_history.2.jsonl"), encoding: .utf8),
            first + "\n" + second + "\n"
        )
    }

    /// Rows committed but the manifest never written (a crash in between):
    /// the dirty flag makes the next open rewrite it.
    func testStaleManifestIsRewrittenOnTheNextOpen() throws {
        try writeFullFixture()
        do {
            let database = try StateDatabase()
            XCTAssertNil(try database.metaValue(StateMigration.manifestDirtyKey))
            try database.inTransaction(.write) {
                try database.execute(
                    "INSERT INTO migration_sources (source_path, status, detail) VALUES ('/simulated/late.transcript.json', 'skipped', 'simulated')"
                )
                try database.setMeta(StateMigration.manifestDirtyKey, "1")
            }
            database.close()
        }
        StateStore.closeShared()
        let manifestURL = archive.appendingPathComponent("MANIFEST.tsv")
        XCTAssertFalse(try String(contentsOf: manifestURL, encoding: .utf8).contains("/simulated/late"))

        let database = try StateDatabase()
        XCTAssertTrue(try String(contentsOf: manifestURL, encoding: .utf8)
            .contains("/simulated/late.transcript.json\tskipped\t\tsimulated"))
        XCTAssertNil(try database.metaValue(StateMigration.manifestDirtyKey))
    }

    /// Each move flushes the destination and source directories before the
    /// database records it; a failed flush leaves the row unrecorded and
    /// `archive_complete` unset, and the next open finishes the job. A real
    /// power-loss test is not possible here, so the flush goes through a
    /// seam that records calls and can fail.
    func testArchiveMovesAreSyncedBeforeBeingRecorded() throws {
        try writeFullFixture()
        let original = StateMigration.syncDirectory
        defer { StateMigration.syncDirectory = original }
        var synced: [String] = []
        StateMigration.syncDirectory = { synced.append($0); return false }

        do {
            let database = try StateDatabase()
            XCTAssertEqual(try database.metaValue("import_complete"), "migrated")
            XCTAssertNil(try database.metaValue("archive_complete"), "unconfirmed moves keep the phase open")
            XCTAssertTrue(try manifest(database).allSatisfy { $0.archivedPath == nil && $0.plannedPath != nil })
            database.close()
        }
        StateStore.closeShared()
        // Every planned destination was reached and both of its directories
        // were flushed, once per move.
        XCTAssertFalse(exists(processingURL))
        XCTAssertTrue(exists(archive.appendingPathComponent("processing_history.jsonl")))
        XCTAssertEqual(synced.filter { $0 == archive.path }.count, 4, "profiles, both ledgers, the manifest")
        XCTAssertEqual(synced.filter { $0 == archive.appendingPathComponent("transcripts").path }.count, 2)
        XCTAssertEqual(synced.filter { $0 == state.path }.count, 3)
        XCTAssertEqual(synced.filter { $0 == transcriptsDirectory.path }.count, 2)
        XCTAssertEqual(try StateDatabase().metaValue(StateMigration.manifestDirtyKey), "1",
                       "an unflushed manifest stays marked for rewrite")
        StateStore.closeShared()

        synced = []
        StateMigration.syncDirectory = { synced.append($0); return true }
        let database = try StateDatabase()
        XCTAssertEqual(try database.metaValue("archive_complete"), "migrated")
        XCTAssertTrue(try manifest(database).allSatisfy { $0.archivedPath != nil && $0.archivedPath == $0.plannedPath })
        XCTAssertTrue(synced.contains(archive.path))
        XCTAssertEqual(try ProcessingStore.recordLines(), processingLines, "nothing re-imported")
    }

    /// Without lock sidecars the emptied transcripts/ directory used to be
    /// removed while a move out of it was still unconfirmed. It now stays
    /// until every move is recorded; and if it is gone anyway on retry, its
    /// surviving parent is flushed instead.
    func testTranscriptOnlyMigrationKeepsItsDirectoryUntilMovesAreConfirmed() throws {
        let file = try writeTranscript(document(id: idA, hash: "a"), lockSidecar: false)
        let original = StateMigration.syncDirectory
        defer { StateMigration.syncDirectory = original }
        var synced: [String] = []
        StateMigration.syncDirectory = { synced.append($0); return false }

        do {
            let database = try StateDatabase()
            XCTAssertNil(try database.metaValue("archive_complete"))
            database.close()
        }
        StateStore.closeShared()
        XCTAssertFalse(exists(file))
        XCTAssertTrue(exists(transcriptsDirectory), "kept while its move is unconfirmed")
        XCTAssertTrue(synced.contains(transcriptsDirectory.path))

        // Removed anyway before the retry: flush the state directory, whose
        // entry for it changed.
        XCTAssertEqual(rmdir(transcriptsDirectory.path), 0)
        synced = []
        StateMigration.syncDirectory = { synced.append($0); return true }
        let database = try StateDatabase()
        XCTAssertEqual(try database.metaValue("archive_complete"), "migrated")
        XCTAssertEqual(row(try manifest(database), file)?.archivedPath,
                       archive.appendingPathComponent("transcripts/\(idA.uuidString.lowercased()).transcript.json").path)
        XCTAssertTrue(synced.contains(state.path), "\(synced)")
        XCTAssertFalse(synced.contains(transcriptsDirectory.path))
    }

    /// A ledger that did not exist when migration started, created and
    /// written by a 2.x writer under its lock while migration waits on the
    /// other ledger: migration must lock it too, so the line is imported.
    func testLedgerCreatedDuringMigrationIsLockedAndImported() throws {
        try Data((processingLines.joined(separator: "\n") + "\n").utf8).write(to: processingURL)
        XCTAssertFalse(exists(timingURL))
        let processingFD = open(processingURL.path, O_WRONLY | O_APPEND)
        XCTAssertGreaterThanOrEqual(processingFD, 0)
        defer { close(processingFD) }
        XCTAssertEqual(flock(processingFD, LOCK_EX), 0)

        let finished = DispatchSemaphore(value: 0)
        var openError: Error?
        DispatchQueue.global().async {
            do { try StateDatabase().close() } catch { openError = error }
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 0.5), .timedOut)

        let timingFD = open(timingURL.path, O_CREAT | O_WRONLY | O_APPEND, 0o600)
        XCTAssertGreaterThanOrEqual(timingFD, 0)
        defer { close(timingFD) }
        XCTAssertEqual(flock(timingFD, LOCK_EX), 0)
        XCTAssertEqual(flock(processingFD, LOCK_UN), 0)
        XCTAssertEqual(finished.wait(timeout: .now() + 0.5), .timedOut, "migration waits for the timing writer too")
        // The append completes under the timing lock, after migration has
        // been released from the processing lock.
        let line = timingLine("racing.wav") + "\n"
        XCTAssertEqual(write(timingFD, line, line.utf8.count), line.utf8.count)
        XCTAssertEqual(flock(timingFD, LOCK_UN), 0)
        XCTAssertEqual(finished.wait(timeout: .now() + 30), .success)
        XCTAssertNil(openError)

        XCTAssertEqual(try TimingStore.loadRecent(model: "model-a").map(\.input_basename), ["racing.wav"])
        XCTAssertEqual(try String(contentsOf: archive.appendingPathComponent("timing_history.jsonl"), encoding: .utf8), line)
        XCTAssertFalse(exists(timingURL))
    }

    /// Simulates a crash after `planned_path` committed but before the
    /// rename, with an unrelated file then created at that destination.
    private func simulateUnrelatedFileAtPlannedDestination(moveSourceBack: Bool) throws -> (unrelated: Data, original: Data) {
        try writeFullFixture()
        let original = try bytes(processingURL)
        let archived = archive.appendingPathComponent("processing_history.jsonl")
        let unrelated = Data("someone else's file\n".utf8)
        do {
            let database = try StateDatabase()
            try database.inTransaction(.write) {
                try database.execute("UPDATE migration_sources SET archived_path = NULL WHERE source_path = ?",
                                     [.text(processingURL.path)])
                try database.execute("DELETE FROM meta WHERE key = 'archive_complete'")
            }
            database.close()
        }
        StateStore.closeShared()
        if moveSourceBack {
            try FileManager.default.moveItem(at: archived, to: processingURL)
        } else {
            try FileManager.default.removeItem(at: archived)
        }
        try unrelated.write(to: archived)
        return (unrelated, original)
    }

    func testUnrelatedFileAtPlannedDestinationIsLeftAloneAndTheSourceMovesElsewhere() throws {
        let (unrelated, original) = try simulateUnrelatedFileAtPlannedDestination(moveSourceBack: true)
        let database = try StateDatabase()
        XCTAssertEqual(try database.metaValue("archive_complete"), "migrated")
        let suffixed = archive.appendingPathComponent("processing_history.2.jsonl")
        let processing = row(try manifest(database), processingURL)
        XCTAssertEqual(processing?.plannedPath, suffixed.path)
        XCTAssertEqual(processing?.archivedPath, suffixed.path)
        XCTAssertEqual(try bytes(archive.appendingPathComponent("processing_history.jsonl")), unrelated)
        XCTAssertEqual(try bytes(suffixed), original)
        XCTAssertFalse(exists(processingURL))
        XCTAssertEqual(try ProcessingStore.recordLines(), processingLines, "the original is not re-imported")
    }

    func testUnrelatedFileAtPlannedDestinationWithTheSourceGoneIsNotClaimed() throws {
        let (unrelated, _) = try simulateUnrelatedFileAtPlannedDestination(moveSourceBack: false)
        let database = try StateDatabase()
        XCTAssertEqual(try database.metaValue("archive_complete"), "migrated")
        let processing = row(try manifest(database), processingURL)
        XCTAssertEqual(processing?.archivedPath, "")
        XCTAssertTrue(processing?.detail?.contains("holds a different file and the source was gone") ?? false,
                      processing?.detail ?? "")
        XCTAssertEqual(try bytes(archive.appendingPathComponent("processing_history.jsonl")), unrelated)
        XCTAssertEqual(try ProcessingStore.recordLines(), processingLines)
    }

    /// A pending move that fails (its destination's parent is a regular
    /// file) must not stop a dirty manifest from being rewritten.
    func testFailingPendingMoveStillRepairsAStaleManifest() throws {
        try writeFullFixture()
        let extra = state.appendingPathComponent("extra.txt")
        let blocker = archive.appendingPathComponent("blocker")
        do {
            let database = try StateDatabase()
            try Data("x".utf8).write(to: extra)
            try Data("not a directory".utf8).write(to: blocker)
            try database.inTransaction(.write) {
                try database.execute(
                    "INSERT INTO migration_sources (source_path, status, planned_path) VALUES (?, 'imported', ?)",
                    [.text(extra.path), .text(blocker.appendingPathComponent("extra.txt").path)]
                )
                try database.setMeta(StateMigration.manifestDirtyKey, "1")
            }
            database.close()
        }
        StateStore.closeShared()

        let database = try StateDatabase()
        let tsv = try String(contentsOf: archive.appendingPathComponent("MANIFEST.tsv"), encoding: .utf8)
        XCTAssertTrue(tsv.contains("\(extra.path)\timported\t\t"), tsv)
        XCTAssertNil(try database.metaValue(StateMigration.manifestDirtyKey))
        XCTAssertTrue(exists(extra), "the failed move left the source in place")
    }

    func testUnreadableTranscriptsDirectoryAbortsMigration() throws {
        try writeTranscript(document(id: idA, hash: "a"))
        try writeLedgers()
        XCTAssertEqual(chmod(transcriptsDirectory.path, 0), 0)
        defer { chmod(transcriptsDirectory.path, 0o700) }

        XCTAssertThrowsError(try StateDatabase()) { error in
            guard case .unreadableTranscriptsDirectory(let path, _) = error as? StateMigrationError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(path, transcriptsDirectory.path)
        }
        XCTAssertFalse(exists(databaseURL), "no database may hide the unlisted files")
        XCTAssertTrue(exists(processingURL), "nothing moved")
        XCTAssertFalse(exists(archive))

        XCTAssertEqual(chmod(transcriptsDirectory.path, 0o700), 0)
        let database = try StateDatabase()
        XCTAssertEqual(try CanonicalTranscriptStore.listing().map(\.id), [idA])
        XCTAssertEqual(try database.metaValue("archive_complete"), "migrated")
    }

    func testPreexistingArchiveFileGetsANumericSuffix() throws {
        try writeLedgers()
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let squatter = archive.appendingPathComponent("timing_history.jsonl")
        try Data("unrelated\n".utf8).write(to: squatter)

        let database = try StateDatabase()
        XCTAssertEqual(row(try manifest(database), timingURL)?.archivedPath,
                       archive.appendingPathComponent("timing_history.2.jsonl").path)
        XCTAssertEqual(try String(contentsOf: squatter, encoding: .utf8), "unrelated\n")
        XCTAssertEqual(try mode(of: archive), 0o700, "an existing archive directory is tightened")
    }

    // MARK: - Reappeared legacy files

    func testReappearedLedgerIsImportedAndArchivedWithASuffix() throws {
        try writeFullFixture()
        try StateDatabase().close()
        StateStore.closeShared()

        // An older binary still running appends to a recreated ledger.
        let later = [processingLine("late.m4a")]
        let recreated = Data((later.joined(separator: "\n") + "\n").utf8)
        try recreated.write(to: processingURL)

        let database = try StateDatabase()
        XCTAssertEqual(try ProcessingStore.recordLines(), processingLines + later)
        XCTAssertFalse(exists(processingURL))
        let suffixed = archive.appendingPathComponent("processing_history.2.jsonl")
        XCTAssertEqual(try bytes(suffixed), recreated)
        let rows = try manifest(database)
        let reappeared = rows.first { $0.sourcePath == processingURL.path + "#reappeared-1" }
        XCTAssertEqual(reappeared?.status, "imported")
        XCTAssertEqual(reappeared?.detail, "reappeared after migration; 1 row")
        XCTAssertEqual(reappeared?.archivedPath, suffixed.path)
        XCTAssertEqual(reappeared?.filePath, processingURL.path)
        XCTAssertTrue(reappeared?.isReappeared ?? false)
        let tsv = try String(contentsOf: archive.appendingPathComponent("MANIFEST.tsv"), encoding: .utf8)
        XCTAssertTrue(tsv.contains(suffixed.path), tsv)

        // Nothing further happens on the next open.
        database.close()
        StateStore.closeShared()
        let again = try StateDatabase()
        XCTAssertEqual(try manifest(again), rows)
        XCTAssertEqual(try ProcessingStore.recordLines(), processingLines + later)
    }

    func testReappearedLedgerOnAFreshDatabaseIsImported() throws {
        try StateDatabase().close()
        StateStore.closeShared()
        try Data((timingLine("x.wav") + "\n").utf8).write(to: timingURL)

        let database = try StateDatabase()
        XCTAssertEqual(try TimingStore.loadRecent(model: "model-a").map(\.input_basename), ["x.wav"])
        XCTAssertEqual(row(try manifest(database), timingURL)?.archivedPath,
                       archive.appendingPathComponent("timing_history.jsonl").path)
        XCTAssertFalse(exists(timingURL))
        XCTAssertEqual(try database.metaValue("archive_complete"), "fresh")
    }

    func testReappearedProfileStoreIsNeverMerged() throws {
        try writeFullFixture()
        try StateDatabase().close()
        StateStore.closeShared()

        try writeProfiles(legacyProfiles(name: "Ada Lovelace"))
        let database = try StateDatabase()
        XCTAssertEqual(try SpeakerProfileStore.profiles(), legacyProfiles(), "not merged")
        XCTAssertTrue(exists(profilesURL), "left in place for a person to reconcile")
        let rows = try manifest(database)
        let reappeared = rows.filter { $0.filePath == profilesURL.path && $0.isReappeared }
        XCTAssertEqual(reappeared.map(\.status), ["skipped"])
        XCTAssertEqual(reappeared.first?.detail, StateMigration.reappearedProfilesDetail)
        XCTAssertNil(reappeared.first?.archivedPath)

        database.close()
        StateStore.closeShared()
        XCTAssertEqual(try manifest(try StateDatabase()), rows, "recorded once")
    }

    func testReappearedTranscriptIsRecordedForImportAndLeftInPlace() throws {
        try writeFullFixture()
        try StateDatabase().close()
        StateStore.closeShared()

        let late = try writeTranscript(document(id: idC, hash: "c", basename: "late"))
        let database = try StateDatabase()
        XCTAssertEqual(try CanonicalTranscriptStore.listing().map(\.id), [idA, idB], "not imported")
        XCTAssertTrue(exists(late))
        let rows = try manifest(database)
        XCTAssertEqual(row(rows, late)?.status, "skipped")
        XCTAssertEqual(row(rows, late)?.detail, StateMigration.reappearedTranscriptDetail)
        database.close()
        StateStore.closeShared()
        XCTAssertEqual(try manifest(try StateDatabase()), rows, "recorded once")
    }

    // MARK: - CLI

    private func run(_ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CLITests.transcribePath)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(["XDG_STATE_HOME": root.path]) { _, new in new }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }

    func testCLIMigratesAutomaticallyOnceAndListsMigratedDocuments() throws {
        try writeFullFixture()
        let first = try run(["transcripts"])
        XCTAssertEqual(first.status, 0, first.stderr)
        XCTAssertTrue(first.stderr.contains("Migrated transcribe state into \(databaseURL.path)"), first.stderr)
        XCTAssertTrue(first.stderr.contains("migrated-v1"), first.stderr)
        let rows = first.stdout.split(separator: "\n").map(String.init)
        XCTAssertTrue(rows.contains { $0.hasPrefix("aaaaaaaa") && $0.hasSuffix("alpha") }, first.stdout)
        XCTAssertTrue(rows.contains { $0.hasPrefix("bbbbbbbb") && $0.hasSuffix("beta") }, first.stdout)

        let second = try run(["transcripts"])
        XCTAssertEqual(second.status, 0, second.stderr)
        XCTAssertFalse(second.stderr.contains("Migrated"), second.stderr)
        XCTAssertEqual(second.stdout, first.stdout)
    }

    func testCLIMigrationStatusOnAFreshDatabase() throws {
        let result = try run(["transcripts", "migration-status"])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.hasPrefix("Nothing was migrated"), result.stdout)
        XCTAssertTrue(result.stdout.contains("created fresh"), result.stdout)
    }

    func testCLIMigrationStatusListsImportedSkippedConflictAndReappeared() throws {
        try writeFullFixture()
        let conflict = try writeTranscript(document(id: idC, hash: "a", basename: "dupe"))
        let bad = transcriptsDirectory.appendingPathComponent("broken.transcript.json")
        try Data("{".utf8).write(to: bad)
        let migrated = try run(["transcripts"])
        XCTAssertTrue(migrated.stderr.contains("2 transcript files were left in place"), migrated.stderr)

        // A profile store recreated afterwards is reported loudly, every run.
        try writeProfiles(legacyProfiles(name: "Changed"))
        let status = try run(["transcripts", "migration-status"])
        XCTAssertEqual(status.status, 0, status.stderr)
        XCTAssertTrue(status.stderr.contains("SPEAKER PROFILES NOT MERGED"), status.stderr)
        let out = status.stdout
        XCTAssertTrue(out.contains("Migrated 2.x state files into \(databaseURL.path)."), out)
        XCTAssertTrue(out.contains("plain-text manifest: \(archive.path)/MANIFEST.tsv"), out)
        XCTAssertTrue(out.contains("Imported (5):"), out)
        XCTAssertTrue(out.contains("  \(processingURL.path) -> \(archive.path)/processing_history.jsonl (2 rows; 1 unreadable line kept only in the archive)"), out)
        XCTAssertTrue(out.contains("Skipped (1):\n  \(bad.path): unreadable: "), out)
        XCTAssertTrue(out.contains("Conflicts (1):\n  \(conflict.path): same recording (evidence ID) was already imported from "), out)
        XCTAssertTrue(out.contains("Reappeared after migration (1):\n  \(profilesURL.path) [skipped]: \(StateMigration.reappearedProfilesDetail)"), out)
        XCTAssertTrue(out.contains("transcribe transcripts import <path>"), out)

        let again = try run(["transcripts"])
        XCTAssertTrue(again.stderr.contains("SPEAKER PROFILES NOT MERGED"), again.stderr)
    }

    // MARK: - export-legacy equivalence (phase 5)

    private struct DecodedProfileFile: Decodable, Equatable {
        let schemaVersion: Int
        let profiles: [SpeakerProfile]
        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case profiles
        }
    }

    private func decodedProfiles(_ url: URL) throws -> DecodedProfileFile {
        try JSONDecoder().decode(DecodedProfileFile.self, from: bytes(url))
    }

    /// The spec's acceptance harness: migrate the 2.x fixture, export it
    /// back as 2.x files through the real binary, and compare against the
    /// sources. Ledger lines are byte-identical in order (the torn final
    /// line was never imported, so it is the one difference); documents and
    /// profiles are decoded-equal — and, as the 2.x writers produced them,
    /// byte-identical too.
    /// Frozen 2.x bytes: `Fixtures/Legacy2x/` holds a portable document and a
    /// `speaker_profiles.json` captured once from the writers, which were
    /// verified byte-compatible with the 2.7.0 release. They are a format
    /// contract and are never regenerated: the other export tests compare
    /// against bytes the current encoder produced, so encoder drift would
    /// pass them silently. Any change to the portable or profile-store
    /// encoding must fail here, deliberately.
    func testExportLegacyMatchesFrozen2xBytes() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Legacy2x", isDirectory: true)
        let frozenDocument = try bytes(fixtures.appendingPathComponent("legacy-2x-document.transcript.json"))
        let frozenProfiles = try bytes(fixtures.appendingPathComponent("legacy-2x-speaker_profiles.json"))
        // Sanity: the frozen document is the rich fixture document.
        XCTAssertEqual(try CanonicalTranscriptStore.load(data: frozenDocument),
                       document(id: idA, hash: "a", basename: "alpha", rich: true))

        try FileManager.default.createDirectory(at: transcriptsDirectory, withIntermediateDirectories: true)
        try frozenDocument.write(to: transcriptsDirectory.appendingPathComponent("\(idA.uuidString.lowercased()).transcript.json"))
        try frozenProfiles.write(to: profilesURL)

        let out = root.appendingPathComponent("frozen-export", isDirectory: true)
        let result = try run(["transcripts", "export-legacy", out.path])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(try bytes(out.appendingPathComponent("transcripts/\(idA.uuidString.lowercased()).transcript.json")), frozenDocument)
        XCTAssertEqual(try bytes(out.appendingPathComponent("speaker_profiles.json")), frozenProfiles)
    }

    func testExportLegacyReproducesTheMigrated2xFixture() throws {
        let documents = try writeFullFixture()
        let originalDocuments = try [idA, idB].map {
            try bytes(transcriptsDirectory.appendingPathComponent("\($0.uuidString.lowercased()).transcript.json"))
        }
        let originalProfiles = try bytes(profilesURL)
        let originalTiming = try bytes(timingURL)

        let out = root.appendingPathComponent("export", isDirectory: true)
        let result = try run(["transcripts", "export-legacy", out.path])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stderr.contains("Migrated transcribe state"), "the export migrated first: \(result.stderr)")
        XCTAssertEqual(result.stdout, "Exported 2 transcripts, 2 speaker profiles, 2 processing history rows, and 1 timing history row as 2.x files to \(out.path).\n")

        for (index, document) in documents.enumerated() {
            let file = out.appendingPathComponent("transcripts/\(document.id.uuidString.lowercased()).transcript.json")
            XCTAssertEqual(try CanonicalTranscriptStore.load(from: file), document)
            XCTAssertEqual(try bytes(file), originalDocuments[index])
        }
        let exportedProfiles = out.appendingPathComponent("speaker_profiles.json")
        XCTAssertEqual(try decodedProfiles(exportedProfiles), try decodedProfiles(archive.appendingPathComponent("speaker_profiles.json")))
        XCTAssertEqual(try bytes(exportedProfiles), originalProfiles)
        XCTAssertEqual(try bytes(out.appendingPathComponent("processing_history.jsonl")),
                       Data((processingLines.joined(separator: "\n") + "\n").utf8))
        XCTAssertEqual(
            String(decoding: try bytes(archive.appendingPathComponent("processing_history.jsonl")), as: UTF8.self),
            processingLines.joined(separator: "\n") + "\n" + tornLine,
            "the archive keeps the torn line the export cannot carry"
        )
        XCTAssertEqual(try bytes(out.appendingPathComponent("timing_history.jsonl")), originalTiming)
    }

    /// Lossless rollback: changes made after migration are in the export,
    /// and the export is itself a valid 2.x state directory — migrating it
    /// again yields the same state, and exporting that gives the same bytes.
    func testExportLegacyCarriesPostMigrationChangesAndMigratesBackIdentically() throws {
        try writeFullFixture()
        _ = try StateDatabase()
        // A new confirmation, a dismissal, and ledger appends.
        var beta = try CanonicalTranscriptStore.load(id: idB)
        let match = try SpeakerProfileStore.confirm(
            name: "Bob", profileID: "p-bob", transcriptID: beta.evidenceID, speakerID: "SPEAKER_0",
            embedding: [0.25, 0.75], modelID: beta.embeddingModelID, sourceHashes: beta.sourceHashes
        )
        beta.speakerMatches["SPEAKER_0"] = match
        beta.markDismissed("SPEAKER_1")
        try CanonicalTranscriptStore.save(beta, to: .managed(id: idB))
        let appended = processingLine("late.m4a")
        try ProcessingStore.appendVerbatim(line: appended)
        try TimingStore.appendVerbatim(line: timingLine("late.wav"))

        let out = root.appendingPathComponent("rollback", isDirectory: true)
        let snapshot = try LegacyExport.snapshot()
        try LegacyExport.write(snapshot, to: out)
        XCTAssertEqual(
            try CanonicalTranscriptStore.load(from: out.appendingPathComponent("transcripts/\(idB.uuidString.lowercased()).transcript.json")),
            beta
        )
        let profiles = try decodedProfiles(out.appendingPathComponent("speaker_profiles.json")).profiles
        XCTAssertEqual(profiles.first { $0.id == "p-bob" }?.examples.map(\.transcriptID), [beta.evidenceID])
        let processing = String(decoding: try bytes(out.appendingPathComponent("processing_history.jsonl")), as: UTF8.self)
        XCTAssertEqual(processing, (processingLines + [appended]).joined(separator: "\n") + "\n")

        // Use the export as a 2.x state directory and migrate it again.
        StateStore.closeShared()
        let secondRoot = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: false)
        try FileManager.default.copyItem(at: out, to: secondRoot.appendingPathComponent("transcribe"))
        setenv("XDG_STATE_HOME", secondRoot.path, 1)
        _ = try StateDatabase()
        let again = try LegacyExport.snapshot()
        XCTAssertEqual(again.documents.map(\.id), snapshot.documents.map(\.id))
        XCTAssertEqual(again.documents.map(\.data), snapshot.documents.map(\.data))
        XCTAssertEqual(again.profiles, snapshot.profiles)
        XCTAssertEqual(again.processingLines, snapshot.processingLines)
        XCTAssertEqual(again.timingLines, snapshot.timingLines)
        setenv("XDG_STATE_HOME", root.path, 1)
    }

    // MARK: - transcripts import of files migration left in place (phase 5)

    /// The manifest is matched against the file import actually read: a
    /// different file renamed over the path after the read and before the
    /// write transaction must not be marked imported later.
    func testImportDoesNotMarkAFileReplacedAfterItWasRead() throws {
        try writeFullFixture()
        let bad = transcriptsDirectory.appendingPathComponent("broken.transcript.json")
        try Data("{".utf8).write(to: bad)
        _ = try StateDatabase()
        XCTAssertEqual(row(try manifest(StateDatabase()), bad)?.status, "skipped")
        StateStore.closeShared()

        let read = document(id: UUID(uuidString: "dddddddd-0000-4000-8000-000000000004")!, hash: "d", basename: "read")
        _ = try CanonicalTranscriptStore.save(read, to: bad)
        let swapped = document(id: UUID(uuidString: "eeeeeeee-0000-4000-8000-000000000005")!, hash: "e", basename: "swapped")
        let staging = root.appendingPathComponent("staging.transcript.json")
        _ = try CanonicalTranscriptStore.save(swapped, to: staging)
        defer { SpeakerCommands.afterImportRead = nil }
        SpeakerCommands.afterImportRead = {
            guard rename(staging.path, bad.path) == 0 else { throw POSIXError(.EIO) }
        }

        try SpeakerCommands.transcripts(["import", bad.path])

        XCTAssertEqual(try CanonicalTranscriptStore.load(id: read.id).basename, "read", "what was read is stored")
        XCTAssertFalse(try CanonicalTranscriptStore.listing().contains { $0.id == swapped.id })
        let untouched = row(try manifest(StateDatabase()), bad)
        XCTAssertEqual(untouched?.status, "skipped", "the replacement file was never imported")
        XCTAssertFalse(untouched?.detail?.contains("imported later") ?? true)
    }

    func testImportingSkippedAndConflictFilesUpdatesTheManifest() throws {
        try writeFullFixture()
        let conflict = try writeTranscript(document(id: idC, hash: "a", basename: "dupe"))
        let bad = transcriptsDirectory.appendingPathComponent("broken.transcript.json")
        try Data("{".utf8).write(to: bad)
        XCTAssertEqual(try run(["transcripts"]).status, 0)

        // The user repairs the skipped file and imports it.
        let repaired = document(id: UUID(uuidString: "dddddddd-0000-4000-8000-000000000004")!, hash: "d", basename: "repaired")
        _ = try CanonicalTranscriptStore.save(repaired, to: bad)
        let imported = try run(["transcripts", "import", bad.path])
        XCTAssertEqual(imported.status, 0, imported.stderr)
        XCTAssertTrue(imported.stdout.hasPrefix("Imported \(bad.path) as dddddddd.\n"), imported.stdout)
        XCTAssertTrue(imported.stdout.contains("migration-status lists it as imported later"), imported.stdout)

        var status = try run(["transcripts", "migration-status"])
        XCTAssertEqual(status.status, 0, status.stderr)
        XCTAssertTrue(status.stdout.contains(
            "Imported later with transcripts import (1):\n  \(bad.path): unreadable: "
        ), status.stdout)
        XCTAssertTrue(status.stdout.contains("; imported later as dddddddd-0000-4000-8000-000000000004 with transcribe transcripts import; the file was left in place"), status.stdout)
        XCTAssertFalse(status.stdout.contains("Skipped ("), status.stdout)
        XCTAssertTrue(status.stdout.contains("Conflicts (1):"), status.stdout)
        XCTAssertTrue(status.stdout.contains("transcribe transcripts import <path>"), "the conflict still needs a decision")

        // The conflict is the same recording as alpha: importing it replaces
        // alpha in place, keeping alpha's ID.
        let replaced = try run(["transcripts", "import", conflict.path])
        XCTAssertEqual(replaced.status, 0, replaced.stderr)
        XCTAssertTrue(replaced.stdout.contains("as aaaaaaaa, replacing the saved transcript of the same recording"), replaced.stdout)
        status = try run(["transcripts", "migration-status"])
        XCTAssertTrue(status.stdout.contains("Imported later with transcripts import (2):"), status.stdout)
        XCTAssertFalse(status.stdout.contains("Conflicts ("), status.stdout)
        XCTAssertFalse(status.stdout.contains("Files not imported"), status.stdout)

        // Both files stay where they are, are never archived, and are not
        // mistaken for files an older binary recreated.
        StateStore.closeShared()
        let database = try StateDatabase()
        let rows = try manifest(database)
        for url in [bad, conflict] {
            XCTAssertTrue(exists(url))
            XCTAssertEqual(row(rows, url)?.status, StateMigration.importedLaterStatus)
            XCTAssertNil(row(rows, url)?.archivedPath)
            XCTAssertFalse(rows.contains { $0.filePath == url.path && $0.isReappeared })
        }
        XCTAssertEqual(try CanonicalTranscriptStore.load(id: idA).basename, "dupe")
        let tsv = try String(contentsOf: archive.appendingPathComponent("MANIFEST.tsv"), encoding: .utf8)
        XCTAssertTrue(tsv.contains("\(bad.path)\t\(StateMigration.importedLaterStatus)\t\t"), tsv)
    }
}
