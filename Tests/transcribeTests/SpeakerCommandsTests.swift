import CryptoKit
import Foundation
import XCTest
@testable import transcribe

final class SpeakerCommandsTests: XCTestCase {
    private var directory: URL!
    private var previousState: String?

    override func setUpWithError() throws {
        previousState = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("XDG_STATE_HOME", directory.path, 1)
    }

    override func tearDownWithError() throws {
        if let previousState { setenv("XDG_STATE_HOME", previousState, 1) }
        else { unsetenv("XDG_STATE_HOME") }
        try? FileManager.default.removeItem(at: directory)
    }

    private func document(_ name: String, hash: String) throws -> URL {
        let hashes = [String(repeating: hash, count: 64)]
        let result = CanonicalTranscript(
            evidenceID: CanonicalTranscript.evidenceID(forSourceHashes: hashes), sourceHashes: hashes,
            model: "intentionally-unavailable-model", transcribeVersion: Transcribe.version,
            audioPath: "/does/not/exist.wav", basename: "meeting",
            output: TranscriptionOutput(
                segments: [TranscriptSegment(speaker: "SPEAKER_0", start: 1, end: 3, text: "Hello world.", words: nil)],
                language: "en", durationSeconds: 4, diarizationEnabled: true, speakersDetected: 1,
                speakerEmbeddings: ["SPEAKER_0": [1, 0]]
            )
        )
        let url = directory.appendingPathComponent(name + ".transcript.json")
        _ = try CanonicalTranscriptStore.save(result, to: url)
        return url
    }

    private func run(
        _ args: [String], input: String? = nil, environment extra: [String: String] = [:],
        currentDirectory: URL? = nil
    ) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CLITests.transcribePath)
        process.arguments = args
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_STATE_HOME"] = directory.path
        environment["TRANSCRIBE_CONFIG"] = directory.appendingPathComponent("missing-config.json").path
        // The surrounding shell or CI may set color variables; drop them so
        // assertions about styled output hold everywhere. Tests opt back in
        // through `extra`.
        environment["NO_COLOR"] = nil
        environment["CLICOLOR_FORCE"] = nil
        for (key, value) in extra { environment[key] = value }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        // Replies fit comfortably in the pipe buffer, so write them up front;
        // closing signals end of input, which the session treats as quit.
        if let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
        }
        stdin.fileHandleForWriting.closeFile()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, text)
    }

    func testConfirmedIdentityCarriesAcrossIndependentDocumentsAndExports() throws {
        let one = try document("one", hash: "a")
        let two = try document("two", hash: "b")
        let three = try document("three", hash: "c")
        let confirm = try run(["speakers", "confirm", one.path, "SPEAKER_0", "--name", "Dave"])
        XCTAssertEqual(confirm.0, 0, confirm.1)
        let profileID = try XCTUnwrap(SpeakerProfileStore.profiles().first?.id)

        let before = try Data(contentsOf: two)
        let preview = try run(["speakers", "review", two.path])
        XCTAssertEqual(preview.0, 0, preview.1)
        XCTAssertTrue(preview.1.contains("suggested"))
        XCTAssertEqual(try Data(contentsOf: two), before, "review is read-only by default")

        let second = try run(["speakers", "confirm", two.path, "SPEAKER_0", "--profile", profileID])
        XCTAssertEqual(second.0, 0, second.1)
        let applied = try run(["speakers", "review", three.path, "--apply"])
        XCTAssertEqual(applied.0, 0, applied.1)
        XCTAssertTrue(applied.1.contains("automatic"))
        XCTAssertEqual(try CanonicalTranscriptStore.load(from: three).speakerMatches["SPEAKER_0"]?.status, .automatic)
        XCTAssertEqual(try SpeakerProfileStore.profiles().first?.examples.count, 2, "automatic match must not enroll")

        let out = directory.appendingPathComponent("exports")
        let exported = try run(["export", three.path, "--format", "all", "-o", out.path])
        XCTAssertEqual(exported.0, 0, exported.1)
        XCTAssertTrue(try String(contentsOf: out.appendingPathComponent("meeting.txt")).contains("Dave"))
        let json = try String(contentsOf: out.appendingPathComponent("meeting.json"))
        XCTAssertTrue(json.contains("Dave"))
        XCTAssertFalse(json.contains("speakerEmbeddings"))
        XCTAssertFalse(try String(contentsOf: out.appendingPathComponent("meeting.tsv")).contains("Dave"))
        let repeated = try run(["export", three.path, "--format", "txt", "-o", out.path])
        XCTAssertEqual(repeated.0, 5, repeated.1)
    }

    func testCopyAndRedoOfSameSourceDoNotInflateSupport() throws {
        let one = try document("one", hash: "a")
        let repeated = try document("redo", hash: "a")
        XCTAssertEqual(try run(["speakers", "confirm", one.path, "SPEAKER_0", "--name", "Dave"]).0, 0)
        XCTAssertEqual(try run(["speakers", "confirm", repeated.path, "SPEAKER_0", "--name", "Dave"]).0, 0)
        XCTAssertEqual(try SpeakerProfileStore.profiles().count, 1)
        XCTAssertEqual(try SpeakerProfileStore.profiles().first?.examples.count, 1)
        let fresh = try document("fresh", hash: "b")
        XCTAssertTrue(try run(["speakers", "review", fresh.path]).1.contains("suggested"))
    }

    func testCorrectClearRenameAndDelete() throws {
        let one = try document("one", hash: "a")
        XCTAssertEqual(try run(["speakers", "confirm", one.path, "SPEAKER_0", "--name", "Dave"]).0, 0)
        XCTAssertEqual(try run(["speakers", "confirm", one.path, "SPEAKER_0", "--name", "Jane"]).0, 0)
        let jane = try XCTUnwrap(SpeakerProfileStore.profiles().first { $0.name == "Jane" })
        XCTAssertEqual(try CanonicalTranscriptStore.load(from: one).speakerMatches["SPEAKER_0"]?.name, "Jane")
        XCTAssertEqual(try run(["speakers", "rename", jane.id, "Janet"]).0, 0)
        XCTAssertEqual(try run(["speakers", "review", one.path, "--apply"]).0, 0)
        XCTAssertEqual(try CanonicalTranscriptStore.load(from: one).speakerMatches["SPEAKER_0"]?.name, "Janet")
        XCTAssertEqual(try run(["speakers", "clear", one.path, "SPEAKER_0"]).0, 0)
        XCTAssertNil(try CanonicalTranscriptStore.load(from: one).speakerMatches["SPEAKER_0"])
        XCTAssertEqual(try SpeakerProfileStore.profiles().first { $0.id == jane.id }?.examples.count, 0)
        XCTAssertEqual(try run(["speakers", "delete", jane.id]).0, 0)
    }

    func testSpeakerIDAcceptsABareNumberAndAnyCase() throws {
        let one = try document("one", hash: "a")
        let confirm = try run(["speakers", "confirm", one.path, "0", "--name", "Dave"])
        XCTAssertEqual(confirm.0, 0, confirm.1)
        XCTAssertEqual(try CanonicalTranscriptStore.load(from: one).speakerMatches["SPEAKER_0"]?.name, "Dave")
        let cleared = try run(["speakers", "clear", one.path, "speaker_0"])
        XCTAssertEqual(cleared.0, 0, cleared.1)
        XCTAssertTrue(cleared.1.contains("Cleared SPEAKER_0."), cleared.1)
        XCTAssertNil(try CanonicalTranscriptStore.load(from: one).speakerMatches["SPEAKER_0"])
    }

    func testUnknownSpeakerListsTheDocumentsSpeakers() throws {
        let one = try document("one", hash: "a")
        XCTAssertEqual(try run(["speakers", "confirm", one.path, "SPEAKER_0", "--name", "Dave"]).0, 0)
        let cleared = try run(["speakers", "clear", one.path, "SPEAKER_7"])
        XCTAssertEqual(cleared.0, 2, cleared.1)
        XCTAssertTrue(cleared.1.contains("Speakers in this transcript: SPEAKER_0 (Dave, confirmed)."), cleared.1)
        let confirmed = try run(["speakers", "confirm", one.path, "SPEAKER_7", "--name", "Jane"])
        XCTAssertEqual(confirmed.0, 2, confirmed.1)
        XCTAssertTrue(confirmed.1.contains("Speakers in this transcript: SPEAKER_0"), confirmed.1)
    }

    /// The saved-transcript directory lives under "Application Support", so an
    /// unquoted path reaches the command as several arguments.
    func testUnquotedPathWithSpacesSuggestsQuoting() throws {
        let spaced = directory.appendingPathComponent("Application Support", isDirectory: true)
        try FileManager.default.createDirectory(at: spaced, withIntermediateDirectories: true)
        let target = spaced.appendingPathComponent("one.transcript.json")
        try FileManager.default.moveItem(at: try document("one", hash: "a"), to: target)
        let pieces = target.path.components(separatedBy: " ")
        try XCTSkipUnless(pieces.count == 2, "temporary directory path already contains spaces")

        let tooMany = try run(["speakers", "clear"] + pieces + ["SPEAKER_0"])
        XCTAssertEqual(tooMany.0, 2, tooMany.1)
        XCTAssertTrue(tooMany.1.contains("quote it: '\(target.path)'"), tooMany.1)

        // A stray file at the first fragment used to surface only as a bare
        // JSON decoding error.
        XCTAssertTrue(FileManager.default.createFile(atPath: pieces[0], contents: Data()))
        let stray = try run(["speakers", "clear"] + pieces)
        XCTAssertEqual(stray.0, 3, stray.1)
        // The command resolves symlinked temporary directories, so match the name.
        XCTAssertTrue(stray.1.contains("Cannot read transcript ") && stray.1.contains("/Application: "), stray.1)
        XCTAssertTrue(stray.1.contains("quote it: '\(target.path)'"), stray.1)

        let missing = try run(["inspect", directory.appendingPathComponent("absent.transcript.json").path])
        XCTAssertEqual(missing.0, 3, missing.1)
        XCTAssertTrue(missing.1.contains("No transcript at"), missing.1)
    }

    func testExportCannotOverwriteCanonicalInput() throws {
        let one = try document("one", hash: "a")
        let before = try Data(contentsOf: one)
        let result = try run(["export", one.path, "--format", "json", "-o", directory.path,
                              "--output-prefix", "one.transcript", "--overwrite"])
        XCTAssertEqual(result.0, 2)
        XCTAssertEqual(try Data(contentsOf: one), before)
    }

    func testExportCannotOverwriteCanonicalInputThroughACaseFlippedPrefix() throws {
        let one = try document("one", hash: "a")
        try XCTSkipUnless(volumeIsCaseInsensitive(), "case-sensitive volume keeps the two names distinct")
        let before = try Data(contentsOf: one)
        let result = try run(["export", one.path, "--format", "json", "-o", directory.path,
                              "--output-prefix", "One.transcript", "--overwrite"])
        XCTAssertEqual(result.0, 2, result.1)
        XCTAssertEqual(try Data(contentsOf: one), before)
    }

    func testExportRejectsAnEmptyOutputPrefix() throws {
        let one = try document("one", hash: "a")
        let out = directory.appendingPathComponent("empty-prefix")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let result = try run(["export", one.path, "--format", "txt,json", "-o", out.path, "--output-prefix", ""])
        XCTAssertEqual(result.0, 2, result.1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [])
    }

    func testUnreadableTranscriptDoesNotHideTheListing() throws {
        let (_, good) = try managedDocument(hash: "a")
        let (_, damaged) = try managedDocument(hash: "b")
        try StateStore.withDatabase { database in
            try database.inTransaction(.write) {
                try database.execute("UPDATE documents SET basename = '' WHERE id = ?", [.text(damaged)])
            }
        }

        let list = try run(["transcripts"])
        XCTAssertEqual(list.0, 0, list.1)
        let lines = list.1.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains { $0.hasPrefix(String(good.prefix(8))) && $0.hasSuffix("meeting") }, list.1)
        XCTAssertTrue(lines.contains { $0.hasPrefix(String(damaged.prefix(8))) && $0.contains("(unreadable)") }, list.1)
    }

    /// A held document lock must stop a second command from starting its own
    /// load-modify-save, which is what keeps concurrent confirmations from
    /// dropping one another.
    func testDocumentLockBlocksASecondSpeakerCommand() throws {
        try assertDocumentLockBlocksConfirmation(useSymlink: false)
    }

    func testSymlinkConfirmationUsesTargetLockAndPreservesLink() throws {
        try assertDocumentLockBlocksConfirmation(useSymlink: true)
    }

    private func assertDocumentLockBlocksConfirmation(useSymlink: Bool) throws {
        let one = try document("one", hash: "a")
        let input: URL
        if useSymlink {
            input = directory.appendingPathComponent("alias.transcript.json")
            try FileManager.default.createSymbolicLink(at: input, withDestinationURL: one)
        } else {
            input = one
        }
        let lock = one.appendingPathExtension("lock")
        let fd = open(lock.path, O_CREAT | O_RDWR, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX), 0)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: CLITests.transcribePath)
        process.arguments = ["speakers", "confirm", input.path, "SPEAKER_0", "--name", "Dave"]
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_STATE_HOME"] = directory.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(process.isRunning, "confirm must wait for the document lock")

        _ = flock(fd, LOCK_UN)
        close(fd)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try CanonicalTranscriptStore.load(from: one).speakerMatches["SPEAKER_0"]?.name, "Dave")
        if useSymlink {
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: input.path), one.path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: input.appendingPathExtension("lock").path))
            XCTAssertEqual(try run(["speakers", "review", input.path, "--apply"]).0, 0)
            XCTAssertEqual(try run(["speakers", "clear", input.path, "SPEAKER_0"]).0, 0)
            XCTAssertTrue(try CanonicalTranscriptStore.load(from: one).speakerMatches.isEmpty)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: input.path), one.path)
        }
    }

    private func volumeIsCaseInsensitive() -> Bool {
        let probe = directory.appendingPathComponent("CaseProbe")
        guard (try? Data().write(to: probe)) != nil else { return false }
        defer { try? FileManager.default.removeItem(at: probe) }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("caseprobe").path)
    }

    func testInspectAndListExposeNoEmbeddings() throws {
        let one = try document("one", hash: "a")
        let original = try CanonicalTranscriptStore.load(from: one)
        let id = try CanonicalTranscriptStore.saveManaged(original)
        let list = try run(["transcripts"])
        XCTAssertEqual(list.0, 0, list.1)
        let listLines = list.1.split(separator: "\n").map(String.init)
        XCTAssertEqual(listLines.count, 2, "header and one row: \(list.1)")
        XCTAssertTrue(listLines[0].hasPrefix("ID"), list.1)
        XCTAssertTrue(listLines[1].hasPrefix(String(id.uuidString.lowercased().prefix(8)) + "  "), list.1)
        XCTAssertTrue(listLines[1].hasSuffix("meeting"), list.1)
        XCTAssertFalse(list.1.contains(one.path), "title and ID only, no path")
        let inspect = try run(["inspect", one.path])
        XCTAssertEqual(inspect.0, 0, inspect.1)
        XCTAssertTrue(inspect.1.contains("SPEAKER_0"))
        XCTAssertFalse(inspect.1.contains("speakerEmbeddings"))
        XCTAssertEqual(try run(["speakers", "confirm", one.path, "MISSING", "--name", "Dave"]).0, 2)
        XCTAssertTrue(try SpeakerProfileStore.profiles().isEmpty)
    }

    func testConcurrentConfirmationsPreserveBothProfiles() throws {
        let one = try document("one", hash: "a")
        let two = try document("two", hash: "b")
        let processes = [("Alice", one), ("Bob", two)].map { name, url -> Process in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: CLITests.transcribePath)
            process.arguments = ["speakers", "confirm", url.path, "SPEAKER_0", "--name", name]
            process.environment = ProcessInfo.processInfo.environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            return process
        }
        for process in processes { try process.run() }
        for process in processes {
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        XCTAssertEqual(Set(try SpeakerProfileStore.profiles().map(\.name)), ["Alice", "Bob"])
    }

    func testInteractiveReviewConfirmsFromPipedReplies() throws {
        let one = try document("one", hash: "a")
        let result = try run(["speakers", "review", one.path, "--interactive"], input: "Dave\n")
        XCTAssertEqual(result.0, 0, result.1)
        XCTAssertTrue(result.1.contains("Hello world."), "shows a speech sample")
        XCTAssertTrue(result.1.contains("Confirmed SPEAKER_0 as Dave"), result.1)
        XCTAssertEqual(try CanonicalTranscriptStore.load(from: one).speakerMatches["SPEAKER_0"]?.status, .confirmed)
        XCTAssertEqual(try SpeakerProfileStore.profiles().map(\.name), ["Dave"])
    }

    func testReviewOnPipesKeepsTheReadOnlyTable() throws {
        let one = try document("one", hash: "a")
        let before = try Data(contentsOf: one)
        let result = try run(["speakers", "review", one.path], input: "Dave\n")
        XCTAssertEqual(result.0, 0, result.1)
        XCTAssertTrue(result.1.contains("SPEAKER_0\tunidentified"), result.1)
        XCTAssertEqual(try Data(contentsOf: one), before, "piped review must not prompt or write")
        XCTAssertTrue(try SpeakerProfileStore.profiles().isEmpty)
    }

    func testReviewWithoutTranscriptSpansAllSavedDocuments() throws {
        let one = try CanonicalTranscriptStore.saveManaged(CanonicalTranscriptStore.load(from: document("one", hash: "a")))
        let table = try run(["speakers", "review"])
        XCTAssertEqual(table.0, 0, table.1)
        // The header names the document by ID; managed documents have no path.
        XCTAssertTrue(table.1.contains("meeting\t\(String(one.uuidString.lowercased().prefix(8)))\n"), table.1)
        XCTAssertTrue(table.1.contains("SPEAKER_0\tunidentified"), table.1)

        let interactive = try run(["speakers", "review", "--interactive"], input: "Dave\n")
        XCTAssertEqual(interactive.0, 0, interactive.1)
        XCTAssertTrue(interactive.1.contains("Confirmed SPEAKER_0 as Dave"), interactive.1)
        XCTAssertEqual(try CanonicalTranscriptStore.load(id: one).speakerMatches["SPEAKER_0"]?.name, "Dave")

        let settled = try run(["speakers", "review", "--interactive"], input: "")
        XCTAssertEqual(settled.0, 0, settled.1)
        XCTAssertTrue(settled.1.contains("run with --all to revisit"), settled.1)
    }

    func testDismissalThroughTheCLISurvivesUntilCleared() throws {
        let one = try document("one", hash: "a")
        let dismissed = try run(["speakers", "review", one.path, "--interactive"], input: "u\n")
        XCTAssertEqual(dismissed.0, 0, dismissed.1)
        XCTAssertTrue(dismissed.1.contains("Marked SPEAKER_0 as unidentifiable"), dismissed.1)
        XCTAssertEqual(try CanonicalTranscriptStore.load(from: one).dismissedSpeakers, ["SPEAKER_0"])

        let table = try run(["speakers", "review", one.path])
        XCTAssertTrue(table.1.contains("SPEAKER_0\tdismissed"), table.1)
        let settled = try run(["speakers", "review", one.path, "--interactive"], input: "Dave\n")
        XCTAssertEqual(settled.0, 0, settled.1)
        XCTAssertTrue(settled.1.contains("marked unidentifiable; run with --all"), settled.1)
        XCTAssertNil(try CanonicalTranscriptStore.load(from: one).speakerMatches["SPEAKER_0"], "a settled session must not prompt")

        let cleared = try run(["speakers", "clear", one.path, "SPEAKER_0"])
        XCTAssertEqual(cleared.0, 0, cleared.1)
        XCTAssertNil(try CanonicalTranscriptStore.load(from: one).dismissedSpeakers)
        let prompted = try run(["speakers", "review", one.path, "--interactive"], input: "Dave\n")
        XCTAssertTrue(prompted.1.contains("Confirmed SPEAKER_0 as Dave"), "clear makes the speaker promptable again")
    }

    func testManagedConfirmSaveFailureKeepsOutputWriteExitAndRollsBack() throws {
        let (uuid, id) = try managedDocument(hash: "a")
        // The trigger lives in the shared database file, so the CLI process
        // hits it when its confirm transaction inserts the match row.
        try StateStore.withDatabase { database in
            try database.exec(
                "CREATE TRIGGER reject_matches BEFORE INSERT ON speaker_matches BEGIN SELECT RAISE(ABORT, 'injected failure'); END"
            )
        }
        let confirm = try run(["speakers", "confirm", id, "SPEAKER_0", "--name", "Dave"])
        XCTAssertEqual(confirm.0, 5, "a failed managed save is an output-write failure, not a generic one: \(confirm.1)")
        XCTAssertTrue(confirm.1.contains("nothing was saved"), confirm.1)
        XCTAssertTrue(try SpeakerProfileStore.profiles().isEmpty, "the profile change rolls back with the document")
        XCTAssertNil(try CanonicalTranscriptStore.load(id: uuid).speakerMatches["SPEAKER_0"])
    }

    func testInvalidStoredSpeakerStateFailsInspectAsInputError() throws {
        let (uuid, id) = try managedDocument(hash: "a")
        // A zero vector is exactly what a full load rejects; the payload-free
        // summary must reject it too rather than quietly succeeding.
        try StateStore.withDatabase { database in
            try database.inTransaction(.write) {
                try database.execute(
                    "UPDATE document_embeddings SET vector = ? WHERE document_id = ?",
                    [.blob(Float32Blob.encode([0, 0])), .text(uuid.uuidString.lowercased())]
                )
            }
        }
        let inspect = try run(["inspect", id])
        XCTAssertEqual(inspect.0, 3, inspect.1)
        XCTAssertTrue(inspect.1.contains("Cannot read transcript"), inspect.1)
    }

    func testMalformedDocumentIDRowDoesNotHideTheListing() throws {
        _ = try managedDocument(hash: "a")
        try StateStore.withDatabase { database in
            try database.inTransaction(.write) {
                try database.execute(
                    """
                    INSERT INTO documents (id, evidence_id, source_hashes, created_at, model,
                      transcribe_version, audio_path, basename, embedding_model_id,
                      duration_seconds, diarization_enabled, speaker_strategy, warnings,
                      segment_count, segment_speakers, exports_recorded, updated_at)
                    VALUES ('not-a-uuid', 'sha256:junk', '[]', 't', 'm', 'v', '/a', 'broken',
                      'e', 1, 0, 's', '[]', 0, '[]', 0, 't')
                    """
                )
            }
        }
        let list = try run(["transcripts"])
        XCTAssertEqual(list.0, 0, list.1)
        XCTAssertTrue(list.1.contains("meeting"), "healthy rows still list: \(list.1)")
        XCTAssertTrue(
            list.1.split(separator: "\n").contains { $0.hasPrefix("not-a-uu") && $0.contains("(unreadable)") },
            list.1
        )
    }

    func testReviewFlagValidation() throws {
        let one = try document("one", hash: "a")
        XCTAssertEqual(try run(["speakers", "review", one.path, "--apply", "--interactive"]).0, 2)
        XCTAssertEqual(try run(["speakers", "review", "--apply"]).0, 2, "--apply needs a transcript")
    }

    // MARK: - Export refresh

    func testExportSeedsRecordsInTheCanonicalDocument() throws {
        let one = try document("one", hash: "a")
        let out = directory.appendingPathComponent("seeded")
        let exported = try run(["export", one.path, "--format", "txt,srt", "-o", out.path])
        XCTAssertEqual(exported.0, 0, exported.1)

        let records = try XCTUnwrap(CanonicalTranscriptStore.load(from: one).exports)
        XCTAssertEqual(Set(records.map(\.format)), ["txt", "srt"])
        for record in records {
            XCTAssertEqual((record.path as NSString).deletingLastPathComponent, out.resolvingSymlinksInPath().path)
            let bytes = try Data(contentsOf: URL(fileURLWithPath: record.path))
            XCTAssertEqual(record.sha256, sha256Hex(bytes), "recorded hash matches the written file")
        }
    }

    func testConfirmRefreshesRecordedExports() throws {
        let one = try document("one", hash: "a")
        let out = directory.appendingPathComponent("refreshed")
        XCTAssertEqual(try run(["export", one.path, "--format", "txt,srt", "-o", out.path]).0, 0)
        XCTAssertTrue(try String(contentsOf: out.appendingPathComponent("meeting.txt")).contains("SPEAKER_0"))

        let confirm = try run(["speakers", "confirm", one.path, "SPEAKER_0", "--name", "Dave"])
        XCTAssertEqual(confirm.0, 0, confirm.1)
        XCTAssertTrue(confirm.1.contains("Refreshed 2 exports"), confirm.1)
        XCTAssertFalse(confirm.1.contains("Export again to update rendered files."), confirm.1)
        XCTAssertTrue(try String(contentsOf: out.appendingPathComponent("meeting.txt")).contains("Dave"))
        XCTAssertTrue(try String(contentsOf: out.appendingPathComponent("meeting.srt")).contains("Dave"))
    }

    func testNoRefreshExportsLeavesFilesAndKeepsTheHint() throws {
        let one = try document("one", hash: "a")
        let out = directory.appendingPathComponent("disabled")
        XCTAssertEqual(try run(["export", one.path, "--format", "txt", "-o", out.path]).0, 0)

        let confirm = try run(["speakers", "confirm", one.path, "SPEAKER_0", "--name", "Dave", "--no-refresh-exports"])
        XCTAssertEqual(confirm.0, 0, confirm.1)
        XCTAssertTrue(confirm.1.contains("Export again to update rendered files."), confirm.1)
        XCTAssertFalse(try String(contentsOf: out.appendingPathComponent("meeting.txt")).contains("Dave"))

        let environment = try run(
            ["speakers", "confirm", one.path, "SPEAKER_0", "--name", "Dave"],
            environment: ["TRANSCRIBE_REFRESH_EXPORTS": "0"]
        )
        XCTAssertEqual(environment.0, 0, environment.1)
        XCTAssertFalse(try String(contentsOf: out.appendingPathComponent("meeting.txt")).contains("Dave"), "environment variable disables refresh")
    }

    func testLocallyModifiedExportSurvivesConfirmation() throws {
        let one = try document("one", hash: "a")
        let out = directory.appendingPathComponent("edited")
        XCTAssertEqual(try run(["export", one.path, "--format", "txt", "-o", out.path]).0, 0)
        let txt = out.appendingPathComponent("meeting.txt")
        let edited = "my careful manual edits\n"
        try Data(edited.utf8).write(to: txt)

        let confirm = try run(["speakers", "confirm", one.path, "SPEAKER_0", "--name", "Dave"])
        XCTAssertEqual(confirm.0, 0, confirm.1)
        XCTAssertTrue(confirm.1.contains("locally modified"), confirm.1)
        XCTAssertEqual(try String(contentsOf: txt), edited, "edited export must not be overwritten")
    }

    func testConfirmOnRecordlessDocumentKeepsTheLegacyHint() throws {
        let one = try document("one", hash: "a")
        let confirm = try run(["speakers", "confirm", one.path, "SPEAKER_0", "--name", "Dave"])
        XCTAssertEqual(confirm.0, 0, confirm.1)
        XCTAssertTrue(confirm.1.contains("Export again to update rendered files."), confirm.1)
    }

    func testExportRefreshCommandRewritesStaleFiles() throws {
        let one = try document("one", hash: "a")
        let out = directory.appendingPathComponent("manual")
        XCTAssertEqual(try run(["export", one.path, "--format", "txt", "-o", out.path]).0, 0)
        XCTAssertEqual(try run(["speakers", "confirm", one.path, "SPEAKER_0", "--name", "Dave", "--no-refresh-exports"]).0, 0)
        XCTAssertFalse(try String(contentsOf: out.appendingPathComponent("meeting.txt")).contains("Dave"))

        let refresh = try run(["export", one.path, "--refresh"])
        XCTAssertEqual(refresh.0, 0, refresh.1)
        XCTAssertTrue(refresh.1.contains("Refreshed 1 export"), refresh.1)
        XCTAssertTrue(try String(contentsOf: out.appendingPathComponent("meeting.txt")).contains("Dave"))

        let repeated = try run(["export", one.path, "--refresh"])
        XCTAssertEqual(repeated.0, 0, repeated.1)
        XCTAssertFalse(repeated.1.contains("Refreshed"), "an up-to-date document refreshes quietly")
    }

    func testExportRefreshRejectsRenderOptionsAndExportNeedsATranscript() throws {
        let one = try document("one", hash: "a")
        XCTAssertEqual(try run(["export", one.path, "--refresh", "--format", "txt"]).0, 2)
        XCTAssertEqual(try run(["export", one.path, "--refresh", "-o", directory.path]).0, 2)
        XCTAssertEqual(try run(["export", one.path, "--refresh", "--overwrite"]).0, 2)
        let missing = try run(["export"])
        XCTAssertEqual(missing.0, 2, missing.1)
        XCTAssertTrue(missing.1.contains("Missing transcript path"), missing.1)
    }

    // MARK: - Transcript ID arguments

    /// Saves a document into the managed store and returns its UUID and the
    /// lowercased ID string commands accept.
    private func managedDocument(hash: String, id: UUID = UUID()) throws -> (uuid: UUID, id: String) {
        let portable = try CanonicalTranscriptStore.load(from: document("managed-\(hash)", hash: hash))
        let document = CanonicalTranscript(
            id: id, evidenceID: portable.evidenceID, sourceHashes: portable.sourceHashes,
            createdAt: portable.createdAt, model: portable.model,
            transcribeVersion: portable.transcribeVersion, audioPath: portable.audioPath,
            basename: portable.basename, output: portable.output
        )
        let saved = try CanonicalTranscriptStore.saveManaged(document)
        return (saved, saved.uuidString.lowercased())
    }

    func testTranscriptArgumentsAcceptSavedDocumentIDs() throws {
        let (uuid, id) = try managedDocument(hash: "a")

        let list = try run(["transcripts"])
        XCTAssertEqual(list.0, 0, list.1)
        XCTAssertTrue(
            list.1.split(separator: "\n").contains { $0.hasPrefix(String(id.prefix(8)) + "  ") },
            "listing shows the shortened ID column: \(list.1)"
        )

        let inspect = try run(["inspect", String(id.prefix(8))])
        XCTAssertEqual(inspect.0, 0, inspect.1)
        XCTAssertTrue(inspect.1.contains("SPEAKER_0"), inspect.1)
        XCTAssertTrue(inspect.1.contains("Segments: 1"), inspect.1)

        let confirm = try run(["speakers", "confirm", id, "0", "--name", "Dave"])
        XCTAssertEqual(confirm.0, 0, confirm.1)
        XCTAssertEqual(try CanonicalTranscriptStore.load(id: uuid).speakerMatches["SPEAKER_0"]?.name, "Dave")

        let clear = try run(["speakers", "clear", String(id.prefix(12)), "SPEAKER_0"])
        XCTAssertEqual(clear.0, 0, clear.1)
        XCTAssertNil(try CanonicalTranscriptStore.load(id: uuid).speakerMatches["SPEAKER_0"])
        XCTAssertEqual(try SpeakerProfileStore.profiles().first?.examples.count, 0)

        // The 2.x listing printed IDs with the file suffix; that spelling
        // still resolves by ID.
        let suffixed = try run(["inspect", id + ".transcript.json"])
        XCTAssertEqual(suffixed.0, 0, suffixed.1)
    }

    func testUnknownAndAmbiguousTranscriptIDsAreRejected() throws {
        let (_, id) = try managedDocument(hash: "a")

        let unknown = try run(["speakers", "clear", "deadbeef", "0"])
        XCTAssertEqual(unknown.0, 3, unknown.1)
        XCTAssertTrue(unknown.1.contains("no saved transcript ID starts with it"), unknown.1)

        // A second document whose ID shares the first eight characters makes
        // that prefix ambiguous.
        let flipped = id[id.index(id.startIndex, offsetBy: 9)] == "0" ? "1" : "0"
        var otherID = id
        otherID.replaceSubrange(
            otherID.index(otherID.startIndex, offsetBy: 9)...otherID.index(otherID.startIndex, offsetBy: 9),
            with: flipped
        )
        _ = try managedDocument(hash: "b", id: try XCTUnwrap(UUID(uuidString: otherID)))
        let ambiguous = try run(["inspect", String(id.prefix(8))])
        XCTAssertEqual(ambiguous.0, 2, ambiguous.1)
        XCTAssertTrue(ambiguous.1.contains("ambiguous"), ambiguous.1)
        XCTAssertTrue(ambiguous.1.contains(otherID), ambiguous.1)

        let full = try run(["inspect", id])
        XCTAssertEqual(full.0, 0, "the full ID stays unambiguous: \(full.1)")
    }

    /// Listings print shortened IDs for pasting back, so a same-named file in
    /// the working directory must not capture the argument; `./` still
    /// reaches the file.
    func testUniqueSavedIDTakesPrecedenceOverSameNamedFile() throws {
        let (_, id) = try managedDocument(hash: "a")
        let short = String(id.prefix(8))
        let cwd = directory.appendingPathComponent("cwd")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try Data("not a transcript\n".utf8).write(to: cwd.appendingPathComponent(short))

        let byID = try run(["inspect", short], currentDirectory: cwd)
        XCTAssertEqual(byID.0, 0, byID.1)
        XCTAssertTrue(byID.1.contains("Segments: 1"), byID.1)
        XCTAssertTrue(byID.1.contains("Transcript: \(short)\n"), byID.1)
        XCTAssertTrue(byID.1.contains("was read as saved document \(short)"), byID.1)
        XCTAssertTrue(byID.1.contains("./\(short)"), byID.1)

        let byPath = try run(["inspect", "./" + short], currentDirectory: cwd)
        XCTAssertEqual(byPath.0, 3, byPath.1)
        XCTAssertTrue(byPath.1.contains("Cannot read transcript"), byPath.1)
        XCTAssertFalse(byPath.1.contains("was read as saved document"), byPath.1)
    }

    /// An ID-shaped name that matches no saved document keeps reading the
    /// file, with no warning.
    func testUnmatchedIDShapedFileNameStillReadsTheFile() throws {
        _ = try managedDocument(hash: "a", id: try XCTUnwrap(UUID(uuidString: "aaaaaaaa-0000-4000-8000-000000000000")))
        let cwd = directory.appendingPathComponent("cwd")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let source = try document("portable", hash: "b")
        let name = "deadbeef"
        try FileManager.default.copyItem(at: source, to: cwd.appendingPathComponent(name))

        let result = try run(["inspect", name], currentDirectory: cwd)
        XCTAssertEqual(result.0, 0, result.1)
        XCTAssertTrue(result.1.contains("Segments: 1"), result.1)
        XCTAssertFalse(result.1.contains("was read as saved document"), result.1)
        // A portable file's ID is not abbreviated: that would open the store.
        let portableID = try CanonicalTranscriptStore.load(from: source).id.uuidString.lowercased()
        XCTAssertTrue(result.1.contains("Transcript: \(portableID)\n"), result.1)
    }

    /// The shadow lookup behind a bare ID-shaped file argument must not run
    /// the database's startup phases: here a normal open would import the
    /// recreated 2.x ledger and move it to migrated-v1/.
    func testShadowLookupLeavesTheStateDirectoryUntouched() throws {
        let stored = try XCTUnwrap(UUID(uuidString: "aaaaaaaa-0000-4000-8000-000000000000"))
        _ = try managedDocument(hash: "a", id: stored)
        StateStore.closeShared()
        let state = try StatePaths.stateDirectoryURL()
        let ledger = state.appendingPathComponent("processing_history.jsonl")
        let fingerprint = "{\"files\":[{\"path\":\"/rec/a.m4a\",\"sha256\":\"0\",\"bytes\":0,\"mtime\":null}]}"
        let line = "{\"basename\":\"a.m4a\",\"completed_at\":\"2026-06-01T10:00:00Z\",\"output_paths\":[],\"recorded_at\":null,\"recording_title\":null,\"schema_version\":1,\"source_fingerprint\":\(fingerprint),\"source_id\":\"file:/rec/a.m4a\",\"source_kind\":\"file\",\"voice_memos_path\":null,\"voice_memos_unique_id\":null,\"warning_count\":0}\n"
        try Data(line.utf8).write(to: ledger)
        let cwd = directory.appendingPathComponent("cwd")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try document("portable", hash: "b"), to: cwd.appendingPathComponent("deadbeef"))
        let before = try snapshot(of: state)

        let result = try run(["inspect", "deadbeef"], currentDirectory: cwd)
        XCTAssertEqual(result.0, 0, result.1)
        XCTAssertTrue(result.1.contains("Segments: 1"), result.1)
        XCTAssertFalse(result.1.contains("was read as saved document"), result.1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ledger.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: state.appendingPathComponent("migrated-v1").path))
        XCTAssertEqual(try snapshot(of: state), before)

        // The probe still sees the stored document through the same files.
        try Data("not a transcript\n".utf8).write(to: cwd.appendingPathComponent("aaaaaaaa"))
        let clash = try run(["inspect", "aaaaaaaa"], currentDirectory: cwd)
        XCTAssertEqual(clash.0, 0, clash.1)
        XCTAssertTrue(clash.1.contains("was read as saved document aaaaaaaa"), clash.1)
        XCTAssertTrue(clash.1.contains("Transcript: aaaaaaaa\n"), clash.1)
    }

    /// A schema this binary does not understand is never opened for the
    /// shadow lookup, let alone refused loudly: the file argument wins.
    func testShadowLookupIgnoresANewerSchema() throws {
        let stored = try XCTUnwrap(UUID(uuidString: "aaaaaaaa-0000-4000-8000-000000000000"))
        _ = try managedDocument(hash: "a", id: stored)
        try StateStore.withDatabase { try $0.exec("PRAGMA user_version = \(StateDatabase.schemaVersion + 1)") }
        StateStore.closeShared()
        let state = try StatePaths.stateDirectoryURL()
        let cwd = directory.appendingPathComponent("cwd")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: try document("portable", hash: "b"), to: cwd.appendingPathComponent("aaaaaaaa"))
        let before = try snapshot(of: state)

        let result = try run(["inspect", "aaaaaaaa"], currentDirectory: cwd)
        XCTAssertEqual(result.0, 0, result.1)
        XCTAssertFalse(result.1.contains("was read as saved document"), result.1)
        XCTAssertTrue(result.1.contains("Segments: 1"), result.1)
        XCTAssertEqual(try snapshot(of: state), before)
    }

    /// Every entry under `root` with its POSIX mode and, for files, a digest
    /// of the bytes.
    private func snapshot(of root: URL) throws -> [String: String] {
        var entries: [String: String] = [:]
        let paths = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        for path in paths {
            let full = root.appendingPathComponent(path).path
            let attributes = try FileManager.default.attributesOfItem(atPath: full)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
            var isDirectory: ObjCBool = false
            _ = FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory)
            let content = isDirectory.boolValue
                ? "dir"
                : SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: full))).map { String(format: "%02x", $0) }.joined()
            entries[path] = "\(String(mode, radix: 8)) \(content)"
        }
        return entries
    }

    func testCorruptUpdatedAtIsSanitisedInTheListing() throws {
        let (uuid, _) = try managedDocument(hash: "a")
        try StateStore.withDatabase { database in
            try database.inTransaction(.write) {
                try database.execute(
                    "UPDATE documents SET updated_at = ? WHERE id = ?",
                    [.text("bad\u{1B}[31mtime"), .text(uuid.uuidString.lowercased())]
                )
            }
        }
        let list = try run(["transcripts"])
        XCTAssertEqual(list.0, 0, list.1)
        XCTAssertTrue(list.1.contains("meeting"), list.1)
        XCTAssertFalse(list.1.contains("\u{1B}"), list.1)
    }

    /// Scripts may hold 2.x managed paths; those dangle now, and the error
    /// says how saved documents are addressed instead.
    func testDanglingManagedPathPointsAtTheIDForm() throws {
        let (_, id) = try managedDocument(hash: "a")
        let legacyPath = try StatePaths.stateDirectoryURL()
            .appendingPathComponent("transcripts/\(id).transcript.json").path

        let result = try run(["speakers", "review", legacyPath])
        XCTAssertEqual(result.0, 3, result.1)
        XCTAssertTrue(result.1.contains("No transcript at "), result.1)
        XCTAssertTrue(result.1.contains("Run transcribe transcripts"), result.1)
        XCTAssertTrue(result.1.contains("addressed by ID"), result.1)
    }

    func testReviewPrintsTheTranscriptID() throws {
        let (_, id) = try managedDocument(hash: "a")

        let table = try run(["speakers", "review", id])
        XCTAssertEqual(table.0, 0, table.1)
        XCTAssertTrue(table.1.contains("Transcript ID: \(String(id.prefix(8)))\n"), table.1)

        let interactive = try run(["speakers", "review", id, "--interactive"], input: "Dave\n")
        XCTAssertEqual(interactive.0, 0, interactive.1)
        XCTAssertTrue(interactive.1.contains("Confirmed SPEAKER_0 as Dave"), interactive.1)
        XCTAssertTrue(interactive.1.contains("Transcript ID: \(String(id.prefix(8)))\n"), interactive.1)
    }

    /// A short prefix resolves to managed documents, so a portable file whose
    /// ID also names an imported managed copy must show its full ID.
    func testReviewOfAPortableFilePrintsTheFullID() throws {
        let file = try document("portable", hash: "b")
        let uuid = try CanonicalTranscriptStore.load(from: file).id
        let id = uuid.uuidString.lowercased()
        _ = try managedDocument(hash: "a", id: uuid)

        let table = try run(["speakers", "review", file.path])
        XCTAssertEqual(table.0, 0, table.1)
        XCTAssertTrue(table.1.contains("Transcript ID: \(id)\n"), table.1)

        let interactive = try run(["speakers", "review", file.path, "--interactive"], input: "Dave\n")
        XCTAssertEqual(interactive.0, 0, interactive.1)
        XCTAssertTrue(interactive.1.contains("Confirmed SPEAKER_0 as Dave"), interactive.1)
        XCTAssertTrue(interactive.1.contains("Transcript ID: \(id)\n"), interactive.1)
    }

    func testReviewApplyOnAManagedDocumentNamesItsID() throws {
        let (uuid, id) = try managedDocument(hash: "a")
        let one = try document("one", hash: "b")
        XCTAssertEqual(try run(["speakers", "confirm", one.path, "SPEAKER_0", "--name", "Dave"]).0, 0)

        let applied = try run(["speakers", "review", id, "--apply"])
        XCTAssertEqual(applied.0, 0, applied.1)
        XCTAssertTrue(applied.1.contains("Saved assignments for \(String(id.prefix(8)))."), applied.1)
        XCTAssertFalse(applied.1.contains(id), applied.1)
        XCTAssertTrue(applied.1.contains("suggested"), applied.1)
        XCTAssertEqual(try CanonicalTranscriptStore.load(id: uuid).speakerMatches["SPEAKER_0"]?.status, .suggested)

        let portable = try run(["speakers", "review", one.path, "--apply"])
        XCTAssertTrue(portable.1.contains("Saved assignments to \(one.resolvingSymlinksInPath().path)."), portable.1)
    }

    func testManagedExportRecordsRefreshUnderTheRenderLock() throws {
        let (uuid, id) = try managedDocument(hash: "a")
        let out = directory.appendingPathComponent("managed-out")
        let exported = try run(["export", id, "--format", "txt,srt", "-o", out.path])
        XCTAssertEqual(exported.0, 0, exported.1)
        let records = try XCTUnwrap(CanonicalTranscriptStore.load(id: uuid).exports)
        XCTAssertEqual(Set(records.map(\.format)), ["txt", "srt"])

        let confirm = try run(["speakers", "confirm", id, "SPEAKER_0", "--name", "Dave"])
        XCTAssertEqual(confirm.0, 0, confirm.1)
        XCTAssertTrue(confirm.1.contains("Refreshed 2 exports"), confirm.1)
        XCTAssertTrue(try String(contentsOf: out.appendingPathComponent("meeting.txt")).contains("Dave"))

        let locks = try StatePaths.locksDirectoryURL()
        XCTAssertEqual(try XCTUnwrap(fileModeBits(atPath: locks.path)) & 0o777, 0o700)
        let lock = locks.appendingPathComponent("\(id).lock")
        XCTAssertEqual(try XCTUnwrap(fileModeBits(atPath: lock.path)) & 0o777, 0o600)

        XCTAssertEqual(try run(["speakers", "clear", id, "SPEAKER_0", "--no-refresh-exports"]).0, 0)
        let refresh = try run(["export", "--refresh"])
        XCTAssertEqual(refresh.0, 0, refresh.1)
        XCTAssertTrue(refresh.1.contains("Refreshed 2 exports"), refresh.1)
        XCTAssertFalse(try String(contentsOf: out.appendingPathComponent("meeting.txt")).contains("Dave"))
    }

    /// A held render lock stops a second export of the same managed
    /// document from rendering until the first has recorded its result.
    func testRenderLockBlocksASecondManagedExport() throws {
        let (uuid, id) = try managedDocument(hash: "a")
        let out = directory.appendingPathComponent("locked-out")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CLITests.transcribePath)
        process.arguments = ["export", id, "--format", "txt", "-o", out.path]
        var environment = ProcessInfo.processInfo.environment
        environment["XDG_STATE_HOME"] = directory.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try SpeakerCommands.withRenderLock(id: uuid) {
            try process.run()
            Thread.sleep(forTimeInterval: 1)
            XCTAssertTrue(process.isRunning, "export must wait for the render lock")
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.appendingPathComponent("meeting.txt").path))
        }
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try CanonicalTranscriptStore.load(id: uuid).exports?.count, 1)
    }

    func testColorAppearsOnlyWhenForcedOntoPipes() throws {
        let original = try CanonicalTranscriptStore.load(from: document("one", hash: "a"))
        _ = try CanonicalTranscriptStore.saveManaged(original)
        let plain = try run(["transcripts"])
        XCTAssertEqual(plain.0, 0, plain.1)
        XCTAssertFalse(plain.1.contains("\u{1B}["), "piped output stays plain")
        let forced = try run(["transcripts"], environment: ["CLICOLOR_FORCE": "1"])
        XCTAssertEqual(forced.0, 0, forced.1)
        XCTAssertTrue(forced.1.contains("\u{1B}[1m"), "forced color emits ANSI sequences")
        let suppressed = try run(["transcripts"], environment: ["CLICOLOR_FORCE": "1", "NO_COLOR": "1"])
        XCTAssertFalse(suppressed.1.contains("\u{1B}["), "NO_COLOR wins over forcing")
    }
}
