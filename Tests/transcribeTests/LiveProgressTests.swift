import XCTest
import WhisperKit
@testable import transcribe

final class LiveProgressTests: XCTestCase {
    /// TTY detection is based on stdout because both the live TUI and text
    /// event modes now write processing output there.
    func testIsStdoutTTYReturnsBool() {
        // In XCTest, stdout is typically a pipe, but a local terminal run can
        // differ. This only pins that the helper is callable in tests.
        let result = isStdoutTTY()
        _ = result
    }

    func testLiveProgressDisplayWritesDiarizationLine() async throws {
        let pipe = Pipe()
        let writeHandle = pipe.fileHandleForWriting
        let readHandle = pipe.fileHandleForReading
        defer { writeHandle.closeFile() }

        let display = LiveProgressDisplay(stderr: writeHandle, showDiarizationLine: true)
        display.updateDiarization(fractionCompleted: 0.5, completedUnitCount: 40)
        _ = display.finish()
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
        display.updateDiarization(fractionCompleted: 0.25, completedUnitCount: 20)
        _ = display.finish()
        writeHandle.closeFile()

        var data = Data()
        while true {
            let chunk = try readHandle.read(upToCount: 1024) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        readHandle.closeFile()

        let output = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(output.contains("Diarization:"), "Single-line mode should not show diarization, got: \(output)")
    }

    func testTTYFinishLeavesFinalSnapshot() async throws {
        let pipe = Pipe()
        let writeHandle = pipe.fileHandleForWriting
        let readHandle = pipe.fileHandleForReading
        defer { writeHandle.closeFile() }

        let display = LiveProgressDisplay(
            stderr: writeHandle,
            showDiarizationLine: false,
            audioDurationSeconds: 20
        )
        display.start()
        _ = display.finish()
        writeHandle.closeFile()

        var data = Data()
        while true {
            let chunk = try readHandle.read(upToCount: 4096) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        readHandle.closeFile()

        let output = String(data: data, encoding: .utf8) ?? ""
        let totalLines = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0.contains("Total:") }
        let finalTotalLine = try XCTUnwrap(totalLines.last)
        XCTAssertTrue(finalTotalLine.contains("✓"), "Final snapshot should show total as finished, got: \(output)")
        XCTAssertTrue(finalTotalLine.contains("elapsed"), "Final snapshot should include total elapsed time, got: \(output)")
        XCTAssertFalse(finalTotalLine.contains("ETA"), "Final total line should not keep an ETA, got: \(output)")
        XCTAssertTrue(output.contains("Encoding:"), "Final snapshot should leave phase rows visible, got: \(output)")
    }

    func testLiveProgressDisplayIncludesRunContext() async throws {
        let pipe = Pipe()
        let writeHandle = pipe.fileHandleForWriting
        let readHandle = pipe.fileHandleForReading
        defer { writeHandle.closeFile() }

        let display = LiveProgressDisplay(
            stderr: writeHandle,
            showDiarizationLine: false,
            contextLines: [
                "Session: 1/2",
                "Input: clip.m4a",
                "Output: clip (txt,json) -> /tmp/out [clip.txt, clip.json]",
                "Model: openai_whisper-large-v3-v20240930_turbo",
            ]
        )
        display.start()
        _ = display.finish()
        writeHandle.closeFile()

        let output = String(data: readHandle.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("Session: 1/2"), output)
        XCTAssertTrue(output.contains("Input: clip.m4a"), output)
        XCTAssertTrue(output.contains("Output: clip"), output)
        XCTAssertTrue(output.contains("Model: openai_whisper-large-v3-v20240930_turbo"), output)
    }

    func testDurationFormattingOmitsZeroHigherUnits() async throws {
        let pipe = Pipe()
        let writeHandle = pipe.fileHandleForWriting
        let readHandle = pipe.fileHandleForReading
        defer { writeHandle.closeFile() }

        let display = LiveProgressDisplay(
            stderr: writeHandle,
            showDiarizationLine: false,
            audioDurationSeconds: 3_604,
            historicalRatios: HistoricalTimingRatios(encodingSecondsPerAudioSecond: 1),
            renderMode: .lineLog(minInterval: 0)
        )
        display.start()
        _ = display.finish()
        writeHandle.closeFile()

        var data = Data()
        while true {
            let chunk = try readHandle.read(upToCount: 4096) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        readHandle.closeFile()

        let output = String(data: data, encoding: .utf8) ?? ""
        let finalTotalLine = try XCTUnwrap(
            output
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
                .last { $0.contains("Total:") }
        )
        XCTAssertTrue(finalTotalLine.contains("audio duration 1h 4s"), "Audio duration should omit zero minutes, got: \(finalTotalLine)")
        XCTAssertFalse(finalTotalLine.contains("1h 0m 4s"), "Audio duration should not include zero minutes, got: \(finalTotalLine)")
        XCTAssertTrue(output.contains("ETA ~1h "), "ETA should include hours and omit zero minutes, got: \(output)")
        XCTAssertFalse(output.contains("ETA ~1h 0m 4s"), "ETA should not include zero minutes, got: \(output)")

        let finalEncodingLine = try XCTUnwrap(
            output
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
                .last { $0.contains("Encoding:") }
        )
        XCTAssertTrue(finalEncodingLine.contains("elapsed <1s"), "Sub-second elapsed time should render as <1s, got: \(finalEncodingLine)")
        XCTAssertFalse(finalEncodingLine.contains("elapsed 0s"), "Positive sub-second elapsed time should not render as 0s, got: \(finalEncodingLine)")
        XCTAssertFalse(finalEncodingLine.contains("elapsed 0m"), "Sub-minute elapsed time should not include zero minutes, got: \(finalEncodingLine)")
    }

    func testZeroSecondsIsReservedForTrulyUnstartedPhases() async throws {
        let pipe = Pipe()
        let writeHandle = pipe.fileHandleForWriting
        let readHandle = pipe.fileHandleForReading
        defer { writeHandle.closeFile() }

        let display = LiveProgressDisplay(
            stderr: writeHandle,
            showDiarizationLine: false,
            renderMode: .lineLog(minInterval: 0)
        )
        _ = display.finish()
        writeHandle.closeFile()

        var data = Data()
        while true {
            let chunk = try readHandle.read(upToCount: 4096) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        readHandle.closeFile()

        let output = String(data: data, encoding: .utf8) ?? ""
        let finalEncodingLine = try XCTUnwrap(
            output
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
                .last { $0.contains("Encoding:") }
        )
        XCTAssertTrue(finalEncodingLine.contains("elapsed 0s"), "Unstarted phases completed by finish() should show true zero, got: \(finalEncodingLine)")
        XCTAssertFalse(finalEncodingLine.contains("elapsed <1s"), "Exactly zero elapsed time should not render as <1s, got: \(finalEncodingLine)")
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
        display.start()
        display.updateTranscription(progress: progress0)
        display.updateTranscription(progress: progress3)
        _ = display.finish()
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
        let transLines = lines.filter { $0.contains("Transcription:") }
        let encodingLines = lines.filter { $0.contains("Encoding:") }
        XCTAssertTrue(lines.contains { $0.contains("Total:") }, "Expected a total ETA line, got: \(output)")
        XCTAssertTrue(
            encodingLines.contains { $0.contains("encoding audio") },
            "Initial snapshot should show encoding before callbacks, got: \(encodingLines)"
        )
        XCTAssertGreaterThanOrEqual(transLines.count, 2, "Expected at least two transcription snapshots, got: \(output)")
        XCTAssertTrue(transLines.contains { $0.contains("3 windows") }, "Should show window count, got: \(transLines)")
        XCTAssertTrue(
            transLines.contains { $0.contains("▶") && $0.contains("elapsed") && !$0.contains("windows") },
            "Running transcription should show elapsed time before window counts exist, got: \(transLines)"
        )
        XCTAssertFalse(
            transLines.contains { $0.contains("starting") },
            "Running transcription should not use generic 'starting' filler, got: \(transLines)"
        )
        XCTAssertFalse(output.contains(cursorUpEscape), "Line-log output must not use cursor-up ANSI")
    }

    func testStatusColumnAlignsForLongLabels() async throws {
        let pipe = Pipe()
        let writeHandle = pipe.fileHandleForWriting
        let readHandle = pipe.fileHandleForReading
        defer { writeHandle.closeFile() }

        let display = LiveProgressDisplay(
            stderr: writeHandle,
            showDiarizationLine: true,
            audioDurationSeconds: 20,
            renderMode: .lineLog(minInterval: 0)
        )
        display.start()
        _ = display.finish()
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
        let encoding = try XCTUnwrap(lines.first { $0.contains("Encoding:") && $0.contains("encoding audio") })
        let transcription = try XCTUnwrap(lines.first { $0.contains("Transcription:") && $0.contains("waiting") })
        let diarization = try XCTUnwrap(lines.first { $0.contains("Diarization:") && $0.contains("elapsed") })
        let expectedDetailOffset = try detailOffset(in: encoding, marker: "encoding audio")

        let encodingIndex = try lineIndex(in: lines) { $0.contains("Encoding:") && $0.contains("encoding audio") }
        let diarizationIndex = try lineIndex(in: lines) { $0.contains("Diarization:") && $0.contains("elapsed") }
        let transcriptionIndex = try lineIndex(in: lines) { $0.contains("Transcription:") && $0.contains("waiting") }
        XCTAssertLessThan(encodingIndex, diarizationIndex, "Diarization starts with encoding and should render before waiting transcription: \(lines)")
        XCTAssertLessThan(diarizationIndex, transcriptionIndex, "Waiting transcription should render after already-started diarization: \(lines)")
        XCTAssertEqual(
            try detailOffset(in: diarization, marker: "elapsed"),
            expectedDetailOffset,
            "Running phase detail columns should align in: \(lines)"
        )
        XCTAssertTrue(transcription.hasPrefix("    Transcription:"), "Waiting phases should reserve a blank icon column, got: \(transcription)")
        XCTAssertFalse(transcription.contains("▶"), "Waiting phases should not show the running icon, got: \(transcription)")
        XCTAssertFalse(transcription.contains("✓"), "Waiting phases should not show the finished icon, got: \(transcription)")
    }

    func testEncodingPhaseCanRenderBeforeProgressCallbacksAndUsesEncodingEta() async throws {
        let pipe = Pipe()
        let writeHandle = pipe.fileHandleForWriting
        let readHandle = pipe.fileHandleForReading
        defer { writeHandle.closeFile() }

        let display = LiveProgressDisplay(
            stderr: writeHandle,
            showDiarizationLine: false,
            audioDurationSeconds: 20,
            historicalRatios: HistoricalTimingRatios(
                encodingSecondsPerAudioSecond: 0.5,
                transcriptionSecondsPerAudioSecond: 0.1
            ),
            renderMode: .lineLog(minInterval: 0)
        )
        display.start()
        _ = display.finish()
        writeHandle.closeFile()

        var data = Data()
        while true {
            let chunk = try readHandle.read(upToCount: 4096) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        readHandle.closeFile()

        let output = String(data: data, encoding: .utf8) ?? ""
        let encodingLines = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0.contains("Encoding:") }
        XCTAssertTrue(
            encodingLines.contains { $0.contains("▶") && $0.contains("encoding audio") && $0.contains("ETA ~") },
            "Expected encoding ETA before Whisper callbacks, got: \(output)"
        )
    }

    func testFinishedPhaseShowsElapsedWithoutEta() async throws {
        let pipe = Pipe()
        let writeHandle = pipe.fileHandleForWriting
        let readHandle = pipe.fileHandleForReading
        defer { writeHandle.closeFile() }

        let display = LiveProgressDisplay(
            stderr: writeHandle,
            showDiarizationLine: false,
            audioDurationSeconds: 20,
            historicalRatios: HistoricalTimingRatios(encodingSecondsPerAudioSecond: 0.5),
            renderMode: .lineLog(minInterval: 0)
        )
        display.start()
        _ = display.finish()
        writeHandle.closeFile()

        var data = Data()
        while true {
            let chunk = try readHandle.read(upToCount: 4096) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        readHandle.closeFile()

        let output = String(data: data, encoding: .utf8) ?? ""
        let encodingLines = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0.contains("Encoding:") }
        let finalEncodingLine = try XCTUnwrap(encodingLines.last)
        XCTAssertTrue(finalEncodingLine.contains("✓"), "Finished line should show state, got: \(finalEncodingLine)")
        XCTAssertTrue(finalEncodingLine.contains("elapsed"), "Finished line should show final elapsed time, got: \(finalEncodingLine)")
        XCTAssertFalse(finalEncodingLine.contains("ETA"), "Finished line should not keep updating ETA, got: \(finalEncodingLine)")
        let finalTotalLine = try XCTUnwrap(
            output
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
                .last { $0.contains("Total:") }
        )
        XCTAssertTrue(finalTotalLine.contains("✓"), "Finished total line should show state, got: \(finalTotalLine)")
        XCTAssertTrue(finalTotalLine.contains("elapsed"), "Finished total line should show total elapsed time, got: \(finalTotalLine)")
        XCTAssertFalse(finalTotalLine.contains("ETA"), "Finished total line should not keep an ETA, got: \(finalTotalLine)")
    }

    func testSetupAudioAndOutputLinesRenderWithIconsAndDuration() async throws {
        let pipe = Pipe()
        let writeHandle = pipe.fileHandleForWriting
        let readHandle = pipe.fileHandleForReading
        defer { writeHandle.closeFile() }

        let display = LiveProgressDisplay(
            stderr: writeHandle,
            showDiarizationLine: false,
            renderMode: .lineLog(minInterval: 0)
        )
        display.beginAudioChecking()
        display.finishAudioChecking()
        display.beginModelLoading()
        display.finishModelLoading()
        display.beginAudioLoading()
        display.finishAudioLoading(durationSeconds: 125)
        display.beginEncoding()
        _ = display.finishProcessing()
        display.beginOutput()
        display.finishOutput()
        _ = display.finish()
        writeHandle.closeFile()

        var data = Data()
        while true {
            let chunk = try readHandle.read(upToCount: 4096) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        readHandle.closeFile()

        let output = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("▶ Input Check:") && output.contains("checking audio"), "Audio checking should render immediately, got: \(output)")
        XCTAssertTrue(output.contains("✓ Input Check:"), "Finished input checking should show a checkmark, got: \(output)")
        XCTAssertTrue(output.contains("▶ Model Loading:"), "Model loading should render immediately, got: \(output)")
        XCTAssertTrue(output.contains("✓ Model Loading:"), "Finished model loading should show a checkmark, got: \(output)")
        XCTAssertTrue(output.contains("loading audio"), "Audio loading should update the running audio phase, got: \(output)")
        XCTAssertTrue(output.contains("    Transcription:  waiting"), "Waiting transcription should reserve a blank icon column, got: \(output)")
        XCTAssertTrue(output.contains("✓ Output:"), "Finished output writing should show a checkmark, got: \(output)")
        let finalAudioLine = try XCTUnwrap(
            output
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
                .last { $0.contains("Audio:") && $0.contains("✓") }
        )
        XCTAssertTrue(finalAudioLine.contains("elapsed"), "Finished audio line should show elapsed task time, got: \(finalAudioLine)")
        XCTAssertFalse(finalAudioLine.contains("elapsed 0m"), "Finished audio line should show seconds only under a minute, got: \(finalAudioLine)")
        XCTAssertFalse(finalAudioLine.contains("duration"), "Finished audio line should not duplicate audio duration, got: \(finalAudioLine)")
        let finalTotalLine = try XCTUnwrap(
            output
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
                .last { $0.contains("Total:") }
        )
        XCTAssertTrue(finalTotalLine.contains("✓"), "Final total should show a checkmark, got: \(finalTotalLine)")
        XCTAssertTrue(finalTotalLine.contains("elapsed"), "Final total should include total elapsed time, got: \(finalTotalLine)")
        XCTAssertTrue(finalTotalLine.contains("audio duration 2m 5s"), "Final total should include audio duration, got: \(finalTotalLine)")
        XCTAssertLessThan(
            try detailOffset(in: finalTotalLine, marker: "elapsed"),
            try detailOffset(in: finalTotalLine, marker: "audio duration"),
            "Final total should put task elapsed time before audio duration, got: \(finalTotalLine)"
        )

        let lines = output.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertFalse(
            lines.contains { $0.contains("Audio:") && $0.contains("checking audio") },
            "Audio loading should not inherit the input-check activity: \(lines)"
        )
        let inputCheckIndex = try lineIndex(in: lines) { $0.contains("Input Check:") && $0.contains("checking audio") }
        let modelIndex = try lineIndex(in: lines) { $0.contains("Model Loading:") && $0.contains("loading models") }
        let audioIndex = try lineIndex(in: lines) { $0.contains("Audio:") && $0.contains("loading audio") }
        XCTAssertLessThan(inputCheckIndex, modelIndex, "Input checking starts before model loading and should render first: \(lines)")
        XCTAssertLessThan(modelIndex, audioIndex, "Audio loading starts after model loading and should render later: \(lines)")
    }

    func testOutputCompletionSnapshotDoesNotKeepTotalRunningEta() async throws {
        let pipe = Pipe()
        let writeHandle = pipe.fileHandleForWriting
        let readHandle = pipe.fileHandleForReading
        defer { writeHandle.closeFile() }

        let display = LiveProgressDisplay(
            stderr: writeHandle,
            showDiarizationLine: false,
            audioDurationSeconds: 3,
            historicalRatios: HistoricalTimingRatios(
                encodingSecondsPerAudioSecond: 0.1,
                transcriptionSecondsPerAudioSecond: 0.1,
                outputSecondsPerAudioSecond: 0.1
            ),
            renderMode: .lineLog(minInterval: 0)
        )
        display.beginAudioChecking()
        display.finishAudioChecking()
        display.beginModelLoading()
        display.finishModelLoading()
        display.beginAudioLoading()
        display.finishAudioLoading(durationSeconds: 3)
        display.beginEncoding()
        _ = display.finishProcessing()
        display.beginOutput()
        display.finishOutput()
        _ = display.finish()
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
        let finishedOutputIndexes = lines.indices.filter {
            lines[$0].contains("✓ Output:")
        }
        XCTAssertFalse(finishedOutputIndexes.isEmpty, "Expected at least one finished Output snapshot, got: \(output)")
        for index in finishedOutputIndexes {
            let totalIndex = try XCTUnwrap(
                lines[..<index].lastIndex { $0.contains("Total:") },
                "Expected a Total line before finished Output in: \(lines)"
            )
            let totalLine = lines[totalIndex]
            XCTAssertTrue(totalLine.contains("✓ Total:"), "Finished output snapshots should show total as done, got: \(totalLine)")
            XCTAssertFalse(totalLine.contains("ETA"), "Finished output snapshots should not keep total ETA, got: \(totalLine)")
        }
    }

    func testTTYFinishDoesNotRedrawCompletedOutputSnapshot() async throws {
        let pipe = Pipe()
        let writeHandle = pipe.fileHandleForWriting
        let readHandle = pipe.fileHandleForReading
        defer { writeHandle.closeFile() }

        let display = LiveProgressDisplay(
            stderr: writeHandle,
            showDiarizationLine: false,
            audioDurationSeconds: 3,
            historicalRatios: HistoricalTimingRatios(
                encodingSecondsPerAudioSecond: 0.1,
                transcriptionSecondsPerAudioSecond: 0.1,
                outputSecondsPerAudioSecond: 0.1
            ),
            renderMode: .tty
        )
        display.beginAudioChecking()
        display.finishAudioChecking()
        display.beginModelLoading()
        display.finishModelLoading()
        display.beginAudioLoading()
        display.finishAudioLoading(durationSeconds: 3)
        display.beginEncoding()
        _ = display.finishProcessing()
        display.beginOutput()
        display.finishOutput()
        _ = display.finish()
        writeHandle.closeFile()

        var data = Data()
        while true {
            let chunk = try readHandle.read(upToCount: 4096) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        readHandle.closeFile()

        let output = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(
            output.components(separatedBy: "✓ Total:").count - 1,
            1,
            "TTY finish should not repaint an already completed output snapshot, got: \(output)"
        )
        XCTAssertEqual(
            output.components(separatedBy: "✓ Output:").count - 1,
            1,
            "TTY finish should leave the finished Output line from finishOutput(), got: \(output)"
        )
    }

    func testTTYRedrawCountsWrappedTerminalRows() async throws {
        let pipe = Pipe()
        let writeHandle = pipe.fileHandleForWriting
        let readHandle = pipe.fileHandleForReading
        defer { writeHandle.closeFile() }

        let display = LiveProgressDisplay(
            stderr: writeHandle,
            showDiarizationLine: false,
            contextLines: [
                "Session: 56/56",
                "Input: 20260719 173043-BE1F8B9A.qta",
                "Output: a deliberately long output description that wraps on a narrow terminal",
                "Model: openai_whisper-large-v3-v20240930_turbo",
            ],
            renderMode: .tty,
            ttyColumnCountOverride: 40
        )
        display.beginAudioChecking()
        _ = display.finish()
        writeHandle.closeFile()

        let output = String(data: readHandle.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertGreaterThan(
            output.components(separatedBy: cursorUpEscape).count - 1,
            7,
            "TTY redraw should move over physical rows added by wrapping: \(output)"
        )
    }

    func testTerminalRowCountUsesDisplayCellsAndTerminalWidth() {
        XCTAssertEqual(terminalDisplayWidth("✓ Total"), 7)
        XCTAssertEqual(terminalRowCount(["12345", "123456", ""], columns: 5), 4)
        XCTAssertEqual(terminalRowCount(["12345", "123456", ""], columns: nil), 3)
    }

    func testOverallEtaUsesParallelDiarizationPath() async throws {
        let pipe = Pipe()
        let writeHandle = pipe.fileHandleForWriting
        let readHandle = pipe.fileHandleForReading
        defer { writeHandle.closeFile() }

        let display = LiveProgressDisplay(
            stderr: writeHandle,
            showDiarizationLine: true,
            audioDurationSeconds: 10,
            historicalRatios: HistoricalTimingRatios(
                encodingSecondsPerAudioSecond: 1,
                transcriptionSecondsPerAudioSecond: 1,
                diarizationSecondsPerAudioSecond: 5
            ),
            renderMode: .lineLog(minInterval: 0)
        )
        display.start()
        _ = display.finish()
        writeHandle.closeFile()

        var data = Data()
        while true {
            let chunk = try readHandle.read(upToCount: 4096) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        readHandle.closeFile()

        let output = String(data: data, encoding: .utf8) ?? ""
        let totalLines = output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0.contains("Total:") }
        XCTAssertTrue(
            totalLines.contains { $0.contains("ETA ~49s") || $0.contains("ETA ~50s") },
            "Expected total ETA to use max(transcription path, diarization path), got: \(totalLines)"
        )
    }

    func testDiagnosticsRenderBelowPhaseRowsAndRemainInFinalSnapshot() async throws {
        let pipe = Pipe()
        let writeHandle = pipe.fileHandleForWriting
        let readHandle = pipe.fileHandleForReading
        defer { writeHandle.closeFile() }

        let display = LiveProgressDisplay(
            stderr: writeHandle,
            showDiarizationLine: false,
            renderMode: .lineLog(minInterval: 0)
        )
        display.start()
        display.appendDiagnostic(TranscribeEvent(
            level: .debug,
            name: "verbose",
            fields: [TranscribeEventField("elapsed_s", .double(4.2))],
            message: "loaded model cache metadata"
        ))
        _ = display.finish()
        writeHandle.closeFile()

        let output = String(data: readHandle.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(output.contains("Diagnostics:"), output)
        XCTAssertTrue(
            output.contains(#"DEBUG event=verbose elapsed_s=4.2 message="loaded model cache metadata""#),
            output
        )

        let finalTotalRange = try XCTUnwrap(output.range(of: "✓ Total:", options: .backwards))
        let finalDiagnosticsRange = try XCTUnwrap(output.range(of: "Diagnostics:", options: .backwards))
        XCTAssertGreaterThan(
            output.distance(from: output.startIndex, to: finalDiagnosticsRange.lowerBound),
            output.distance(from: output.startIndex, to: finalTotalRange.lowerBound),
            "Final snapshot should retain diagnostics below the phase rows, got: \(output)"
        )
    }

    func testDiagnosticsAreBoundedToLastFive() async throws {
        let pipe = Pipe()
        let writeHandle = pipe.fileHandleForWriting
        let readHandle = pipe.fileHandleForReading
        defer { writeHandle.closeFile() }

        let display = LiveProgressDisplay(
            stderr: writeHandle,
            showDiarizationLine: false,
            renderMode: .lineLog(minInterval: 0)
        )
        display.start()
        for index in 1...6 {
            display.appendDiagnostic(TranscribeEvent(
                level: .warn,
                name: "warning",
                message: "diagnostic \(index)"
            ))
        }
        _ = display.finish()
        writeHandle.closeFile()

        let output = String(data: readHandle.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let header = "Diagnostics (last 5 of 6):"
        let headerRange = try XCTUnwrap(output.range(of: header, options: .backwards))
        let finalBlock = String(output[headerRange.lowerBound...])
        XCTAssertFalse(finalBlock.contains(#"message="diagnostic 1""#), finalBlock)
        for index in 2...6 {
            XCTAssertTrue(finalBlock.contains(#"message="diagnostic \#(index)""#), finalBlock)
        }
    }

    func testFailureSnapshotShowsFailedTotalAndLeavesUnfinishedPhasesRunning() async throws {
        let pipe = Pipe()
        let writeHandle = pipe.fileHandleForWriting
        let readHandle = pipe.fileHandleForReading
        defer { writeHandle.closeFile() }

        let display = LiveProgressDisplay(
            stderr: writeHandle,
            showDiarizationLine: false,
            renderMode: .lineLog(minInterval: 0)
        )
        display.beginModelLoading()
        display.appendDiagnostic(TranscribeEvent(
            level: .error,
            name: "run_failed",
            fields: [TranscribeEventField("exit", .int(3))],
            message: "model failed"
        ))
        display.fail()
        writeHandle.closeFile()

        let output = String(data: readHandle.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let failedTotalRange = try XCTUnwrap(output.range(of: "✕ Total:", options: .backwards))
        let finalBlock = String(output[failedTotalRange.lowerBound...])
        XCTAssertTrue(finalBlock.contains("failed after"), finalBlock)
        XCTAssertTrue(finalBlock.contains(#"ERROR event=run_failed exit=3 message="model failed""#), finalBlock)
        XCTAssertTrue(finalBlock.contains("▶ Model Loading:"), finalBlock)
        XCTAssertFalse(finalBlock.contains("✓ Model Loading:"), finalBlock)
    }

    func testUpdatesAfterFinishAreIgnored() throws {
        let pipe = Pipe()
        let writeHandle = pipe.fileHandleForWriting
        let readHandle = pipe.fileHandleForReading
        defer { writeHandle.closeFile() }

        let display = LiveProgressDisplay(stderr: writeHandle, showDiarizationLine: true)
        _ = display.finish()
        display.updateDiarization(fractionCompleted: 0.75, completedUnitCount: 99)
        writeHandle.closeFile()

        var data = Data()
        while true {
            let chunk = try readHandle.read(upToCount: 1024) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        readHandle.closeFile()

        let output = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(output.contains("75%"), "updates after finish should be dropped, got: \(output)")
        XCTAssertFalse(output.contains("embedder"), "updates after finish should be dropped, got: \(output)")
    }

    private func detailOffset(in line: String, marker: String) throws -> Int {
        let index = try XCTUnwrap(line.range(of: marker)?.lowerBound.samePosition(in: line.utf8))
        return line.utf8.distance(from: line.utf8.startIndex, to: index)
    }

    private func lineIndex(in lines: [String], matching predicate: (String) -> Bool) throws -> Int {
        try XCTUnwrap(lines.firstIndex(where: predicate))
    }

    private var cursorUpEscape: String { "\u{1B}[A" }
}
