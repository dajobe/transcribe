import Foundation
import WhisperKit

#if canImport(Darwin)
import Darwin
#endif

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

/// Two-line live progress display for transcription and diarization when stderr is a TTY.
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

    /// - Parameters:
    ///   - startDate: Used for elapsed time in both lines.
    ///   - stderr: Where to write (default standardError).
    ///   - showDiarizationLine: If false, only one line is used (transcription-only mode).
    init(startDate: Date = Date(), stderr: FileHandle = .standardError, showDiarizationLine: Bool = true) {
        self.startDate = startDate
        self.stderr = stderr
        self.showDiarizationLine = showDiarizationLine
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
    func finish() {
        redraw(clearOnly: true)
        let data = "\n".data(using: .utf8)!
        stderr.write(data)
    }

    private func formatElapsed(since date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        let m = s / 60
        let sec = s % 60
        return String(format: "%dm %ds", m, sec)
    }

    /// ETA string when we have meaningful progress (e.g. " ~1m 2s left"). Empty when not applicable.
    private func formatETA(elapsedSeconds: TimeInterval, fractionCompleted: Double) -> String {
        guard fractionCompleted > 0.05, fractionCompleted < 0.99 else { return "" }
        let totalEstimate = elapsedSeconds / fractionCompleted
        let remaining = totalEstimate - elapsedSeconds
        let s = max(0, Int(remaining))
        let m = s / 60
        let sec = s % 60
        return String(format: " (~%dm %ds left)", m, sec)
    }

    private func redraw(clearOnly: Bool = false) {
        let linesToDraw = showDiarizationLine ? 2 : 1
        let elapsed = formatElapsed(since: startDate)
        let elapsedSeconds = Date().timeIntervalSince(startDate)

        // Move cursor up to start of our block (from previous position at start of last line)
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
            let state = transcriptionWindows == 0 ? "encoding…" : "\(transcriptionWindows) windows"
            let line1 = "Transcription: \(state), \(elapsed)"
            write("\r\(clearToEndOfLine)\(line1)\n")
            if showDiarizationLine {
                let line2: String
                if let frac = diarizationFraction, let count = diarizationUnitCount {
                    let pct = Int(round(frac * 100))
                    let phase = count < 85 ? "segmenter" : "embedder"
                    if pct >= 100 {
                        line2 = "Diarization: done, \(elapsed)"
                    } else {
                        let eta = formatETA(elapsedSeconds: elapsedSeconds, fractionCompleted: frac)
                        line2 = "Diarization: \(phase) \(pct)%, \(elapsed)\(eta)"
                    }
                } else {
                    line2 = "Diarization: starting…, \(elapsed)"
                }
                write("\r\(clearToEndOfLine)\(line2)")
                write("\r")
                lastLineCount = 1
            } else {
                write("\r")
                lastLineCount = 0
            }
        }
    }

    private func write(_ s: String) {
        stderr.write((s).data(using: .utf8)!)
    }
}
