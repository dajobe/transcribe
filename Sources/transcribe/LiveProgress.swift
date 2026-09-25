import Foundation
import WhisperKit

#if canImport(Darwin)
import Darwin
#endif

/// How live transcription/diarization progress is rendered to the user.
enum LiveProgressRenderMode: Sendable, Equatable {
    /// In-place redraw with ANSI cursor control (for an interactive terminal).
    case tty
    /// Append one snapshot per throttle window as plain lines.
    case lineLog(minInterval: TimeInterval)
}

/// Returns true if stdout is a TTY (terminal).
func isStdoutTTY() -> Bool {
#if canImport(Darwin)
    return isatty(FileHandle.standardOutput.fileDescriptor) != 0
#else
    return false
#endif
}

// ANSI escape sequences for terminal cursor control.
private let esc = "\u{1B}"
private let clearToEndOfLine = "\(esc)[K"
private let clearToEndOfScreen = "\(esc)[J"
private let cursorUp = "\(esc)[A"
private let runningIcon = "▶"
private let doneIcon = "✓"
private let failedIcon = "✕"
private let inactiveIcon = " "
private let maxDiagnosticLines = 5

private func terminalColumnCount(_ fileHandle: FileHandle) -> Int? {
#if canImport(Darwin)
    var windowSize = winsize()
    guard ioctl(fileHandle.fileDescriptor, TIOCGWINSZ, &windowSize) == 0,
          windowSize.ws_col > 0
    else { return nil }
    return Int(windowSize.ws_col)
#else
    return nil
#endif
}

func terminalDisplayWidth(_ text: String) -> Int {
    var width = 0
    for character in text {
        if character == "\t" {
            width += 8 - (width % 8)
            continue
        }
        var characterWidth = 0
        var emojiPresentation = false
        for scalar in character.unicodeScalars {
            emojiPresentation = emojiPresentation
                || scalar.properties.isEmojiPresentation
                || scalar.value == 0xFE0F
#if canImport(Darwin)
            let measuredWidth = Int(wcwidth(wchar_t(scalar.value)))
            if measuredWidth >= 0 {
                characterWidth = max(characterWidth, measuredWidth)
                continue
            }
#endif
            switch scalar.properties.generalCategory {
            case .control, .enclosingMark, .format, .nonspacingMark:
                continue
            default:
                characterWidth = max(characterWidth, isWideTerminalScalar(scalar.value) ? 2 : 1)
            }
        }
        width += emojiPresentation ? max(characterWidth, 2) : characterWidth
    }
    return width
}

private func isWideTerminalScalar(_ value: UInt32) -> Bool {
    switch value {
    case 0x1100 ... 0x115F,
         0x2329 ... 0x232A,
         0x2E80 ... 0x303E,
         0x3040 ... 0xA4CF,
         0xAC00 ... 0xD7A3,
         0xF900 ... 0xFAFF,
         0xFE10 ... 0xFE19,
         0xFE30 ... 0xFE6F,
         0xFF00 ... 0xFF60,
         0xFFE0 ... 0xFFE6,
         0x1F300 ... 0x1FAFF,
         0x20000 ... 0x3FFFD:
        return true
    default:
        return false
    }
}

func terminalRowCount(_ lines: [String], columns: Int?) -> Int {
    guard let columns, columns > 0 else { return lines.count }
    return lines.reduce(0) { count, line in
        let width = terminalDisplayWidth(line)
        return count + max(1, (max(width, 1) - 1) / columns + 1)
    }
}

private enum LivePhaseState: Equatable {
    case waiting
    case running(startedAt: Date)
    case done(duration: TimeInterval)

    var isDone: Bool {
        if case .done = self { return true }
        return false
    }
}

/// Live progress for overall ETA plus independent phase lines.
///
/// Updates are serialized on a private queue so sync progress callbacks can
/// safely forward updates. TTY mode redraws a fixed block of lines in place;
/// line-log mode emits throttled snapshots without ANSI cursor movement.
final class LiveProgressDisplay {
    private let startDate: Date
    private let stderr: FileHandle
    private let queue = DispatchQueue(label: "transcribe.live-progress")
    private let showDiarizationLine: Bool
    private let contextLines: [String]
    private var audioDurationSeconds: Double
    private let historicalRatios: HistoricalTimingRatios
    private let renderMode: LiveProgressRenderMode
    private let ttyColumnCountOverride: Int?
    private let clock: () -> Date

    private var showModelLine: Bool = false
    private var showInputCheckLine: Bool = false
    private var showAudioLine: Bool = false
    private var modelState: LivePhaseState = .waiting
    private var inputCheckState: LivePhaseState = .waiting
    private var audioState: LivePhaseState = .waiting
    private var audioActivity: String = "loading audio"
    private var encodingState: LivePhaseState = .waiting
    private var transcriptionState: LivePhaseState = .waiting
    private var diarizationState: LivePhaseState = .waiting
    private var outputState: LivePhaseState = .waiting

    private var transcriptionWindows: Int = 0
    private var firstTranscriptionProgressDate: Date?
    /// Start of the transcribe (+ diarize) block; the processing ETA counts from here.
    private var processingStartedAt: Date?
    private var transcriptionProgress = PhaseProgressTracker()
    private var transcriptionUnitSource: (() -> (completed: Int64, total: Int64))?
    private var diarizationProgress = PhaseProgressTracker()
    private var diarizationFraction: Double?
    private var diarizationUnitCount: Int64?
    private var isFinished: Bool = false
    private var finishedAt: Date?
    private var failedAt: Date?
    private var workCompletedAt: Date?
    private var redrawTimer: DispatchSourceTimer?
    private var drawnTTYLines: [String] = []
    private var lastLineLogEmit: Date?
    private var lastLineLogSignature: String?
    private var diagnosticLines: [String] = []
    private var diagnosticCount: Int = 0

    /// - Parameters:
    ///   - startDate: Session or pipeline start for the overall elapsed line.
    ///   - audioDurationSeconds: Estimated or decoded audio length in seconds.
    ///   - historicalRatios: Per-phase and total history ratios for ETA.
    ///   - renderMode: `.tty` for cursor updates; `.lineLog` for newline-separated snapshots.
    ///   - clock: Time source; tests inject a controllable clock.
    init(
        startDate: Date = Date(),
        stderr: FileHandle = .standardOutput,
        showDiarizationLine: Bool = true,
        contextLines: [String] = [],
        audioDurationSeconds: Double = 0,
        historicalRatios: HistoricalTimingRatios = HistoricalTimingRatios(),
        historicalWallSecondsPerAudioSecond: Double? = nil,
        renderMode: LiveProgressRenderMode = .tty,
        ttyColumnCountOverride: Int? = nil,
        clock: @escaping () -> Date = Date.init
    ) {
        self.startDate = startDate
        self.stderr = stderr
        self.showDiarizationLine = showDiarizationLine
        self.contextLines = contextLines
        self.audioDurationSeconds = audioDurationSeconds
        var resolvedRatios = historicalRatios
        if resolvedRatios.totalSecondsPerAudioSecond == nil {
            resolvedRatios.totalSecondsPerAudioSecond = historicalWallSecondsPerAudioSecond
        }
        self.historicalRatios = resolvedRatios
        self.renderMode = renderMode
        self.ttyColumnCountOverride = ttyColumnCountOverride
        self.clock = clock
    }

    /// Emit an immediate encoding snapshot and keep elapsed/ETA moving while waiting for model callbacks.
    func start() {
        beginEncoding()
    }

    /// Install a source of completed/total transcription work units (WhisperKit's
    /// `Progress`, one unit per VAD chunk). It is polled on redraws and on every
    /// transcription callback while the processing block is running.
    ///
    /// - Parameter batchSize: Chunks WhisperKit decodes concurrently; pace
    ///   samples at batch boundaries are preferred (see `PhaseProgressTracker`).
    func setTranscriptionUnitSource(
        batchSize: Int = 0,
        _ source: (() -> (completed: Int64, total: Int64))?
    ) {
        queue.sync {
            self.transcriptionUnitSource = source
            self.transcriptionProgress.batchSize = Int64(max(0, batchSize))
        }
    }

    /// Record completed/total transcription work units directly.
    func updateTranscriptionUnits(completed: Int64, total: Int64) {
        queue.async {
            guard !self.isFinished else { return }
            self.recordTranscriptionUnitsLocked(completed: completed, total: total)
            self.redraw()
        }
    }

    private func recordTranscriptionUnitsLocked(completed: Int64, total: Int64) {
        guard let processingStartedAt, !transcriptionState.isDone else { return }
        transcriptionProgress.record(
            completed: completed,
            total: total,
            elapsed: clock().timeIntervalSince(processingStartedAt)
        )
    }

    private func sampleTranscriptionUnitsLocked() {
        guard let transcriptionUnitSource, processingStartedAt != nil, !transcriptionState.isDone else { return }
        let units = transcriptionUnitSource()
        recordTranscriptionUnitsLocked(completed: units.completed, total: units.total)
    }

    func appendDiagnostic(_ event: TranscribeEvent) {
        guard event.level != .info else { return }
        queue.sync {
            self.diagnosticCount += 1
            self.diagnosticLines.append(Self.compactDiagnosticLine(event))
            if self.diagnosticLines.count > maxDiagnosticLines {
                self.diagnosticLines.removeFirst(self.diagnosticLines.count - maxDiagnosticLines)
            }
            self.redraw()
        }
    }

    func beginModelLoading() {
        queue.sync {
            guard !self.isFinished else { return }
            self.showModelLine = true
            self.modelState = .running(startedAt: clock())
            self.redraw()
            self.startTimerIfNeeded()
        }
    }

    func finishModelLoading() {
        queue.sync {
            guard !self.isFinished else { return }
            self.showModelLine = true
            self.modelState = self.doneState(self.modelState, at: clock())
            self.redraw()
        }
    }

    func beginAudioChecking() {
        queue.sync {
            guard !self.isFinished else { return }
            self.showInputCheckLine = true
            if case .waiting = self.inputCheckState {
                self.inputCheckState = .running(startedAt: clock())
            }
            self.redraw()
            self.startTimerIfNeeded()
        }
    }

    func finishAudioChecking() {
        queue.sync {
            guard !self.isFinished else { return }
            self.showInputCheckLine = true
            self.inputCheckState = self.doneState(self.inputCheckState, at: clock())
            self.redraw()
        }
    }

    func beginAudioLoading() {
        queue.sync {
            guard !self.isFinished else { return }
            self.showAudioLine = true
            self.audioActivity = "loading audio"
            if case .waiting = self.audioState {
                self.audioState = .running(startedAt: clock())
            }
            self.redraw()
            self.startTimerIfNeeded()
        }
    }

    /// Seed the audio length from container metadata so audio-scaled ETAs can
    /// render before decoding. Ignored once a decoded duration is known.
    func updateEstimatedAudioDuration(_ durationSeconds: Double) {
        queue.sync {
            guard !self.isFinished, durationSeconds > 0, !self.audioState.isDone else { return }
            self.audioDurationSeconds = durationSeconds
            self.redraw()
        }
    }

    func finishAudioLoading(durationSeconds: Double) {
        queue.sync {
            guard !self.isFinished else { return }
            self.showAudioLine = true
            if durationSeconds > 0 {
                self.audioDurationSeconds = durationSeconds
            }
            self.audioState = self.doneState(self.audioState, at: clock())
            self.redraw()
        }
    }

    func beginEncoding() {
        queue.sync {
            guard !self.isFinished else { return }
            let now = clock()
            if case .waiting = self.encodingState {
                self.encodingState = .running(startedAt: now)
            }
            if self.processingStartedAt == nil {
                self.processingStartedAt = now
            }
            if self.showDiarizationLine, case .waiting = self.diarizationState {
                self.diarizationState = .running(startedAt: now)
            }
            self.redraw()
            self.startTimerIfNeeded()
        }
    }

    /// Update the transcription line from a WhisperKit progress callback.
    func updateTranscription(progress: TranscriptionProgress) {
        queue.async {
            guard !self.isFinished else { return }
            let now = self.clock()
            if self.firstTranscriptionProgressDate == nil {
                self.firstTranscriptionProgressDate = now
                self.encodingState = self.doneState(self.encodingState, at: now)
                self.transcriptionState = .running(startedAt: now)
            }
            self.transcriptionWindows = Int(progress.timings.totalDecodingWindows)
            self.sampleTranscriptionUnitsLocked()
            self.redraw()
        }
    }

    /// Update the diarization line from SpeakerKit Progress (fractionCompleted, phase hint).
    /// Takes scalar values to avoid type-capture issues when called from progressCallback.
    func updateDiarization(fractionCompleted: Double, completedUnitCount: Int64) {
        queue.async {
            guard self.showDiarizationLine, !self.isFinished else { return }
            let now = self.clock()
            if case .waiting = self.diarizationState {
                self.diarizationState = .running(startedAt: now)
            }
            self.diarizationFraction = fractionCompleted
            self.diarizationUnitCount = completedUnitCount
            if case .running(let startedAt) = self.diarizationState {
                self.diarizationProgress.record(
                    fraction: fractionCompleted,
                    elapsed: now.timeIntervalSince(startedAt)
                )
            }
            if fractionCompleted >= 0.995 {
                self.diarizationState = self.doneState(self.diarizationState, at: now)
            }
            self.redraw()
        }
    }

    func beginOutput() {
        queue.sync {
            guard !self.isFinished else { return }
            let now = clock()
            self.workCompletedAt = nil
            self.encodingState = self.doneState(self.encodingState, at: now)
            self.transcriptionState = self.doneState(self.transcriptionState, at: now)
            if self.showDiarizationLine {
                self.diarizationState = self.doneState(self.diarizationState, at: now)
            }
            self.outputState = .running(startedAt: now)
            self.redraw()
        }
    }

    func finishOutput() {
        queue.sync {
            guard !self.isFinished else { return }
            let now = clock()
            self.outputState = self.doneState(self.outputState, at: now)
            self.workCompletedAt = now
            self.redraw()
        }
    }

    /// Mark transcription/diarization phases complete without freezing the whole display.
    /// Returns last observed decoding window count (for timing records).
    func finishProcessing() -> Int? {
        queue.sync {
            guard !isFinished else {
                let windows = transcriptionWindows
                return windows > 0 ? windows : nil
            }

            finishProcessingLocked(at: clock())
            redraw()

            let windows = transcriptionWindows
            return windows > 0 ? windows : nil
        }
    }

    /// Leave a final progress snapshot and move the cursor after it.
    /// Returns last observed decoding window count (for timing records).
    func finish() -> Int? {
        queue.sync {
            guard !isFinished else {
                let windows = transcriptionWindows
                return windows > 0 ? windows : nil
            }

            let alreadyRenderedCompletedTTY = workCompletedAt != nil && renderMode == .tty
            let now = workCompletedAt ?? clock()
            finishProcessingLocked(at: now)
            if case .waiting = outputState {
                // No output phase was shown for this display.
            } else {
                outputState = doneState(outputState, at: now)
            }
            finishedAt = now
            isFinished = true
            redrawTimer?.cancel()
            redrawTimer = nil

            switch renderMode {
            case .lineLog:
                emitLineLogSnapshot(throttled: false)
                stderr.write("\n".data(using: .utf8)!)
            case .tty:
                if !alreadyRenderedCompletedTTY {
                    redrawTTY()
                }
                stderr.write("\n".data(using: .utf8)!)
            }

            let windows = transcriptionWindows
            return windows > 0 ? windows : nil
        }
    }

    func fail() {
        queue.sync {
            guard !isFinished else { return }

            failedAt = clock()
            isFinished = true
            redrawTimer?.cancel()
            redrawTimer = nil

            switch renderMode {
            case .lineLog:
                emitLineLogSnapshot(throttled: false)
                stderr.write("\n".data(using: .utf8)!)
            case .tty:
                redrawTTY()
                stderr.write("\n".data(using: .utf8)!)
            }
        }
    }

    private func finishProcessingLocked(at date: Date) {
        if showModelLine {
            modelState = doneState(modelState, at: date)
        }
        if showInputCheckLine {
            inputCheckState = doneState(inputCheckState, at: date)
        }
        if showAudioLine {
            audioState = doneState(audioState, at: date)
        }
        encodingState = doneState(encodingState, at: date)
        transcriptionState = doneState(transcriptionState, at: date)
        if showDiarizationLine {
            diarizationState = doneState(diarizationState, at: date)
        }
        transcriptionUnitSource = nil
        transcriptionProgress.markComplete()
    }

    func firstTranscriptionProgressMs(since date: Date) -> Int64? {
        queue.sync {
            guard let firstTranscriptionProgressDate else { return nil }
            return Int64(firstTranscriptionProgressDate.timeIntervalSince(date) * 1000.0)
        }
    }

    private func doneState(_ state: LivePhaseState, at date: Date) -> LivePhaseState {
        guard !state.isDone else { return state }
        switch state {
        case .waiting:
            return .done(duration: 0)
        case .running(let startedAt):
            return .done(duration: date.timeIntervalSince(startedAt))
        case .done:
            return state
        }
    }

    private func formatElapsed(since date: Date) -> String {
        formatDuration(clock().timeIntervalSince(date))
    }

    private func formatDuration(_ interval: TimeInterval) -> String {
        let clampedInterval = max(0, interval)
        if clampedInterval > 0, clampedInterval < 1 {
            return "<1s"
        }
        let s = Int(clampedInterval.rounded(.down))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        var parts: [String] = []
        if h > 0 {
            parts.append("\(h)h")
        }
        if m > 0 {
            parts.append("\(m)m")
        }
        if sec > 0 || parts.isEmpty {
            parts.append("\(sec)s")
        }
        return parts.joined(separator: " ")
    }

    /// Suffix like ` (~48s left)` or ` (~2m 15s left)`.
    private func formatRemainingETASuffix(_ remainingSeconds: TimeInterval?) -> String {
        guard let remainingSeconds, remainingSeconds > 0 else { return "" }
        return " (~\(formatDuration(remainingSeconds)) left)"
    }

    private func estimatedDuration(ratio: Double?) -> TimeInterval? {
        guard let ratio, ratio > 0, audioDurationSeconds > 0 else { return nil }
        return ratio * audioDurationSeconds
    }

    /// Remaining time for a phase with a fixed duration estimate and no live progress signal.
    private func remainingForPhase(_ state: LivePhaseState, estimatedDuration: TimeInterval?) -> TimeInterval? {
        guard let estimatedDuration, estimatedDuration > 0 else { return nil }
        switch state {
        case .waiting:
            return estimatedDuration
        case .running(let startedAt):
            return max(0, estimatedDuration - clock().timeIntervalSince(startedAt))
        case .done:
            return 0
        }
    }

    private func modelLoadRemaining() -> TimeInterval? {
        remainingForPhase(modelState, estimatedDuration: historicalRatios.modelLoadSeconds)
    }

    private func audioLoadRemaining() -> TimeInterval? {
        remainingForPhase(
            audioState,
            estimatedDuration: estimatedDuration(ratio: historicalRatios.audioLoadSecondsPerAudioSecond)
        )
    }

    /// The encoding line covers warm-up until WhisperKit's first callback, which
    /// takes roughly constant time regardless of audio length.
    private func encodingRemaining() -> TimeInterval? {
        remainingForPhase(encodingState, estimatedDuration: historicalRatios.firstProgressSeconds)
    }

    /// Remaining time for the transcribe block (warm-up plus decoding), measured
    /// from `processingStartedAt` so it lines up with the recorded wall ratio.
    /// History seeds the estimate and live chunk progress takes over as it accrues.
    private func processingRemaining() -> TimeInterval? {
        if transcriptionState.isDone { return 0 }
        let historyTotal = estimatedDuration(ratio: historicalRatios.processingSecondsPerAudioSecond)
        guard let processingStartedAt else { return historyTotal }
        return PhaseETA.remaining(
            elapsed: clock().timeIntervalSince(processingStartedAt),
            historyTotal: historyTotal,
            progress: transcriptionProgress
        )
    }

    private func diarizationRemaining() -> TimeInterval? {
        guard showDiarizationLine else { return nil }
        let historyTotal = estimatedDuration(ratio: historicalRatios.diarizationSecondsPerAudioSecond)
        switch diarizationState {
        case .done:
            return 0
        case .waiting:
            return historyTotal
        case .running(let startedAt):
            return PhaseETA.remaining(
                elapsed: clock().timeIntervalSince(startedAt),
                historyTotal: historyTotal,
                progress: diarizationProgress
            )
        }
    }

    /// Sum of the sequential phases still ahead; transcription and diarization
    /// run concurrently so only the longer of the two counts.
    private func overallRemaining(elapsedSeconds: TimeInterval) -> TimeInterval? {
        var anyKnown = false
        func known(_ value: TimeInterval?) -> TimeInterval {
            guard let value else { return 0 }
            anyKnown = true
            return value
        }

        var remaining: TimeInterval = 0
        // Setup lines exist only on the shared display that starts before model
        // loading; pipeline-only displays are created after those phases ran.
        if showInputCheckLine || showModelLine || showAudioLine {
            remaining += known(modelLoadRemaining())
            remaining += known(audioLoadRemaining())
        }
        remaining += max(known(processingRemaining()), known(diarizationRemaining()))
        remaining += known(remainingForPhase(
            outputState,
            estimatedDuration: estimatedDuration(ratio: historicalRatios.outputSecondsPerAudioSecond)
        ))
        if anyKnown {
            return max(0, remaining)
        }

        guard let totalRatio = historicalRatios.totalSecondsPerAudioSecond,
              audioDurationSeconds > 0,
              totalRatio > 0 else {
            return nil
        }
        return max(0, totalRatio * audioDurationSeconds - elapsedSeconds)
    }

    private func transcriptionWindowsSummary() -> String? {
        if transcriptionProgress.hasUnits {
            return "\(transcriptionProgress.completedUnits)/\(transcriptionProgress.totalUnits) windows"
        }
        return transcriptionWindows > 0 ? "\(transcriptionWindows) windows" : nil
    }

    private func runningElapsed(for state: LivePhaseState) -> String {
        guard case .running(let startedAt) = state else { return "0s" }
        return formatElapsed(since: startedAt)
    }

    private func finishedElapsed(for state: LivePhaseState) -> String {
        guard case .done(let duration) = state else { return "0s" }
        return formatDuration(duration)
    }

    private func formatRemainingETA(_ remainingSeconds: TimeInterval?) -> String {
        guard let remainingSeconds else { return "unknown" }
        guard remainingSeconds > 0 else { return "now" }
        let formatted = formatDuration(remainingSeconds)
        return formatted == "<1s" ? formatted : "~\(formatted)"
    }

    private func runningDetail(_ activity: String? = nil, state: LivePhaseState, remaining: TimeInterval?) -> String {
        let timing = "elapsed \(runningElapsed(for: state)), ETA \(formatRemainingETA(remaining))"
        guard let activity, !activity.isEmpty else { return timing }
        return "\(activity), \(timing)"
    }

    private func finishedDetail(_ summary: String? = nil, state: LivePhaseState) -> String {
        let prefix = summary.map { "\($0), " } ?? ""
        return "\(prefix)elapsed \(finishedElapsed(for: state))"
    }

    private func icon(for state: LivePhaseState) -> String {
        switch state {
        case .waiting:
            return inactiveIcon
        case .running:
            return runningIcon
        case .done:
            return doneIcon
        }
    }

    private func audioDurationSuffix() -> String {
        audioDurationSeconds > 0 ? ", audio duration \(formatDuration(audioDurationSeconds))" : ""
    }

    private static func compactDiagnosticLine(_ event: TranscribeEvent) -> String {
        var parts = [
            event.level.rendered,
            "event=\(event.name)",
        ]
        parts.append(contentsOf: event.fields.map { "\($0.name)=\($0.value.rendered)" })
        if let message = event.message, !message.isEmpty {
            parts.append("message=\(TranscribeEventValue.string(message).rendered)")
        }
        return parts.joined(separator: " ")
    }

    private func diagnosticDisplayLines() -> [String] {
        guard !diagnosticLines.isEmpty else { return [] }
        let header: String
        if diagnosticCount > diagnosticLines.count {
            header = "Diagnostics (last \(diagnosticLines.count) of \(diagnosticCount)):"
        } else {
            header = "Diagnostics:"
        }
        return [header] + diagnosticLines.map { "  \($0)" }
    }

    private func statusLine(label: String, icon: String, detail: String = "", indented: Bool = true) -> String {
        let labelWithColon = "\(label):"
        let labelWidth = 16
        let prefix = indented ? "  \(icon) " : "\(icon) "
        let padding = String(repeating: " ", count: max(1, labelWidth - labelWithColon.count))
        if detail.isEmpty {
            return "\(prefix)\(labelWithColon)"
        }
        return "\(prefix)\(labelWithColon)\(padding)\(detail)"
    }

    private func modelLine() -> String? {
        guard showModelLine else { return nil }
        switch modelState {
        case .waiting:
            return statusLine(label: "Model Loading", icon: icon(for: modelState), detail: "waiting")
        case .running:
            return statusLine(
                label: "Model Loading",
                icon: icon(for: modelState),
                detail: runningDetail("loading models", state: modelState, remaining: modelLoadRemaining())
            )
        case .done:
            return statusLine(label: "Model Loading", icon: icon(for: modelState), detail: finishedDetail(state: modelState))
        }
    }

    private func inputCheckLine() -> String? {
        guard showInputCheckLine else { return nil }
        switch inputCheckState {
        case .waiting:
            return statusLine(label: "Input Check", icon: icon(for: inputCheckState), detail: "waiting")
        case .running:
            return statusLine(
                label: "Input Check",
                icon: icon(for: inputCheckState),
                detail: runningDetail("checking audio", state: inputCheckState, remaining: nil)
            )
        case .done:
            return statusLine(label: "Input Check", icon: icon(for: inputCheckState), detail: finishedDetail(state: inputCheckState))
        }
    }

    private func audioLine() -> String? {
        guard showAudioLine else { return nil }
        switch audioState {
        case .waiting:
            return statusLine(label: "Audio", icon: icon(for: audioState), detail: "waiting")
        case .running:
            return statusLine(
                label: "Audio",
                icon: icon(for: audioState),
                detail: runningDetail(audioActivity, state: audioState, remaining: audioLoadRemaining())
            )
        case .done:
            return statusLine(
                label: "Audio",
                icon: icon(for: audioState),
                detail: finishedDetail(state: audioState)
            )
        }
    }

    private func encodingLine() -> String {
        switch encodingState {
        case .waiting:
            return statusLine(label: "Encoding", icon: icon(for: encodingState), detail: "waiting")
        case .running:
            return statusLine(
                label: "Encoding",
                icon: icon(for: encodingState),
                detail: runningDetail("encoding audio", state: encodingState, remaining: encodingRemaining())
            )
        case .done:
            return statusLine(label: "Encoding", icon: icon(for: encodingState), detail: finishedDetail(state: encodingState))
        }
    }

    private func transcriptionLine() -> String {
        switch transcriptionState {
        case .waiting:
            return statusLine(label: "Transcription", icon: icon(for: transcriptionState), detail: "waiting")
        case .running:
            return statusLine(
                label: "Transcription",
                icon: icon(for: transcriptionState),
                detail: runningDetail(
                    transcriptionWindowsSummary(),
                    state: transcriptionState,
                    remaining: processingRemaining()
                )
            )
        case .done:
            return statusLine(
                label: "Transcription",
                icon: icon(for: transcriptionState),
                detail: finishedDetail(transcriptionWindowsSummary(), state: transcriptionState)
            )
        }
    }

    private func diarizationLine() -> String? {
        guard showDiarizationLine else { return nil }
        switch diarizationState {
        case .waiting:
            return statusLine(label: "Diarization", icon: icon(for: diarizationState), detail: "waiting")
        case .running:
            let remaining = diarizationRemaining()
            if let frac = diarizationFraction, let count = diarizationUnitCount {
                let pct = Int(round(frac * 100))
                let phase = count < 85 ? "segmenter" : "embedder"
                return statusLine(
                    label: "Diarization",
                    icon: icon(for: diarizationState),
                    detail: runningDetail("\(phase) \(pct)%", state: diarizationState, remaining: remaining)
                )
            }
            return statusLine(
                label: "Diarization",
                icon: icon(for: diarizationState),
                detail: runningDetail(state: diarizationState, remaining: remaining)
            )
        case .done:
            return statusLine(label: "Diarization", icon: icon(for: diarizationState), detail: finishedDetail(state: diarizationState))
        }
    }

    private func outputLine() -> String? {
        switch outputState {
        case .waiting:
            return nil
        case .running:
            let remaining = remainingForPhase(
                outputState,
                estimatedDuration: estimatedDuration(ratio: historicalRatios.outputSecondsPerAudioSecond)
            )
            return statusLine(
                label: "Output",
                icon: icon(for: outputState),
                detail: runningDetail("writing outputs", state: outputState, remaining: remaining)
            )
        case .done:
            return statusLine(label: "Output", icon: icon(for: outputState), detail: finishedDetail(state: outputState))
        }
    }

    private func progressLines() -> [String] {
        let elapsedSeconds = clock().timeIntervalSince(startDate)
        let totalLine: String
        if let failedAt {
            totalLine = statusLine(
                label: "Total",
                icon: failedIcon,
                detail: "failed after \(formatDuration(failedAt.timeIntervalSince(startDate)))\(audioDurationSuffix())",
                indented: false
            )
        } else if let completedAt = finishedAt ?? workCompletedAt {
            totalLine = statusLine(
                label: "Total",
                icon: doneIcon,
                detail: "elapsed \(formatDuration(completedAt.timeIntervalSince(startDate)))\(audioDurationSuffix())",
                indented: false
            )
        } else {
            totalLine = statusLine(
                label: "Total",
                icon: runningIcon,
                detail: "elapsed \(formatElapsed(since: startDate)), ETA \(formatRemainingETA(overallRemaining(elapsedSeconds: elapsedSeconds)))\(audioDurationSuffix())",
                indented: false
            )
        }
        var lines = contextLines
        lines.append(totalLine)
        if let inputCheckLine = inputCheckLine() {
            lines.append(inputCheckLine)
        }
        if let modelLine = modelLine() {
            lines.append(modelLine)
        }
        if let audioLine = audioLine() {
            lines.append(audioLine)
        }
        lines.append(encodingLine())
        if let diarizationLine = diarizationLine() {
            lines.append(diarizationLine)
        }
        lines.append(transcriptionLine())
        if let outputLine = outputLine() {
            lines.append(outputLine)
        }
        lines.append(contentsOf: diagnosticDisplayLines())
        return lines
    }

    private func emitLineLogSnapshot(throttled: Bool) {
        guard case .lineLog(let minInterval) = renderMode else { return }
        if throttled {
            let now = clock()
            if let last = lastLineLogEmit, minInterval > 0, now.timeIntervalSince(last) < minInterval {
                return
            }
            lastLineLogEmit = now
        }

        let lines = progressLines()
        let signature = lines.joined(separator: "\u{1E}")
        if !throttled, signature == lastLineLogSignature { return }
        lastLineLogSignature = signature
        write(lines.joined(separator: "\n") + "\n")
    }

    private func redrawTTY() {
        let columns = ttyColumnCountOverride ?? terminalColumnCount(stderr)
        let drawnRowCount = terminalRowCount(drawnTTYLines, columns: columns)
        if drawnRowCount > 0 {
            for _ in 1 ..< drawnRowCount {
                write(cursorUp)
            }
        }
        write("\r\(clearToEndOfScreen)")

        let lines = progressLines()
        for (idx, line) in lines.enumerated() {
            write("\r\(clearToEndOfLine)\(line)")
            if idx < lines.count - 1 {
                write("\n")
            }
        }
        write("\r")
        drawnTTYLines = lines
    }

    private func redraw() {
        switch renderMode {
        case .lineLog:
            emitLineLogSnapshot(throttled: true)
        case .tty:
            redrawTTY()
        }
    }

    private func startTimerIfNeeded() {
        guard redrawTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self, !self.isFinished else { return }
            self.sampleTranscriptionUnitsLocked()
            self.redraw()
        }
        redrawTimer = timer
        timer.resume()
    }

    private func write(_ s: String) {
        stderr.write((s).data(using: .utf8)!)
    }
}
