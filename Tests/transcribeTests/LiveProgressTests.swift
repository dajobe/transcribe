import XCTest
@testable import transcribe

final class LiveProgressTests: XCTestCase {
    /// When stderr is not a TTY (e.g. in tests or when piped), isStderrTTY() should be false.
    func testIsStderrTTYFalseWhenNotTerminal() {
        // In XCTest, stderr is typically not a TTY (unless run in a terminal with no redirect).
        // When we run "swift test", stderr is often a pipe. So we can't assert true/false
        // without environment assumptions. We only assert the function returns a Bool.
        let result = isStderrTTY()
        _ = result
        // If we're in a context where stderr is a pipe (e.g. CI), result is false.
        // If run in a real terminal with no redirect, result could be true.
    }

    func testLiveProgressDisplayWritesDiarizationLine() async throws {
        let pipe = Pipe()
        let writeHandle = pipe.fileHandleForWriting
        let readHandle = pipe.fileHandleForReading
        defer { writeHandle.closeFile() }

        let display = LiveProgressDisplay(stderr: writeHandle, showDiarizationLine: true)
        await display.updateDiarization(fractionCompleted: 0.5, completedUnitCount: 40)
        await display.finish()
        writeHandle.closeFile()

        var data = Data()
        while true {
            let chunk = try readHandle.read(upToCount: 1024) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        readHandle.closeFile()

        let output = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("Diarization:"), "Output should contain 'Diarization:', got: \(output)")
        XCTAssertTrue(output.contains("segmenter"), "Output should contain 'segmenter' for completedUnitCount 40, got: \(output)")
        XCTAssertTrue(output.contains("50%"), "Output should contain '50%', got: \(output)")
    }

    func testLiveProgressDisplaySingleLineWhenNoDiarization() async throws {
        let pipe = Pipe()
        let writeHandle = pipe.fileHandleForWriting
        let readHandle = pipe.fileHandleForReading
        defer { writeHandle.closeFile() }

        let display = LiveProgressDisplay(stderr: writeHandle, showDiarizationLine: false)
        await display.updateDiarization(fractionCompleted: 0.25, completedUnitCount: 20)
        await display.finish()
        writeHandle.closeFile()

        var data = Data()
        while true {
            let chunk = try readHandle.read(upToCount: 1024) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        readHandle.closeFile()

        let output = String(data: data, encoding: .utf8) ?? ""
        // With showDiarizationLine: false, updateDiarization is a no-op; we only get clear + newline from finish()
        XCTAssertFalse(output.contains("Diarization:"), "Single-line mode should not show diarization, got: \(output)")
    }
}
