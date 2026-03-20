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
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "transcribe --help should exit 0")
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
        process.arguments = ["/nonexistent/file.wav", "--no-diarize"]
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["/tmp/any.wav", "--stdout", "--format", "json"]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 2, "--stdout without txt should exit 2")
    }

    func testMinMaxSpeakersInvalidExitTwo() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["/tmp/any.wav", "--min-speakers", "3", "--max-speakers", "2"]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 2, "min-speakers > max-speakers should exit 2")
    }

    func testSpeakerOptionsWithNoDiarizeExitTwo() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["/tmp/any.wav", "--no-diarize", "--min-speakers", "2"]
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["/tmp/any.wav", "--format", ""]
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["/tmp/any.wav", "--min-speakers", "0"]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 2, "zero --min-speakers should exit 2")
        XCTAssertTrue(stderr.contains("--min-speakers must be greater than 0"), "stderr should explain the invalid speaker count")
    }

    func testNegativeMaxSpeakersExitTwo() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.transcribePath)
        process.arguments = ["/tmp/any.wav", "--max-speakers=-1"]
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
