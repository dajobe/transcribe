import XCTest
@testable import transcribe

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
        // ArgumentHelp wraps long lines; compare against whitespace-collapsed text.
        let collapsedHelp = output.split { $0.isNewline || $0.isWhitespace }.joined(separator: " ")
        XCTAssertTrue(
            collapsedHelp.contains(ConfigSemanticStrings.languageWhenUnset),
            "root help should document language computed-default wording shared with config show; stdout: \(output)"
        )
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
        process.arguments = ["--transcript-only", "/nonexistent/file.wav"]
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
        process.arguments = ["--speakers-min", "3", "--speakers-max", "2", file.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 2, "speakers-min > speakers-max should exit 2")
    }

    func testSpeakerOptionsWithNoDiarizeExitTwo() throws {
        let file = try makeTempAudioFile()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["--transcript-only", "--speakers-min", "2", file.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 2, "speaker options with --transcript-only should exit 2")
        XCTAssertTrue(stderr.contains("only valid when speaker labels are enabled"), "stderr should explain the invalid combination")
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
        process.arguments = ["--speakers-min", "0", file.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 2, "zero --speakers-min should exit 2")
        XCTAssertTrue(stderr.contains("--speakers-min must be greater than 0"), "stderr should explain the invalid speaker count")
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
        process.arguments = ["--transcript-only", "dir", "--input-time-source", "off", "/nonexistent/path"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 3, "flag should be accepted; exit 3 is from missing input, not arg parsing")
    }

    func testNoAutoSessionBasenameFlagAccepted() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["--transcript-only", "dir", "--session-naming", "off", "/nonexistent/path"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 3)
    }

    func testMissingSourcePrintsDefaultBanner() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = []
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        XCTAssertEqual(process.terminationStatus, 0)
        let firstLine = stdout.components(separatedBy: "\n").first ?? ""
        XCTAssertTrue(
            firstLine.range(of: #"^transcribe \d+\.\d+\.\d+ "#, options: .regularExpression) != nil,
            "first line should announce `transcribe <version>`, got: \(firstLine)"
        )
        XCTAssertTrue(stdout.contains("Usage: transcribe"), "stdout: \(stdout)")
        XCTAssertTrue(stdout.contains("Sources:"), "stdout: \(stdout)")
        XCTAssertTrue(stdout.contains("config"), "stdout: \(stdout)")
        XCTAssertTrue(stdout.contains("transcribe --help"), "stdout: \(stdout)")
    }

    func testConfigPathUsesTranscribeConfigEnv() throws {
        let tmp = try makeTempDir()
        let cfg = tmp.appendingPathComponent("my.json")
        try Data("{}".utf8).write(to: cfg)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["config", "path"]
        process.environment = ProcessInfo.processInfo.environment.merging(["TRANSCRIBE_CONFIG": cfg.path]) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .newlines) ?? ""
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(out, cfg.path)
    }

    func testConfigShowIncludesCatalogKeys() throws {
        let tmp = try makeTempDir()
        let cfg = tmp.appendingPathComponent("cfg.json")
        try Data("{}".utf8).write(to: cfg)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["config", "show"]
        process.environment = ProcessInfo.processInfo.environment.merging(["TRANSCRIBE_CONFIG": cfg.path]) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(out.contains("model "), "stdout: \(out)")
        XCTAssertTrue(out.contains("output.dir "), "stdout: \(out)")
        XCTAssertTrue(out.contains("dir.sessionGap "), "stdout: \(out)")
        XCTAssertTrue(out.contains("voiceMemos.sessionGap "), "stdout: \(out)")
        XCTAssertTrue(
            out.contains("# \(ConfigSemanticStrings.languageWhenUnset)"),
            "expected computed-default comment before language; stdout: \(out)"
        )
        XCTAssertTrue(
            out.contains("# \(ConfigSemanticStrings.outputPrefixWhenUnset)"),
            "expected computed-default comment before output.prefix; stdout: \(out)"
        )
    }

    func testConfigShowAnnotatesBuiltinDefaultWhenOverridden() throws {
        let tmp = try makeTempDir()
        let cfg = tmp.appendingPathComponent("cfg.json")
        let json = """
        {"logging":{"verbose":true}}
        """
        try Data(json.utf8).write(to: cfg)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["config", "show"]
        process.environment = ProcessInfo.processInfo.environment.merging(["TRANSCRIBE_CONFIG": cfg.path]) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(
            out.contains("logging.verbose true (default false)"),
            "expected override annotation; stdout: \(out)"
        )
    }

    func testConfigShowOmitsComputedCommentsWhenUnsetSentinelsNotShown() throws {
        let tmp = try makeTempDir()
        let cfg = tmp.appendingPathComponent("cfg.json")
        let json = """
        {"language":"en","output":{"prefix":"meet"},"speakers":{"min":2,"max":2}}
        """
        try Data(json.utf8).write(to: cfg)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["config", "show"]
        process.environment = ProcessInfo.processInfo.environment.merging(["TRANSCRIBE_CONFIG": cfg.path]) { _, new in new }
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertFalse(out.contains("# \(ConfigSemanticStrings.languageWhenUnset)"), "stdout: \(out)")
        XCTAssertFalse(out.contains("# \(ConfigSemanticStrings.outputPrefixWhenUnset)"), "stdout: \(out)")
        XCTAssertFalse(out.contains("# \(ConfigSemanticStrings.speakersMinWhenUnset)"), "stdout: \(out)")
        XCTAssertFalse(out.contains("# \(ConfigSemanticStrings.speakersMaxWhenUnset)"), "stdout: \(out)")
        XCTAssertTrue(out.contains("language en"), "stdout: \(out)")
        XCTAssertTrue(out.contains("output.prefix meet"), "stdout: \(out)")
        XCTAssertTrue(out.contains("speakers.min 2"), "stdout: \(out)")
        XCTAssertTrue(out.contains("speakers.max 2"), "stdout: \(out)")
    }

    func testHistoryWithEmptyLedgerHintsAtPath() throws {
        let state = try makeTempDir()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["history"]
        process.environment = ProcessInfo.processInfo.environment.merging(["XDG_STATE_HOME": state.path]) { _, new in new }
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(stdout.contains("No processing history yet"), "stdout: \(stdout)")
        XCTAssertTrue(stdout.contains("processing_history.jsonl"), "stdout: \(stdout)")
    }

    func testHistoryShowsRecentEntriesNewestFirstWithCount() throws {
        let state = try makeTempDir()
        let ledgerDir = state.appendingPathComponent("transcribe", isDirectory: true)
        try FileManager.default.createDirectory(at: ledgerDir, withIntermediateDirectories: true)
        let ledger = ledgerDir.appendingPathComponent("processing_history.jsonl")

        // Three records with descending completed_at; --count 2 should drop the oldest.
        let lines = [
            historyLine(completedAtMinutesAgo: 60, kind: "voice_memos", filename: "old.m4a", recordedAt: "2014-05-13T00:30:35Z"),
            historyLine(completedAtMinutesAgo: 30, kind: "file", filename: "mid.m4a", recordedAt: nil),
            historyLine(completedAtMinutesAgo: 5, kind: "voice_memos", filename: "fresh.m4a", recordedAt: "2026-05-09T14:30:00Z"),
        ].joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: ledger)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["history", "--count", "2"]
        process.environment = ProcessInfo.processInfo.environment.merging(["XDG_STATE_HOME": state.path]) { _, new in new }
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        try process.run()
        process.waitUntilExit()
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let outputLines = stdout.split(separator: "\n").map(String.init)

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(outputLines.count, 3, "expected header + 2 rows; stdout: \(stdout)")
        XCTAssertTrue(outputLines[0].contains("WHEN"), "header missing: \(outputLines[0])")
        XCTAssertTrue(outputLines[0].contains("WHY"), "header missing: \(outputLines[0])")
        XCTAssertTrue(outputLines[0].contains("KIND"), "header missing: \(outputLines[0])")
        XCTAssertTrue(outputLines[0].contains("RECORDED"), "header missing: \(outputLines[0])")
        XCTAssertTrue(outputLines[0].contains("FILE"), "header missing: \(outputLines[0])")
        XCTAssertTrue(outputLines[1].contains("legacy"), "old records should infer legacy reason: \(outputLines[1])")
        XCTAssertTrue(outputLines[1].contains("fresh.m4a"), "newest first: \(outputLines[1])")
        XCTAssertTrue(outputLines[1].contains("2026-05-09"), "newest entry should show recorded date: \(outputLines[1])")
        XCTAssertTrue(outputLines[2].contains("mid.m4a"), "second: \(outputLines[2])")
        XCTAssertTrue(outputLines[2].contains("-"), "missing recorded_at should render as dash: \(outputLines[2])")
        XCTAssertFalse(stdout.contains("old.m4a"), "--count 2 should drop the third entry")
    }

    func testHistoryRejectsZeroCount() throws {
        let state = try makeTempDir()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["history", "--count", "0"]
        process.environment = ProcessInfo.processInfo.environment.merging(["XDG_STATE_HOME": state.path]) { _, new in new }
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        XCTAssertEqual(process.terminationStatus, 2)
        XCTAssertTrue(stderr.contains("--count must be a positive integer"), "stderr: \(stderr)")
    }

    private func historyLine(completedAtMinutesAgo: Int, kind: String, filename: String, recordedAt: String?) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let completedAt = formatter.string(from: Date().addingTimeInterval(-Double(completedAtMinutesAgo * 60)))
        let recordedField = recordedAt.map { "\"\($0)\"" } ?? "null"
        let path = "/tmp/history-fixture/\(filename)"
        let fingerprint = "{\"files\":[{\"path\":\"\(path)\",\"sha256\":\"0\",\"bytes\":0,\"mtime\":null}]}"
        return """
            {"basename":"\(filename)","completed_at":"\(completedAt)","output_paths":[],"recorded_at":\(recordedField),"recording_title":null,"schema_version":1,"source_fingerprint":\(fingerprint),"source_id":"\(kind):\(filename)","source_kind":"\(kind)","voice_memos_path":null,"voice_memos_unique_id":null,"warning_count":0,"audio_duration_s":null,"output_dir":null,"settings_signature":null}
            """.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testUnknownGlobalOptionBeforeSourceReportsCleanly() throws {
        // ArgumentParser's .captureForPassthrough swallows unknown flags into
        // sourceArgs. The dispatcher must recognise that a leading `-` token
        // is a typo'd global option, not a path alias.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["--verbose", "--no-such-flag", "voice-memos"]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        XCTAssertEqual(process.terminationStatus, 2)
        XCTAssertTrue(stderr.contains("Unknown global option"), "stderr: \(stderr)")
        XCTAssertTrue(stderr.contains("--no-such-flag"), "stderr: \(stderr)")
        XCTAssertFalse(stderr.contains("root path alias"), "stderr: \(stderr)")
    }

    func testDryRunAliasAcceptsBothSpellings() throws {
        // Both --dry-run and --dryrun should be accepted as the dry-run flag.
        // Use voice-memos with a nonexistent recordings dir so we exit early
        // on the input-file check (exit code 3) rather than loading models.
        for spelling in ["--dry-run", "--dryrun"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Self.transcribePath)
            process.arguments = [spelling, "voice-memos", "--recordings-dir", "/nonexistent-path"]
            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            try process.run()
            process.waitUntilExit()
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            XCTAssertNotEqual(process.terminationStatus, 2,
                              "\(spelling) should not exit invalid-usage; stderr: \(stderr)")
            XCTAssertFalse(stderr.contains("Unknown global option"),
                           "\(spelling) should be recognised; stderr: \(stderr)")
        }
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
        process.arguments = ["--dry-run", "--transcript-only", file.path]
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
        process.arguments = ["--dry-run", "--transcript-only", dir.path]
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

        let fileResult = try runCommand(["file", file.path, "--transcript-only"])
        XCTAssertNotEqual(fileResult.status, 0)
        XCTAssertTrue(fileResult.stderr.contains("--transcript-only"), "stderr: \(fileResult.stderr)")

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
        process.arguments = ["--redo", "--transcript-only", "/nonexistent/path"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 3)
    }

    func testVoiceMemosDryRunListsProcessWithoutModelLoad() throws {
        let dir = try makeTempDir()
        try createVoiceMemosDB(in: dir, uniqueID: "dry-run-a", path: "A.m4a", title: "Dry Run")
        try Data("audio".utf8).write(to: dir.appendingPathComponent("A.m4a"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = [
            "--dry-run",
            "--transcript-only",
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

    func testVoiceMemosMarkImportedWritesVoiceMemosBaseline() throws {
        let dir = try makeTempDir()
        let state = try makeTempDir()
        try createVoiceMemosDB(in: dir, uniqueID: "real-import-a", path: "A.m4a", title: "Field Recording")
        try Data("audio".utf8).write(to: dir.appendingPathComponent("A.m4a"))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = [
            "--mark-imported",
            "voice-memos",
            "--recordings-dir", dir.path,
        ]
        process.environment = ProcessInfo.processInfo.environment.merging(["XDG_STATE_HOME": state.path]) { _, new in new }
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let ledger = state.appendingPathComponent("transcribe").appendingPathComponent("processing_history.jsonl")
        let raw = try String(contentsOf: ledger, encoding: .utf8)
        XCTAssertTrue(raw.contains("\"source_kind\":\"voice_memos_baseline\""), "ledger: \(raw)")
        XCTAssertTrue(raw.contains("\"history_reason\":\"imported\""), "ledger: \(raw)")
        XCTAssertFalse(raw.contains("\"source_kind\":\"imported_baseline\""), "should not write generic baseline kind for Voice Memos: \(raw)")

        let duplicate = Process()
        duplicate.executableURL = URL(fileURLWithPath: Self.transcribePath)
        duplicate.arguments = process.arguments
        duplicate.environment = process.environment
        try duplicate.run()
        duplicate.waitUntilExit()
        XCTAssertEqual(duplicate.terminationStatus, 0)

        let rawAfterDuplicate = try String(contentsOf: ledger, encoding: .utf8)
        XCTAssertEqual(rawAfterDuplicate.split(separator: "\n").count, 1, "baseline duplicate skips should not flood history: \(rawAfterDuplicate)")
        XCTAssertFalse(rawAfterDuplicate.contains("\"history_reason\":\"skip_duplicate\""), "ledger: \(rawAfterDuplicate)")

        // history should render the new reason and compact source kind.
        let history = Process()
        history.executableURL = URL(fileURLWithPath: Self.transcribePath)
        history.arguments = ["history"]
        history.environment = ProcessInfo.processInfo.environment.merging(["XDG_STATE_HOME": state.path]) { _, new in new }
        let stdoutPipe = Pipe()
        history.standardOutput = stdoutPipe
        try history.run()
        history.waitUntilExit()
        let out = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        XCTAssertEqual(history.terminationStatus, 0)
        XCTAssertTrue(out.contains("imported"), "stdout: \(out)")
        XCTAssertTrue(out.contains("voice"), "stdout: \(out)")
        XCTAssertTrue(out.contains("A.m4a"), "stdout: \(out)")
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
        SQLiteTestHelpers.executeScript(
            at: dir.appendingPathComponent("CloudRecordings.db"),
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
            """
        )
    }

    func testNegativeMaxSpeakersExitTwo() throws {
        let file = try makeTempAudioFile()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["--speakers-max=-1", file.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 2, "negative --speakers-max should exit 2")
        XCTAssertTrue(stderr.contains("--speakers-max must be greater than 0"), "stderr should explain the invalid speaker count")
    }
}
