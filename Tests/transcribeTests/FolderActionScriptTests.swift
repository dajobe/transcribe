import Foundation
import XCTest

final class FolderActionScriptTests: XCTestCase {
    func testFolderActionAppendsChildStdoutEventsAndDefaultsPlainProgress() throws {
        let dir = try makeTempDir()
        let fakeBin = dir.appendingPathComponent("fake-transcribe.sh")
        let argsFile = dir.appendingPathComponent("args.txt")
        try writeExecutable(
            fakeBin,
            """
            #!/bin/bash
            if [[ "${1:-}" == "--version" ]]; then
              echo "2.5.9"
              exit 0
            fi
            printf '%s\\n' "$*" > "\(argsFile.path)"
            echo '2026-05-29T16:28:08Z INFO event=session_done source=file session=1/1 input=clip.aac'
            exit 0
            """
        )
        let audio = dir.appendingPathComponent("clip.aac")
        try Data("audio".utf8).write(to: audio)
        let log = dir.appendingPathComponent("transcribe.log")

        let result = try runFolderAction(audio: audio, fakeBin: fakeBin, log: log)

        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        let logText = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(logText.contains("INFO event=start"), logText)
        XCTAssertTrue(logText.contains("INFO event=session_done"), logText)
        XCTAssertTrue(logText.contains("INFO event=end"), logText)
        XCTAssertFalse(logText.contains("transcribe-stderr:"), logText)
        let args = try String(contentsOf: argsFile, encoding: .utf8)
        XCTAssertTrue(args.contains("--progress-log plain"), args)
    }

    func testFolderActionFailureLogsOneErrorAndRawStderr() throws {
        let dir = try makeTempDir()
        let fakeBin = dir.appendingPathComponent("fake-transcribe.sh")
        try writeExecutable(
            fakeBin,
            """
            #!/bin/bash
            if [[ "${1:-}" == "--version" ]]; then
              echo "2.5.9"
              exit 0
            fi
            echo '2026-05-29T16:28:08Z INFO event=session_start source=file session=1/1 input=clip.m4a'
            echo 'model failed badly' >&2
            exit 4
            """
        )
        let audio = dir.appendingPathComponent("clip.m4a")
        try Data("audio".utf8).write(to: audio)
        let log = dir.appendingPathComponent("transcribe.log")
        let stderrLog = dir.appendingPathComponent("raw-stderr.log")

        let result = try runFolderAction(
            audio: audio,
            fakeBin: fakeBin,
            log: log,
            extraEnvironment: ["TRANSCRIBE_STDERR_LOG": stderrLog.path]
        )

        XCTAssertEqual(result.status, 4)
        XCTAssertEqual(result.stderr, "")
        let logText = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(logText.contains("INFO event=session_start"), logText)
        XCTAssertTrue(logText.contains("ERROR event=transcribe_failed"), logText)
        XCTAssertTrue(logText.contains("meaning=model"), logText)
        XCTAssertTrue(logText.contains("stderr_summary=\"model failed badly\""), logText)
        XCTAssertFalse(logText.contains("transcribe-stderr:"), logText)
        let raw = try String(contentsOf: stderrLog, encoding: .utf8)
        XCTAssertTrue(raw.contains("model failed badly"), raw)
    }

    private func runFolderAction(
        audio: URL,
        fakeBin: URL,
        log: URL,
        extraEnvironment: [String: String] = [:]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["scripts/folder-action-transcribe.sh", audio.path]
        var env = ProcessInfo.processInfo.environment
        env["TRANSCRIBE_BIN"] = fakeBin.path
        env["TRANSCRIBE_LOG"] = log.path
        env["TRANSCRIBE_OUTPUT_DIR"] = audio.deletingLastPathComponent().path
        env["TRANSCRIBE_STABLE_SECS"] = "0"
        env["TRANSCRIBE_MAX_STABLE_WAIT"] = "3"
        for (key, value) in extraEnvironment {
            env[key] = value
        }
        process.environment = env
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

    private func writeExecutable(_ url: URL, _ text: String) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
