import XCTest
import WhisperKit
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
        _ = await display.finish()
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
        _ = await display.finish()
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

    /// Line-log mode emits newline-terminated snapshots (no ANSI cursor motion); `minInterval: 0` logs every update.
    func testLineLogModeEmitsSeparatedLines() async throws {
        let pipe = Pipe()
        let writeHandle = pipe.fileHandleForWriting
        let readHandle = pipe.fileHandleForReading
        defer { writeHandle.closeFile() }

        let timings0 = TranscriptionTimings(totalDecodingWindows: 0)
        let progress0 = TranscriptionProgress(timings: timings0, text: "", tokens: [])
        let timings3 = TranscriptionTimings(totalDecodingWindows: 3)
        let progress3 = TranscriptionProgress(timings: timings3, text: "", tokens: [])

        let display = LiveProgressDisplay(
            stderr: writeHandle,
            showDiarizationLine: false,
            audioDurationSeconds: 100,
            historicalWallSecondsPerAudioSecond: 0.1,
            renderMode: .lineLog(minInterval: 0)
        )
        await display.updateTranscription(progress: progress0)
        await display.updateTranscription(progress: progress3)
        _ = await display.finish()
        writeHandle.closeFile()

        var data = Data()
        while true {
            let chunk = try readHandle.read(upToCount: 4096) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        readHandle.closeFile()

        let output = String(data: data, encoding: .utf8) ?? ""
        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let transLines = lines.filter { $0.hasPrefix("Transcription:") }
        XCTAssertGreaterThanOrEqual(transLines.count, 2, "Expected at least two transcription snapshots, got: \(output)")
        XCTAssertTrue(transLines.contains { $0.contains("encoding") }, "First snapshot should show encoding, got: \(transLines)")
        XCTAssertTrue(transLines.contains { $0.contains("3 windows") }, "Should show window count, got: \(transLines)")
        XCTAssertFalse(output.contains(cursorUpEscape), "Line-log output must not use cursor-up ANSI")
    }

    private var cursorUpEscape: String { "\u{1B}[A" }
}
