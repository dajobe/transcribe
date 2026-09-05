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
        _ args: [String], input: String? = nil, environment extra: [String: String] = [:]
    ) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CLITests.transcribePath)
        process.arguments = args
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
        let original = try CanonicalTranscriptStore.load(from: try document("one", hash: "a"))
        _ = try CanonicalTranscriptStore.save(original)
        let managed = try StatePaths.stateDirectoryURL().appendingPathComponent("transcripts")
        let corrupt = managed.appendingPathComponent("corrupt.transcript.json")
        try Data("{ not json".utf8).write(to: corrupt)

        let list = try run(["transcripts"])
        XCTAssertEqual(list.0, 0, list.1)
        XCTAssertTrue(list.1.contains("meeting\t"), list.1)
        // The listing resolves symlinked state directories, so match the name.
        XCTAssertTrue(list.1.contains("(unreadable)\t") && list.1.contains(corrupt.lastPathComponent), list.1)
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
        _ = try CanonicalTranscriptStore.save(original)
        let list = try run(["transcripts"])
        XCTAssertEqual(list.0, 0, list.1)
        XCTAssertTrue(list.1.contains(".transcript.json"))
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
        let one = try CanonicalTranscriptStore.save(CanonicalTranscriptStore.load(from: document("one", hash: "a")))
        let table = try run(["speakers", "review"])
        XCTAssertEqual(table.0, 0, table.1)
        XCTAssertTrue(table.1.contains("meeting"), table.1)
        XCTAssertTrue(table.1.contains("SPEAKER_0\tunidentified"), table.1)

        let interactive = try run(["speakers", "review", "--interactive"], input: "Dave\n")
        XCTAssertEqual(interactive.0, 0, interactive.1)
        XCTAssertTrue(interactive.1.contains("Confirmed SPEAKER_0 as Dave"), interactive.1)
        XCTAssertEqual(try CanonicalTranscriptStore.load(from: one).speakerMatches["SPEAKER_0"]?.name, "Dave")

        let settled = try run(["speakers", "review", "--interactive"], input: "")
        XCTAssertEqual(settled.0, 0, settled.1)
        XCTAssertTrue(settled.1.contains("run with --all to revisit"), settled.1)
    }

    func testReviewFlagValidation() throws {
        let one = try document("one", hash: "a")
        XCTAssertEqual(try run(["speakers", "review", one.path, "--apply", "--interactive"]).0, 2)
        XCTAssertEqual(try run(["speakers", "review", "--apply"]).0, 2, "--apply needs a transcript")
    }

    func testColorAppearsOnlyWhenForcedOntoPipes() throws {
        let original = try CanonicalTranscriptStore.load(from: document("one", hash: "a"))
        _ = try CanonicalTranscriptStore.save(original)
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
