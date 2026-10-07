import Foundation
import XCTest
@testable import transcribe

/// Phase 5 of specs/sqlite-state-store.md: the `transcripts export-document`,
/// `import`, and `export-legacy` subcommands that make the boundary between
/// the state database and portable or 2.x JSON files explicit.
final class TranscriptPortabilityTests: XCTestCase {
    private var root: URL!
    private var previousState: String?

    override func setUpWithError() throws {
        previousState = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        root = FileManager.default.temporaryDirectory.appendingPathComponent("portability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("XDG_STATE_HOME", root.path, 1)
    }

    override func tearDownWithError() throws {
        StateStore.closeShared()
        if let previousState { setenv("XDG_STATE_HOME", previousState, 1) } else { unsetenv("XDG_STATE_HOME") }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private let idA = UUID(uuidString: "aaaaaaaa-1111-4000-8000-000000000001")!
    private let idB = UUID(uuidString: "bbbbbbbb-1111-4000-8000-000000000002")!

    private func hashes(_ characters: Character...) -> [String] {
        characters.map { String(repeating: String($0), count: 64) }.sorted()
    }

    /// Every optional populated and every scalar off its default, so a field
    /// an export forgets fails decoded equality.
    private func exhaustiveDocument(id: UUID, hashes sourceHashes: [String]) -> CanonicalTranscript {
        let recording = VoiceMemoOutputRecording(
            title: "Standup", titleSource: .customLabel, titleForSorting: "standup",
            recordedAt: "2026-01-02T03:04:05Z", durationSeconds: 61.5, uniqueID: "memo-id",
            path: "/memo/path.m4a", folderID: 3, flags: 1, audioDigestHex: "ABCDEF",
            enhancements: VoiceMemoEnhancements(
                audioFutureFlags: 1, sharedFlags: 2, silenceRemoverEnabled: true,
                skipSilenceEnabled: false, studioMixEnabled: true, studioMixLevel: 0.5
            )
        )
        let output = TranscriptionOutput(
            segments: [
                TranscriptSegment(speaker: "SPEAKER_0", start: 0, end: 1.5, text: "Hello",
                                  words: [WordSegment(word: "Hello", start: 0, end: 1.5)]),
                TranscriptSegment(speaker: "SPEAKER_1", start: 2, end: 3, text: "There", words: nil),
                TranscriptSegment(speaker: nil, start: 3, end: 3.25, text: "(music)", words: []),
            ],
            language: "de", durationSeconds: 3.333333333333333, diarizationEnabled: true,
            speakersDetected: 2, speakerStrategy: "segment", warnings: ["first warning", "second / warning"],
            speakerEmbeddings: ["SPEAKER_0": [0.1, -0.2, 3.4028235e38], "SPEAKER_1": [1.0e-7, 0.5, 0.25]]
        )
        return CanonicalTranscript(
            id: id,
            evidenceID: CanonicalTranscript.evidenceID(forSourceHashes: sourceHashes),
            sourceHashes: sourceHashes,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            model: "whisper-test", transcribeVersion: "2.7.0",
            audioPath: "/audio/meeting dir", audioFiles: ["part-1.m4a", "part-2.m4a"],
            basename: "meeting",
            sourceMetadata: OutputSourceMetadata(
                source: "voice_memos", recordedAt: "2026-01-02T03:04:05Z",
                recordingTitle: "Standup", voiceMemosUniqueID: "memo-id", voiceMemosPath: "/memo/path",
                voiceMemos: VoiceMemosOutputMetadata(sessionTitle: "Standup", recordingCount: 1, recordings: [recording])
            ),
            output: output,
            embeddingModelID: "model/with/slashes",
            speakerMatches: [
                "SPEAKER_0": SpeakerMatch(profileID: "p0", name: "Alice", distance: 0.125, margin: 0.3,
                                          confirmedExampleCount: 2, status: .confirmed),
                "SPEAKER_1": SpeakerMatch(profileID: "p1", name: "Bob", distance: 0.25, margin: nil,
                                          confirmedExampleCount: 1, status: .suggested),
            ],
            dismissedSpeakers: ["SPEAKER_1"],
            exports: [
                ExportRecord(path: "/notes/z.txt", format: "txt", sha256: String(repeating: "1", count: 64),
                             exportedAt: Date(timeIntervalSince1970: 1_700_000_300)),
                ExportRecord(path: "/notes/a.srt", format: "srt", sha256: String(repeating: "2", count: 64),
                             exportedAt: Date(timeIntervalSince1970: 1_700_000_100)),
            ]
        )
    }

    /// A plain rerun of the same recording: fresh ID, no decisions, no
    /// export records.
    private func plainDocument(id: UUID, hashes sourceHashes: [String], basename: String = "rerun") -> CanonicalTranscript {
        CanonicalTranscript(
            id: id,
            evidenceID: CanonicalTranscript.evidenceID(forSourceHashes: sourceHashes),
            sourceHashes: sourceHashes,
            createdAt: Date(timeIntervalSince1970: 1_710_000_000),
            model: "whisper-test", transcribeVersion: "3.0.0",
            audioPath: "/audio/\(basename).m4a", basename: basename,
            output: TranscriptionOutput(
                segments: [
                    TranscriptSegment(speaker: "SPEAKER_0", start: 0, end: 1, text: "Hi", words: nil),
                    TranscriptSegment(speaker: "SPEAKER_1", start: 1, end: 2, text: "Yo", words: nil),
                ],
                language: "en", durationSeconds: 2, diarizationEnabled: true, speakersDetected: 2,
                speakerEmbeddings: ["SPEAKER_0": [0.25, 0.75], "SPEAKER_1": [0.5, 0.5]]
            )
        )
    }

    private func portableFile(_ document: CanonicalTranscript, name: String) throws -> URL {
        let url = root.appendingPathComponent("files/\(name).transcript.json")
        _ = try CanonicalTranscriptStore.save(document, to: url)
        return url
    }

    private func transcripts(_ arguments: [String]) throws {
        try SpeakerCommands.transcripts(arguments)
    }

    private func assertFails(
        _ arguments: [String], exitCode: ExitCode, containing text: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try transcripts(arguments), file: file, line: line) { error in
            guard let error = error as? TranscribeError else {
                return XCTFail("unexpected error \(error)", file: file, line: line)
            }
            XCTAssertEqual(error.exitCode, exitCode, error.message, file: file, line: line)
            XCTAssertTrue(error.message.contains(text), error.message, file: file, line: line)
        }
    }

    private func mode(of url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func execute(_ sql: String, _ bindings: [SQLValue] = []) throws {
        try StateStore.withDatabase { database in
            try database.inTransaction(.write) { try database.execute(sql, bindings) }
        }
    }

    private func run(_ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CLITests.transcribePath)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_STATE_HOME"] = root.path
        environment["TRANSCRIBE_CONFIG"] = root.appendingPathComponent("missing-config.json").path
        environment["NO_COLOR"] = "1"
        environment["CLICOLOR_FORCE"] = nil
        process.environment = environment
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

    // MARK: - export-document

    func testExportDocumentWritesThePortableFileOfAStoredDocument() throws {
        let original = exhaustiveDocument(id: idA, hashes: hashes("a", "b"))
        try CanonicalTranscriptStore.saveManaged(original)
        let destination = root.appendingPathComponent("out/copy.transcript.json")

        try transcripts(["export-document", String(idA.uuidString.lowercased().prefix(8)), destination.path])

        let stored = try CanonicalTranscriptStore.load(id: idA)
        XCTAssertEqual(stored, original)
        XCTAssertEqual(try Data(contentsOf: destination), try CanonicalTranscriptStore.portableData(stored),
                       "exactly what a portable save writes")
        let exported = try CanonicalTranscriptStore.load(from: destination)
        XCTAssertEqual(exported, original, "every field round-trips, whole-second timestamps included")
        XCTAssertEqual(exported.exports?.map(\.exportedAt), original.exports?.map(\.exportedAt))
        XCTAssertEqual(try mode(of: destination), 0o600)

        // Importing the export back changes nothing.
        try transcripts(["import", destination.path])
        XCTAssertEqual(try CanonicalTranscriptStore.listing().map(\.id), [idA])
        XCTAssertEqual(try CanonicalTranscriptStore.load(id: idA), original)
    }

    func testExportDocumentRefusesAnExistingFileWithoutOverwrite() throws {
        try CanonicalTranscriptStore.saveManaged(exhaustiveDocument(id: idA, hashes: hashes("a")))
        let destination = root.appendingPathComponent("existing.transcript.json")
        try Data("keep me".utf8).write(to: destination)

        assertFails(["export-document", idA.uuidString, destination.path], exitCode: .outputWrite,
                    containing: "Output file already exists: \(destination.path). Use --overwrite to replace.")
        XCTAssertEqual(try Data(contentsOf: destination), Data("keep me".utf8))

        try transcripts(["export-document", idA.uuidString, destination.path, "--overwrite"])
        XCTAssertEqual(try CanonicalTranscriptStore.load(from: destination), try CanonicalTranscriptStore.load(id: idA))

        assertFails(["export-document", idA.uuidString, root.path], exitCode: .invalidUsage, containing: "is a directory")
        assertFails(["export-document", destination.path, root.appendingPathComponent("x.json").path],
                    exitCode: .invalidUsage, containing: "takes a saved document ID")
    }

    // MARK: - import

    func testImportStoresAFreshDocumentUnderItsOwnID() throws {
        let original = exhaustiveDocument(id: idA, hashes: hashes("a"))
        let file = try portableFile(original, name: "fresh")

        let result = try run(["transcripts", "import", file.path])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "Imported \(file.path) as \(idA.uuidString.lowercased()).\n")
        let listing = try run(["transcripts"])
        XCTAssertTrue(listing.stdout.contains("meeting\t\(idA.uuidString.lowercased())"), listing.stdout)
        XCTAssertEqual(try CanonicalTranscriptStore.load(id: idA), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".lock"), "import leaves no sidecar")
    }

    func testReimportOfTheSameRecordingReplacesAndCarriesDecisionsForward() throws {
        // The stored document: a confirmed SPEAKER_0, a dismissed SPEAKER_1,
        // and recorded exports.
        let stored = exhaustiveDocument(id: idA, hashes: hashes("a"))
        try CanonicalTranscriptStore.saveManaged(stored)
        // A rerun of the same audio exported elsewhere: new ID, no
        // decisions, no export records.
        let rerun = plainDocument(id: idB, hashes: hashes("a"))
        let file = try portableFile(rerun, name: "rerun")

        try transcripts(["import", file.path])

        XCTAssertEqual(try CanonicalTranscriptStore.listing().map(\.id), [idA], "replaced, adopting the stored ID")
        let imported = try CanonicalTranscriptStore.load(id: idA)
        XCTAssertEqual(imported.basename, "rerun")
        XCTAssertEqual(imported.output, rerun.output)
        XCTAssertEqual(imported.speakerMatches, ["SPEAKER_0": stored.speakerMatches["SPEAKER_0"]!],
                       "the confirmed match carries forward; the suggestion does not")
        XCTAssertEqual(imported.dismissedSpeakers, ["SPEAKER_1"])
        XCTAssertEqual(imported.exports, stored.exports, "nil incoming exports keep the recorded ones")

        // Incoming export records win over the stored ones.
        var withExports = rerun
        withExports.exports = []
        try transcripts(["import", try portableFile(withExports, name: "rerun-exports").path])
        XCTAssertEqual(try CanonicalTranscriptStore.load(id: idA).exports, [])
    }

    func testImportGivesAFreshIDWhenItsOwnBelongsToAnotherRecording() throws {
        try CanonicalTranscriptStore.saveManaged(exhaustiveDocument(id: idA, hashes: hashes("a")))
        let other = plainDocument(id: idA, hashes: hashes("c"), basename: "other")
        try transcripts(["import", try portableFile(other, name: "other").path])

        let listing = try CanonicalTranscriptStore.listing()
        XCTAssertEqual(listing.count, 2, "the stored document is not replaced by ID")
        XCTAssertEqual(try CanonicalTranscriptStore.load(id: idA).basename, "meeting")
        let newID = try XCTUnwrap(listing.compactMap(\.id).first { $0 != idA })
        XCTAssertEqual(try CanonicalTranscriptStore.load(id: newID).basename, "other")
    }

    func testImportRejectsMissingAndInvalidFiles() throws {
        assertFails(["import", root.appendingPathComponent("nope.transcript.json").path],
                    exitCode: .inputFile, containing: "No transcript file at")
        let bad = root.appendingPathComponent("bad.transcript.json")
        try Data("{".utf8).write(to: bad)
        assertFails(["import", bad.path], exitCode: .inputFile, containing: "Cannot read transcript")
        XCTAssertEqual(try CanonicalTranscriptStore.listing(), [])
    }

    // MARK: - export-legacy

    private struct LegacyProfileFile: Decodable, Equatable {
        let schemaVersion: Int
        let profiles: [SpeakerProfile]
        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case profiles
        }
    }

    private func timingLine(_ name: String) -> String {
        "{\"schema_version\":1,\"ended_at\":\"2026-05-28T12:00:00.000Z\",\"transcribe_version\":\"2.7.0\",\"model\":\"model-a\",\"diarization_enabled\":false,\"input_basename\":\"\(name)\",\"file_bytes\":1000,\"audio_duration_s\":10,\"segment_count\":1,\"speakers_detected\":null,\"audio_load_ms\":100,\"whisper_init_ms\":100,\"speaker_init_ms\":0,\"parallel_ms\":0,\"transcribe_only_ms\":1000,\"merge_ms\":0,\"write_outputs_ms\":10,\"total_ms\":1210,\"decoding_windows\":1}"
    }

    func testExportLegacyDumpsEveryStoreFaithfully() throws {
        let documents = [exhaustiveDocument(id: idA, hashes: hashes("a", "b")),
                         plainDocument(id: idB, hashes: hashes("c"))]
        for document in documents { try CanonicalTranscriptStore.saveManaged(document) }
        let evidence = documents[1].evidenceID
        _ = try SpeakerProfileStore.confirm(
            name: "Zed", profileID: nil, transcriptID: evidence, speakerID: "SPEAKER_0",
            embedding: [0.25, 0.75], modelID: "m", sourceHashes: hashes("c")
        )
        _ = try SpeakerProfileStore.confirm(
            name: "Amy", profileID: nil, transcriptID: evidence, speakerID: "SPEAKER_1",
            embedding: [0.5, 0.5], modelID: "m", sourceHashes: hashes("c")
        )
        // Verbatim rows, one with a field no binary knows and spacing no
        // encoder would produce.
        let processing = [
            "{\"source_id\":\"file:/a\",\"source_kind\":\"file\",\"completed_at\":\"2026-06-01T10:00:00Z\"}",
            "{ \"unknown_field\" : {\"nested\":[1,2.50]}, \"source_id\":\"file:/b\" }",
        ]
        for line in processing { try ProcessingStore.appendVerbatim(line: line) }
        let timing = [timingLine("one.wav"), timingLine("two.wav")]
        for line in timing { try TimingStore.appendVerbatim(line: line) }

        let out = root.appendingPathComponent("dump", isDirectory: true)
        try transcripts(["export-legacy", out.path])

        let transcriptsDirectory = out.appendingPathComponent("transcripts")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: transcriptsDirectory.path).sorted(),
            [idA, idB].map { "\($0.uuidString.lowercased()).transcript.json" }
        )
        for document in documents {
            let file = transcriptsDirectory.appendingPathComponent("\(document.id.uuidString.lowercased()).transcript.json")
            XCTAssertEqual(try CanonicalTranscriptStore.load(from: file), try CanonicalTranscriptStore.load(id: document.id))
            XCTAssertEqual(try mode(of: file), 0o600)
        }
        XCTAssertEqual(try CanonicalTranscriptStore.load(from: transcriptsDirectory
            .appendingPathComponent("\(idA.uuidString.lowercased()).transcript.json")), documents[0])

        let profiles = try JSONDecoder().decode(
            LegacyProfileFile.self, from: Data(contentsOf: out.appendingPathComponent("speaker_profiles.json"))
        )
        XCTAssertEqual(profiles.schemaVersion, 1)
        XCTAssertEqual(profiles.profiles.map(\.name), ["Zed", "Amy"], "confirmation order, as the 2.x store appended")
        XCTAssertEqual(profiles.profiles.sorted { $0.id < $1.id }, try SpeakerProfileStore.profiles())

        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("processing_history.jsonl")),
                       Data((processing.joined(separator: "\n") + "\n").utf8), "verbatim, in order")
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("timing_history.jsonl")),
                       Data((timing.joined(separator: "\n") + "\n").utf8))

        XCTAssertEqual(try mode(of: out), 0o700)
        XCTAssertEqual(try mode(of: transcriptsDirectory), 0o700)
        for name in ["speaker_profiles.json", "processing_history.jsonl", "timing_history.jsonl"] {
            XCTAssertEqual(try mode(of: out.appendingPathComponent(name)), 0o600, name)
        }
    }

    func testExportLegacyOfAnEmptyStateWritesEmptyButValidFiles() throws {
        let out = root.appendingPathComponent("empty-dump", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        try transcripts(["export-legacy", out.path])

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path).sorted(),
                       ["processing_history.jsonl", "speaker_profiles.json", "timing_history.jsonl", "transcripts"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent("transcripts").path), [])
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("processing_history.jsonl")), Data())
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("timing_history.jsonl")), Data())
        XCTAssertEqual(
            try JSONDecoder().decode(LegacyProfileFile.self, from: Data(contentsOf: out.appendingPathComponent("speaker_profiles.json"))),
            LegacyProfileFile(schemaVersion: 1, profiles: [])
        )
        XCTAssertEqual(try mode(of: out), 0o700, "an existing empty directory is made owner-only")
    }

    func testExportLegacyRefusesANonEmptyDestination() throws {
        try CanonicalTranscriptStore.saveManaged(exhaustiveDocument(id: idA, hashes: hashes("a")))
        let out = root.appendingPathComponent("busy", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        try Data().write(to: out.appendingPathComponent(".DS_Store"))

        assertFails(["export-legacy", out.path], exitCode: .outputWrite, containing: "is not empty")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [".DS_Store"])

        let file = root.appendingPathComponent("a-file")
        try Data().write(to: file)
        assertFails(["export-legacy", file.path], exitCode: .outputWrite, containing: "is not a directory")
    }

    func testExportLegacyErrorsOnStateItCannotRepresentAndWritesNothing() throws {
        try CanonicalTranscriptStore.saveManaged(exhaustiveDocument(id: idA, hashes: hashes("a")))
        try CanonicalTranscriptStore.saveManaged(plainDocument(id: idB, hashes: hashes("b")))
        // A payload encoding a future build might write, and a ledger row no
        // JSONL line can hold: both must be named, neither silently dropped.
        try execute("UPDATE document_segments SET encoding = 'zstd' WHERE document_id = ?",
                    [.text(idB.uuidString.lowercased())])
        try execute("INSERT INTO timing_history (recorded_at, model, diarization, record) VALUES ('', '', 0, ?)",
                    [.text("{\"a\":1}\n{\"b\":2}")])

        let out = root.appendingPathComponent("never", isDirectory: true)
        XCTAssertThrowsError(try transcripts(["export-legacy", out.path])) { error in
            let message = (error as? TranscribeError)?.message ?? "\(error)"
            XCTAssertEqual((error as? TranscribeError)?.exitCode, .inputFile)
            XCTAssertTrue(message.contains("document \(idB.uuidString.lowercased()): Invalid canonical transcript: unsupported segment encoding 'zstd'"), message)
            XCTAssertTrue(message.contains("timing_history.jsonl row 1: contains a line break"), message)
            XCTAssertFalse(message.contains(idA.uuidString.lowercased()), "readable documents are not listed")
            XCTAssertTrue(message.hasSuffix("Nothing was written."), message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path), "no partial dump")
    }

    private struct InjectedFailure: Error {}

    func testExportLegacyRemovesWhatItWroteWhenAWriteFails() throws {
        try CanonicalTranscriptStore.saveManaged(exhaustiveDocument(id: idA, hashes: hashes("a")))
        let snapshot = try LegacyExport.snapshot()
        defer { LegacyExport.beforePublish = nil }
        // The failure lands mid-dump: the document is already published.
        LegacyExport.beforePublish = { path in
            if path.hasSuffix("/processing_history.jsonl") { throw InjectedFailure() }
        }

        // An existing empty directory is not the export's: it stays, empty.
        let out = root.appendingPathComponent("partial", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: false)
        XCTAssertThrowsError(try LegacyExport.write(snapshot, to: out)) { error in
            XCTAssertTrue((error as? TranscribeError)?.message.contains("Everything the export created was removed.") ?? false, "\(error)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [])

        // Missing ancestors the export created go too, newest first.
        let fresh = root.appendingPathComponent("fresh", isDirectory: true)
        XCTAssertThrowsError(try LegacyExport.write(snapshot, to: fresh.appendingPathComponent("deeper/dump")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path), "created ancestors are removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), "a pre-existing ancestor stays")
    }

    /// A concurrent writer adds a file to the dump's `transcripts/` and
    /// creates a file at a name the dump is about to publish. The publish
    /// must not replace that file, and cleanup must remove only what the
    /// export created: the foreign files survive, and so do the directories
    /// holding them.
    func testExportLegacyNeverReplacesOrRemovesAConcurrentWritersFiles() throws {
        try CanonicalTranscriptStore.saveManaged(exhaustiveDocument(id: idA, hashes: hashes("a")))
        let snapshot = try LegacyExport.snapshot()
        let out = root.appendingPathComponent("raced", isDirectory: true)
        let foreignDocument = out.appendingPathComponent("transcripts/foreign.transcript.json")
        let foreignTiming = out.appendingPathComponent("timing_history.jsonl")
        defer { LegacyExport.beforePublish = nil }
        LegacyExport.beforePublish = { path in
            guard path == foreignTiming.path else { return }
            try Data("theirs".utf8).write(to: foreignDocument)
            try Data("theirs too".utf8).write(to: foreignTiming)
        }

        XCTAssertThrowsError(try LegacyExport.write(snapshot, to: out)) { error in
            let message = (error as? TranscribeError)?.message ?? "\(error)"
            XCTAssertTrue(message.contains("\(foreignTiming.path) was created by something else during the export and was left alone"), message)
            XCTAssertTrue(message.contains("which now hold other files"), message)
        }
        XCTAssertEqual(try Data(contentsOf: foreignTiming), Data("theirs too".utf8), "not replaced")
        XCTAssertEqual(try Data(contentsOf: foreignDocument), Data("theirs".utf8), "not removed")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path).sorted(),
                       ["timing_history.jsonl", "transcripts"], "only the export's own files were removed")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent("transcripts").path),
                       ["foreign.transcript.json"])
    }

    func testNoReplacePublishRefusesAFileCreatedAfterTheCheck() throws {
        let directory = root.appendingPathComponent("publish", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        let destination = directory.appendingPathComponent("copy.transcript.json")
        // The destination appears after export-document's existence check.
        try Data("theirs".utf8).write(to: destination)

        XCTAssertThrowsError(try publishPrivateFile(
            data: Data("ours".utf8), named: destination.lastPathComponent, inDirectory: fd,
            displayPath: destination.path, replace: false
        )) { XCTAssertTrue($0 is DestinationExistsError, "\($0)") }
        XCTAssertEqual(try Data(contentsOf: destination), Data("theirs".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [destination.lastPathComponent],
                       "no temporary file is left behind")

        // --overwrite publishes with a plain rename.
        try publishPrivateFile(
            data: Data("ours".utf8), named: destination.lastPathComponent, inDirectory: fd,
            displayPath: destination.path, replace: true
        )
        XCTAssertEqual(try Data(contentsOf: destination), Data("ours".utf8))
        XCTAssertEqual(try mode(of: destination), 0o600)
    }

    func testExportLegacyErrorsOnOrphanRowsInsteadOfOmittingThem() throws {
        try CanonicalTranscriptStore.saveManaged(exhaustiveDocument(id: idA, hashes: hashes("a")))
        // Only an outside edit with foreign keys off can leave an example
        // whose profile is gone; every reader skips it.
        try StateStore.withDatabase { database in
            try database.exec("PRAGMA foreign_keys = OFF")
            defer { try? database.exec("PRAGMA foreign_keys = ON") }
            try database.inTransaction(.write) {
                try database.execute(
                    """
                    INSERT INTO profile_examples (profile_id, transcript_id, speaker_id, model_id, vector, source_hashes)
                    VALUES ('ghost', 'sha256:x', 'SPEAKER_0', 'm', ?, '["x"]')
                    """,
                    [.blob(Float32Blob.encode([1, 0]))]
                )
            }
        }
        XCTAssertEqual(try SpeakerProfileStore.profiles(), [], "invisible to the store")

        let out = root.appendingPathComponent("orphans", isDirectory: true)
        XCTAssertThrowsError(try transcripts(["export-legacy", out.path])) { error in
            let message = (error as? TranscribeError)?.message ?? "\(error)"
            XCTAssertTrue(message.contains("profile_examples row 1: refers to a missing profiles row"), message)
            XCTAssertTrue(message.hasSuffix("Nothing was written."), message)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testCLIExportLegacyHappyPath() throws {
        try CanonicalTranscriptStore.saveManaged(exhaustiveDocument(id: idA, hashes: hashes("a")))
        try ProcessingStore.appendVerbatim(line: "{\"source_id\":\"file:/a\"}")
        StateStore.closeShared()
        let out = root.appendingPathComponent("cli-dump")
        let result = try run(["transcripts", "export-legacy", out.path])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "Exported 1 transcript, 0 speaker profiles, 1 processing history row, and 0 timing history rows as 2.x files to \(out.path).\n")
        XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("processing_history.jsonl")),
                       Data("{\"source_id\":\"file:/a\"}\n".utf8))

        let again = try run(["transcripts", "export-legacy", out.path])
        XCTAssertEqual(again.status, 5)
        XCTAssertTrue(again.stderr.contains("is not empty"), again.stderr)
    }
}
