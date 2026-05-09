import XCTest

final class CLITests: XCTestCase {
    /// Path to the built transcribe executable (relative to package root).
    static var transcribePath: String {
        #if arch(arm64)
        return ".build/arm64-apple-macosx/debug/transcribe"
        #elseif arch(x86_64)
        return ".build/x86_64-apple-macosx/debug/transcribe"
        #else
        return ".build/debug/transcribe"
        #endif
    }

    func testHelpExitZero() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["--help"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "transcribe --help should exit 0")
        XCTAssertTrue(output.contains("--model"), "root help should include global options")
        XCTAssertTrue(output.contains("--mark-imported"), "root help should include global mark-imported option")
        XCTAssertTrue(output.contains("Source commands:"), "root help should list source commands")
    }

    func testSubcommandHelpIsSourceSpecific() throws {
        let fileHelp = try runCommand(["file", "--help"]).stdout
        XCTAssertTrue(fileHelp.contains("<audio-file>"))
        XCTAssertFalse(fileHelp.contains("--model"), "file help should not duplicate global options")
        XCTAssertFalse(fileHelp.contains("--sort"), "file help should not show dir options")

        let dirHelp = try runCommand(["dir", "--help"]).stdout
        XCTAssertTrue(dirHelp.contains("--sort"))
        XCTAssertTrue(dirHelp.contains("--session-gap"))
        XCTAssertFalse(dirHelp.contains("--model"), "dir help should not duplicate global options")
        XCTAssertFalse(dirHelp.contains("--recordings-dir"), "dir help should not show Voice Memos options")

        let voiceHelp = try runCommand(["voice-memos", "--help"]).stdout
        XCTAssertTrue(voiceHelp.contains("--recordings-dir"))
        XCTAssertTrue(voiceHelp.contains("--session-gap"))
        XCTAssertFalse(voiceHelp.contains("--mark-imported"), "Voice Memos help should not duplicate global options")
        XCTAssertFalse(voiceHelp.contains("--model"), "Voice Memos help should not duplicate global options")
    }

    func testVersionOutput() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(output.range(of: #"^\d+\.\d+\.\d+\s*$"#, options: .regularExpression) != nil,
                      "Version output should be a semver string, got: \(output)")
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testMissingFileExitThree() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["--no-diarize", "/nonexistent/file.wav"]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 3, "Missing file should exit 3, stderr: \(stderr)")
        XCTAssertTrue(stderr.contains("does not exist") || stderr.contains("nonexistent"), "stderr should mention missing file")
    }

    func testInvalidUsageStdoutWithoutTxtExitTwo() throws {
        let file = try makeTempAudioFile()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["--stdout", "--format", "json", file.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 2, "--stdout without txt should exit 2")
    }

    func testMinMaxSpeakersInvalidExitTwo() throws {
        let file = try makeTempAudioFile()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["--min-speakers", "3", "--max-speakers", "2", file.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 2, "min-speakers > max-speakers should exit 2")
    }

    func testSpeakerOptionsWithNoDiarizeExitTwo() throws {
        let file = try makeTempAudioFile()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["--no-diarize", "--min-speakers", "2", file.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 2, "speaker options with --no-diarize should exit 2")
        XCTAssertTrue(stderr.contains("only valid when diarization is enabled"), "stderr should explain the invalid combination")
    }

    func testEmptyFormatExitTwo() throws {
        let file = try makeTempAudioFile()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["--format", "", file.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 2, "empty --format should exit 2")
        XCTAssertTrue(stderr.contains("--format must include at least one"), "stderr should explain the empty format list")
    }

    func testZeroMinSpeakersExitTwo() throws {
        let file = try makeTempAudioFile()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["--min-speakers", "0", file.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 2, "zero --min-speakers should exit 2")
        XCTAssertTrue(stderr.contains("--min-speakers must be greater than 0"), "stderr should explain the invalid speaker count")
    }

    func testEmptyDirectoryExitThree() throws {
        let dir = try makeTempDir()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = [dir.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let stderr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 3, "empty directory should exit 3, stderr: \(stderr)")
        XCTAssertTrue(stderr.contains("No audio files"), "stderr should mention no audio files; got: \(stderr)")
    }

    func testNoFilenameTimeRecoveryFlagAccepted() throws {
        // Verify the flag parses without erroring at the argument-parser level.
        // We pass a non-existent input so the run still exits via .inputFile (3),
        // but we should reach validation rather than hit a parser error (64).
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["--no-diarize", "dir", "--no-filename-time-recovery", "/nonexistent/path"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 3, "flag should be accepted; exit 3 is from missing input, not arg parsing")
    }

    func testNoAutoSessionBasenameFlagAccepted() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["--no-diarize", "dir", "--no-auto-session-basename", "/nonexistent/path"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 3)
    }

    func testMissingInputWithoutVoiceMemosExitTwo() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["--no-diarize"]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let stderr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertTrue(stderr.contains("Missing source"), "stderr: \(stderr)")
    }

    func testVoiceMemosRejectsPositionalInputExitTwo() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["voice-memos", "/tmp/any.m4a"]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let stderr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertTrue(stderr.contains("Unexpected argument") || stderr.contains("/tmp/any.m4a"), "stderr: \(stderr)")
    }

    func testMarkImportedDryRunWorksForFileAlias() throws {
        let dir = try makeTempDir()
        let state = try makeTempDir()
        let file = dir.appendingPathComponent("meeting.m4a")
        try Data("audio".utf8).write(to: file)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["--dry-run", "--mark-imported", file.path]
        process.environment = ProcessInfo.processInfo.environment.merging(["XDG_STATE_HOME": state.path]) { _, new in new }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "stderr: \(err)")
        XCTAssertTrue(out.contains("mark-imported\tfile"), "stdout: \(out)")
        let ledger = state.appendingPathComponent("transcribe").appendingPathComponent("processing_history.jsonl")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledger.path))
    }

    func testRootAliasFileDispatchDryRun() throws {
        let dir = try makeTempDir()
        let file = dir.appendingPathComponent("meeting.m4a")
        try Data("audio".utf8).write(to: file)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["--dry-run", "--no-diarize", file.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "stderr: \(err)")
        XCTAssertTrue(out.contains("process\tfile"), "stdout: \(out)")
    }

    func testRootAliasDirectoryDispatchDryRun() throws {
        let dir = try makeTempDir()
        try Data("audio".utf8).write(to: dir.appendingPathComponent("clip.m4a"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["--dry-run", "--no-diarize", dir.path]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "stderr: \(err)")
        XCTAssertTrue(out.contains("process\tdirectory_session"), "stdout: \(out)")
    }

    func testFileSubcommandRejectsDirectory() throws {
        let dir = try makeTempDir()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["--dry-run", "file", dir.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let stderr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 2, "stderr: \(stderr)")
        XCTAssertTrue(stderr.contains("`transcribe file` requires an audio file"), "stderr: \(stderr)")
    }

    func testDirSubcommandRejectsFile() throws {
        let dir = try makeTempDir()
        let file = dir.appendingPathComponent("meeting.m4a")
        try Data("audio".utf8).write(to: file)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["--dry-run", "dir", file.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let stderr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 2, "stderr: \(stderr)")
        XCTAssertTrue(stderr.contains("`transcribe dir` requires a directory"), "stderr: \(stderr)")
    }

    func testFileSubcommandDoesNotAcceptDirOnlyOptions() throws {
        let dir = try makeTempDir()
        let file = dir.appendingPathComponent("meeting.m4a")
        try Data("audio".utf8).write(to: file)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["--dry-run", "file", file.path, "--sort", "name"]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let stderr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertTrue(stderr.contains("--sort"), "stderr: \(stderr)")
    }

    func testSharedOptionsAfterSourceAreRejected() throws {
        let dir = try makeTempDir()
        let file = dir.appendingPathComponent("meeting.m4a")
        try Data("audio".utf8).write(to: file)

        let fileResult = try runCommand(["file", file.path, "--no-diarize"])
        XCTAssertNotEqual(fileResult.status, 0)
        XCTAssertTrue(fileResult.stderr.contains("--no-diarize"), "stderr: \(fileResult.stderr)")

        let dirResult = try runCommand(["dir", dir.path, "--format", "md"])
        XCTAssertNotEqual(dirResult.status, 0)
        XCTAssertTrue(dirResult.stderr.contains("--format"), "stderr: \(dirResult.stderr)")
    }

    func testRootAliasRejectsDirectorySpecificOptions() throws {
        let dir = try makeTempDir()
        try Data("audio".utf8).write(to: dir.appendingPathComponent("clip.m4a"))

        let result = try runCommand([dir.path, "--sort", "name"])
        XCTAssertEqual(result.status, 2)
        XCTAssertTrue(result.stderr.contains("--sort"), "stderr: \(result.stderr)")
        XCTAssertTrue(result.stderr.contains("transcribe dir"), "stderr: \(result.stderr)")
    }

    func testRedoFlagAcceptedForNormalInput() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["--redo", "--no-diarize", "/nonexistent/path"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 3)
    }

    func testVoiceMemosDryRunListsProcessWithoutModelLoad() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3"))
        let dir = try makeTempDir()
        try createVoiceMemosDB(in: dir, uniqueID: "dry-run-a", path: "A.m4a", title: "Dry Run")
        try Data("audio".utf8).write(to: dir.appendingPathComponent("A.m4a"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = [
            "--dry-run",
            "--no-diarize",
            "voice-memos",
            "--recordings-dir", dir.path,
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "stderr: \(err)")
        XCTAssertTrue(out.contains("would process"), "stdout: \(out)")
        XCTAssertTrue(out.contains("process\tvoice_memos"), "stdout: \(out)")
        XCTAssertFalse(err.contains("Using model cache"), "dry run should not load models; stderr: \(err)")
    }

    func testVoiceMemosMarkImportedDryRunDoesNotWriteLedger() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3"))
        let dir = try makeTempDir()
        let state = try makeTempDir()
        try createVoiceMemosDB(in: dir, uniqueID: "dry-run-b", path: "B.m4a", title: "Baseline")
        try Data("audio".utf8).write(to: dir.appendingPathComponent("B.m4a"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = [
            "--dry-run",
            "--mark-imported",
            "voice-memos",
            "--recordings-dir", dir.path,
        ]
        process.environment = ProcessInfo.processInfo.environment.merging(["XDG_STATE_HOME": state.path]) { _, new in new }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, "stderr: \(err)")
        XCTAssertTrue(out.contains("would be marked imported"), "stdout: \(out)")
        XCTAssertTrue(out.contains("mark-imported\tvoice_memos"), "stdout: \(out)")
        let ledger = state.appendingPathComponent("transcribe").appendingPathComponent("processing_history.jsonl")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledger.path))
    }

    func testNegativeSessionGapExitTwo() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["dir", "--session-gap=-1", "/tmp"]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let stderr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 2, "negative --session-gap should exit 2, stderr: \(stderr)")
        XCTAssertTrue(stderr.contains("--session-gap"), "stderr should mention the bad option")
    }

    func testNegativeVoiceMemosSessionGapExitTwo() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["voice-memos", "--session-gap=-1"]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let stderr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 2, "negative --session-gap should exit 2, stderr: \(stderr)")
        XCTAssertTrue(stderr.contains("--session-gap"), "stderr should mention the bad option")
    }

    func testInvalidInputSortExitsNonZero() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["dir", "--input-sort", "garbage", "/tmp"]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let stderr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertNotEqual(process.terminationStatus, 0, "unknown --input-sort value should not exit 0")
        XCTAssertTrue(
            stderr.contains("input-sort") || stderr.contains("garbage"),
            "stderr should reference the bad argument; got: \(stderr)"
        )
    }

    func testDirectoryWithOnlyNonAudioExitThree() throws {
        let dir = try makeTempDir()
        try Data("notes".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        try Data("readme".utf8).write(to: dir.appendingPathComponent("README.md"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = [dir.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let stderr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 3, "directory with only non-audio should exit 3, stderr: \(stderr)")
        XCTAssertTrue(stderr.contains("No audio files"), "stderr should mention no audio files; got: \(stderr)")
    }

    private func runCommand(_ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func makeTempAudioFile(named name: String = "any.m4a") throws -> URL {
        let dir = try makeTempDir()
        let file = dir.appendingPathComponent(name)
        try Data("audio".utf8).write(to: file)
        return file
    }

    private func createVoiceMemosDB(in dir: URL, uniqueID: String, path: String, title: String) throws {
        let db = dir.appendingPathComponent("CloudRecordings.db")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-init", "/dev/null",
            db.path,
            """
            CREATE TABLE ZCLOUDRECORDING (
                Z_PK INTEGER PRIMARY KEY,
                ZDATE TIMESTAMP,
                ZDURATION FLOAT,
                ZCUSTOMLABEL VARCHAR,
                ZPATH VARCHAR,
                ZUNIQUEID VARCHAR
            );
            INSERT INTO ZCLOUDRECORDING (Z_PK, ZDATE, ZDURATION, ZCUSTOMLABEL, ZPATH, ZUNIQUEID)
            VALUES (1, 789000000, 12.5, '\(title)', '\(path)', '\(uniqueID)');
            """,
        ]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let text = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTFail("sqlite failed: \(text)")
        }
    }

    func testNegativeMaxSpeakersExitTwo() throws {
        let file = try makeTempAudioFile()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["--max-speakers=-1", file.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 2, "negative --max-speakers should exit 2")
        XCTAssertTrue(stderr.contains("--max-speakers must be greater than 0"), "stderr should explain the invalid speaker count")
    }
}
