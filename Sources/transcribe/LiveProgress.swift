import Foundation
import WhisperKit

#if canImport(Darwin)
import Darwin
#endif

/// How live transcription/diarization progress is rendered to stderr.
enum LiveProgressRenderMode: Sendable, Equatable {
    /// In-place redraw with ANSI cursor control (for an interactive terminal).
    case tty
    /// Append one snapshot per throttle window as plain lines (works when stderr is a pipe or file).
    case lineLog(minInterval: TimeInterval)
}

/// Returns true if stderr is a TTY (terminal). When false, use plain log lines instead of live progress.
func isStderrTTY() -> Bool {
#if canImport(Darwin)
    return isatty(FileHandle.standardError.fileDescriptor) != 0
#else
    return false
#endif
}

// ANSI escape sequences for terminal cursor control
private let esc = "\u{1B}"
private let clearToEndOfLine = "\(esc)[K"
private let cursorUp = "\(esc)[A"

/// Live progress for transcription (and optionally diarization): TTY in-place redraw or line-log mode for pipes/tests.
/// Updates are serialized via the actor so concurrent callbacks do not interleave output.
/// Both lines are formatted at redraw time so elapsed (and ETA) always use current time.
actor LiveProgressDisplay {
    private let startDate: Date
    private let stderr: FileHandle
    private var transcriptionWindows: Int = 0
    private var diarizationFraction: Double?
    private var diarizationUnitCount: Int64?
    private let showDiarizationLine: Bool
    private var lastLineCount: Int = 0
    private let audioDurationSeconds: Double
    private let historicalWallSecondsPerAudioSecond: Double?
    private let renderMode: LiveProgressRenderMode
    private var lastLineLogEmit: Date?
    private var lastLineLogSignature: String?

    /// - Parameters:
    ///   - startDate: Pipeline start (elapsed includes load/init when set from `runPipeline`).
    ///   - audioDurationSeconds: Decoded audio length in seconds (for history-based ETA on the transcription line).
    ///   - historicalWallSecondsPerAudioSecond: Median `total_wall_s / audio_s` from recent runs, if timing stats enabled.
    ///   - renderMode: `.tty` for cursor updates; `.lineLog` for newline-separated snapshots (e.g. pipes, tests).
    init(
        startDate: Date = Date(),
        stderr: FileHandle = .standardError,
        showDiarizationLine: Bool = true,
        audioDurationSeconds: Double = 0,
        historicalWallSecondsPerAudioSecond: Double? = nil,
        renderMode: LiveProgressRenderMode = .tty
    ) {
        self.startDate = startDate
        self.stderr = stderr
        self.showDiarizationLine = showDiarizationLine
        self.audioDurationSeconds = audioDurationSeconds
        self.historicalWallSecondsPerAudioSecond = historicalWallSecondsPerAudioSecond
        self.renderMode = renderMode
    }

    /// Update the transcription line from WhisperKit progress (windows done).
    func updateTranscription(progress: TranscriptionProgress) {
        transcriptionWindows = Int(progress.timings.totalDecodingWindows)
        redraw()
    }

    /// Update the diarization line from SpeakerKit Progress (fractionCompleted, phase hint).
    /// Takes scalar values to avoid Sendable issues when called from progressCallback.
    func updateDiarization(fractionCompleted: Double, completedUnitCount: Int64) {
        guard showDiarizationLine else { return }
        diarizationFraction = fractionCompleted
        diarizationUnitCount = completedUnitCount
        redraw()
    }

    /// Clear the progress lines and leave cursor after them so subsequent output is clean.
    /// Returns last observed decoding window count (for timing records).
    func finish() -> Int? {
        switch renderMode {
        case .lineLog:
            emitLineLogSnapshot(throttled: false)
            stderr.write("\n".data(using: .utf8)!)
        case .tty:
            redrawTTY(clearOnly: true)
            stderr.write("\n".data(using: .utf8)!)
        }
        let w = transcriptionWindows
        return w > 0 ? w : nil
    }

    private func formatElapsed(since date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        let m = s / 60
        let sec = s % 60
        return String(format: "%dm %ds", m, sec)
    }

    /// Suffix like ` (~48s left)` or ` (~2m 15s left)`; omits zero higher units (no `~0m 48s`).
    private func formatRemainingETASuffix(remainingSeconds: TimeInterval) -> String {
        let s = max(0, Int(remainingSeconds.rounded(.down)))
        guard s > 0 else { return "" }
        if s < 60 {
            return String(format: " (~%ds left)", s)
        }
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 {
            if m == 0, sec == 0 { return String(format: " (~%dh left)", h) }
            if sec == 0 { return String(format: " (~%dh %dm left)", h, m) }
            return String(format: " (~%dh %dm %ds left)", h, m, sec)
        }
        if sec == 0 { return String(format: " (~%dm left)", m) }
        return String(format: " (~%dm %ds left)", m, sec)
    }

    /// ETA string when we have meaningful progress. Empty when not applicable.
    private func formatFractionETA(elapsedSeconds: TimeInterval, fractionCompleted: Double) -> String {
        guard fractionCompleted > 0.05, fractionCompleted < 0.99 else { return "" }
        let totalEstimate = elapsedSeconds / fractionCompleted
        let remaining = totalEstimate - elapsedSeconds
        return formatRemainingETASuffix(remainingSeconds: remaining)
    }

    /// ETA from historical median wall seconds per audio second (full pipeline ratio).
    private func formatHistoryETA(elapsedSeconds: TimeInterval) -> String {
        guard let r = historicalWallSecondsPerAudioSecond, audioDurationSeconds > 0, r > 0 else { return "" }
        let predictedTotal = r * audioDurationSeconds
        let remaining = max(0, predictedTotal - elapsedSeconds)
        return formatRemainingETASuffix(remainingSeconds: remaining)
    }

    private func progressLines(elapsed: String, elapsedSeconds: TimeInterval) -> (String, String?) {
        let state = transcriptionWindows == 0 ? "encoding…" : "\(transcriptionWindows) windows"
        let histETA = formatHistoryETA(elapsedSeconds: elapsedSeconds)
        let line1 = "Transcription: \(state), \(elapsed)\(histETA)"
        guard showDiarizationLine else { return (line1, nil) }
        let line2: String
        if let frac = diarizationFraction, let count = diarizationUnitCount {
            let pct = Int(round(frac * 100))
            let phase = count < 85 ? "segmenter" : "embedder"
            if pct >= 100 {
                line2 = "Diarization: done, \(elapsed)"
            } else {
                let eta = formatFractionETA(elapsedSeconds: elapsedSeconds, fractionCompleted: frac)
                line2 = "Diarization: \(phase) \(pct)%, \(elapsed)\(eta)"
            }
        } else {
            line2 = "Diarization: starting…, \(elapsed)"
        }
        return (line1, line2)
    }

    private func emitLineLogSnapshot(throttled: Bool) {
        guard case .lineLog(let minInterval) = renderMode else { return }
        if throttled {
            let now = Date()
            if let last = lastLineLogEmit, minInterval > 0, now.timeIntervalSince(last) < minInterval {
                return
            }
            lastLineLogEmit = now
        }
        let elapsed = formatElapsed(since: startDate)
        let elapsedSeconds = Date().timeIntervalSince(startDate)
        let (line1, line2) = progressLines(elapsed: elapsed, elapsedSeconds: elapsedSeconds)
        let signature = line1 + "\u{1E}" + (line2 ?? "")
        if !throttled, signature == lastLineLogSignature { return }
        lastLineLogSignature = signature
        write(line1 + "\n")
        if let line2 {
            write(line2 + "\n")
        }
    }

    private func redrawTTY(clearOnly: Bool = false) {
        let linesToDraw = showDiarizationLine ? 2 : 1
        let elapsed = formatElapsed(since: startDate)
        let elapsedSeconds = Date().timeIntervalSince(startDate)

        for _ in 0 ..< lastLineCount {
            write(cursorUp)
        }
        if clearOnly {
            for i in 0 ..< linesToDraw {
                write("\r\(clearToEndOfLine)")
                if i < linesToDraw - 1 { write(cursorUp) }
            }
            lastLineCount = 0
        } else {
            let (line1, line2) = progressLines(elapsed: elapsed, elapsedSeconds: elapsedSeconds)
            write("\r\(clearToEndOfLine)\(line1)")
            if showDiarizationLine, let line2 {
                write("\n")
                write("\r\(clearToEndOfLine)\(line2)")
                write("\r")
                lastLineCount = 1
            } else {
                write("\r")
                lastLineCount = 0
            }
        }
    }

    private func redraw() {
        switch renderMode {
        case .lineLog:
            emitLineLogSnapshot(throttled: true)
        case .tty:
            redrawTTY(clearOnly: false)
        }
    }

    private func write(_ s: String) {
        stderr.write((s).data(using: .utf8)!)
    }
}
