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

// ANSI escape sequences for terminal cursor control.
private let esc = "\u{1B}"
private let clearToEndOfLine = "\(esc)[K"
private let cursorUp = "\(esc)[A"
private let runningIcon = "▶"
private let doneIcon = "✓"
private let inactiveIcon = " "

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
    private var audioDurationSeconds: Double
    private let historicalRatios: HistoricalTimingRatios
    private let renderMode: LiveProgressRenderMode

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
    private var diarizationFraction: Double?
    private var diarizationUnitCount: Int64?
    private var isFinished: Bool = false
    private var finishedAt: Date?
    private var workCompletedAt: Date?
    private var redrawTimer: DispatchSourceTimer?
    private var drawnLineCount: Int = 0
    private var lastLineLogEmit: Date?
    private var lastLineLogSignature: String?

    /// - Parameters:
    ///   - startDate: Session or pipeline start for the overall elapsed line.
    ///   - audioDurationSeconds: Estimated or decoded audio length in seconds.
    ///   - historicalRatios: Per-phase and total history ratios for ETA.
    ///   - renderMode: `.tty` for cursor updates; `.lineLog` for newline-separated snapshots.
    init(
        startDate: Date = Date(),
        stderr: FileHandle = .standardError,
        showDiarizationLine: Bool = true,
        audioDurationSeconds: Double = 0,
        historicalRatios: HistoricalTimingRatios = HistoricalTimingRatios(),
        historicalWallSecondsPerAudioSecond: Double? = nil,
        historicalEncodingSecondsPerAudioSecond: Double? = nil,
        renderMode: LiveProgressRenderMode = .tty
    ) {
        self.startDate = startDate
        self.stderr = stderr
        self.showDiarizationLine = showDiarizationLine
        self.audioDurationSeconds = audioDurationSeconds
        var resolvedRatios = historicalRatios
        if resolvedRatios.totalSecondsPerAudioSecond == nil {
            resolvedRatios.totalSecondsPerAudioSecond = historicalWallSecondsPerAudioSecond
        }
        if resolvedRatios.encodingSecondsPerAudioSecond == nil {
            resolvedRatios.encodingSecondsPerAudioSecond = historicalEncodingSecondsPerAudioSecond
        }
        self.historicalRatios = resolvedRatios
        self.renderMode = renderMode
    }

    /// Emit an immediate encoding snapshot and keep elapsed/ETA moving while waiting for model callbacks.
    func start() {
        beginEncoding()
    }

    func beginModelLoading() {
        queue.sync {
            guard !self.isFinished else { return }
            self.showModelLine = true
            self.modelState = .running(startedAt: Date())
            self.redraw()
            self.startTimerIfNeeded()
        }
    }

    func finishModelLoading() {
        queue.sync {
            guard !self.isFinished else { return }
            self.showModelLine = true
            self.modelState = self.doneState(self.modelState, at: Date())
            self.redraw()
        }
    }

    func beginAudioChecking() {
        queue.sync {
            guard !self.isFinished else { return }
            self.showInputCheckLine = true
            if case .waiting = self.inputCheckState {
                self.inputCheckState = .running(startedAt: Date())
            }
            self.redraw()
            self.startTimerIfNeeded()
        }
    }

    func finishAudioChecking() {
        queue.sync {
            guard !self.isFinished else { return }
            self.showInputCheckLine = true
            self.inputCheckState = self.doneState(self.inputCheckState, at: Date())
            self.redraw()
        }
    }

    func beginAudioLoading() {
        queue.sync {
            guard !self.isFinished else { return }
            self.showAudioLine = true
            self.audioActivity = "loading audio"
            if case .waiting = self.audioState {
                self.audioState = .running(startedAt: Date())
            }
            self.redraw()
            self.startTimerIfNeeded()
        }
    }

    func finishAudioLoading(durationSeconds: Double) {
        queue.sync {
            guard !self.isFinished else { return }
            self.showAudioLine = true
            if durationSeconds > 0 {
                self.audioDurationSeconds = durationSeconds
            }
            self.audioState = self.doneState(self.audioState, at: Date())
            self.redraw()
        }
    }

    func beginEncoding() {
        queue.sync {
            guard !self.isFinished else { return }
            let now = Date()
            if case .waiting = self.encodingState {
                self.encodingState = .running(startedAt: now)
            }
            if self.showDiarizationLine, case .waiting = self.diarizationState {
                self.diarizationState = .running(startedAt: now)
            }
            self.redraw()
            self.startTimerIfNeeded()
        }
    }

    /// Update the transcription line from WhisperKit progress (windows done).
    func updateTranscription(progress: TranscriptionProgress) {
        queue.async {
            guard !self.isFinished else { return }
            let now = Date()
            if self.firstTranscriptionProgressDate == nil {
                self.firstTranscriptionProgressDate = now
                self.encodingState = self.doneState(self.encodingState, at: now)
                self.transcriptionState = .running(startedAt: now)
            }
            self.transcriptionWindows = Int(progress.timings.totalDecodingWindows)
            self.redraw()
        }
    }

    /// Update the diarization line from SpeakerKit Progress (fractionCompleted, phase hint).
    /// Takes scalar values to avoid type-capture issues when called from progressCallback.
    func updateDiarization(fractionCompleted: Double, completedUnitCount: Int64) {
        queue.async {
            guard self.showDiarizationLine, !self.isFinished else { return }
            let now = Date()
            if case .waiting = self.diarizationState {
                self.diarizationState = .running(startedAt: now)
            }
            self.diarizationFraction = fractionCompleted
            self.diarizationUnitCount = completedUnitCount
            if fractionCompleted >= 0.995 {
                self.diarizationState = self.doneState(self.diarizationState, at: now)
            }
            self.redraw()
        }
    }

    func beginOutput() {
        queue.sync {
            guard !self.isFinished else { return }
            let now = Date()
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
            let now = Date()
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

            finishProcessingLocked(at: Date())
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
            let now = workCompletedAt ?? Date()
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
                    redrawTTY(clearOnly: false)
                }
                stderr.write("\n".data(using: .utf8)!)
            }

            let windows = transcriptionWindows
            return windows > 0 ? windows : nil
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
        formatDuration(Date().timeIntervalSince(date))
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

    private func estimatedEncodingPhaseDuration() -> TimeInterval? {
        let ratio = [
            historicalRatios.whisperPrepSecondsPerAudioSecond,
            historicalRatios.encodingSecondsPerAudioSecond,
        ]
        .compactMap { $0 }
        .filter { $0 > 0 }
        .reduce(0, +)
        return ratio > 0 ? estimatedDuration(ratio: ratio) : nil
    }

    private func remainingForPhase(_ state: LivePhaseState, estimatedDuration: TimeInterval?) -> TimeInterval? {
        guard let estimatedDuration else { return nil }
        switch state {
        case .waiting:
            return estimatedDuration
        case .running(let startedAt):
            return max(0, estimatedDuration - Date().timeIntervalSince(startedAt))
        case .done:
            return 0
        }
    }

    private func fractionRemaining(for state: LivePhaseState, fractionCompleted: Double?) -> TimeInterval? {
        guard case .running(let startedAt) = state,
              let fractionCompleted,
              fractionCompleted > 0.05,
              fractionCompleted < 0.995 else {
            return nil
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        let totalEstimate = elapsed / fractionCompleted
        return max(0, totalEstimate - elapsed)
    }

    private func overallRemaining(elapsedSeconds: TimeInterval) -> TimeInterval? {
        let encodingRemaining = remainingForPhase(
            encodingState,
            estimatedDuration: estimatedEncodingPhaseDuration()
        ) ?? 0
        let transcriptionRemaining = remainingForPhase(
            transcriptionState,
            estimatedDuration: estimatedDuration(ratio: historicalRatios.transcriptionSecondsPerAudioSecond)
        ) ?? 0
        let transcribePathRemaining = encodingRemaining + transcriptionRemaining

        let outputRemaining = remainingForPhase(
            outputState,
            estimatedDuration: estimatedDuration(ratio: historicalRatios.outputSecondsPerAudioSecond)
        ) ?? 0

        let phaseEstimate: TimeInterval
        if showDiarizationLine {
            let diarizationRemaining = fractionRemaining(
                for: diarizationState,
                fractionCompleted: diarizationFraction
            ) ?? remainingForPhase(
                diarizationState,
                estimatedDuration: estimatedDuration(ratio: historicalRatios.diarizationSecondsPerAudioSecond)
            ) ?? 0
            phaseEstimate = max(transcribePathRemaining, diarizationRemaining) + outputRemaining
        } else {
            phaseEstimate = transcribePathRemaining + outputRemaining
        }

        if phaseEstimate > 0 {
            return phaseEstimate
        }

        guard let totalRatio = historicalRatios.totalSecondsPerAudioSecond,
              audioDurationSeconds > 0,
              totalRatio > 0 else {
            return nil
        }
        let predictedTotal = totalRatio * audioDurationSeconds
        return max(0, predictedTotal - elapsedSeconds)
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
                detail: runningDetail("loading models", state: modelState, remaining: nil)
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
            let remaining = remainingForPhase(
                audioState,
                estimatedDuration: estimatedDuration(ratio: historicalRatios.audioLoadSecondsPerAudioSecond)
            )
            return statusLine(
                label: "Audio",
                icon: icon(for: audioState),
                detail: runningDetail(audioActivity, state: audioState, remaining: remaining)
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
            let remaining = remainingForPhase(
                encodingState,
                estimatedDuration: estimatedEncodingPhaseDuration()
            )
            return statusLine(
                label: "Encoding",
                icon: icon(for: encodingState),
                detail: runningDetail("encoding audio", state: encodingState, remaining: remaining)
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
            let state = transcriptionWindows > 0 ? "\(transcriptionWindows) windows" : nil
            let remaining = remainingForPhase(
                transcriptionState,
                estimatedDuration: estimatedDuration(ratio: historicalRatios.transcriptionSecondsPerAudioSecond)
            )
            return statusLine(
                label: "Transcription",
                icon: icon(for: transcriptionState),
                detail: runningDetail(state, state: transcriptionState, remaining: remaining)
            )
        case .done:
            let summary = transcriptionWindows > 0 ? "\(transcriptionWindows) windows" : nil
            return statusLine(label: "Transcription", icon: icon(for: transcriptionState), detail: finishedDetail(summary, state: transcriptionState))
        }
    }

    private func diarizationLine() -> String? {
        guard showDiarizationLine else { return nil }
        switch diarizationState {
        case .waiting:
            return statusLine(label: "Diarization", icon: icon(for: diarizationState), detail: "waiting")
        case .running:
            let remaining = fractionRemaining(for: diarizationState, fractionCompleted: diarizationFraction)
                ?? remainingForPhase(
                    diarizationState,
                    estimatedDuration: estimatedDuration(ratio: historicalRatios.diarizationSecondsPerAudioSecond)
            )
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
        let elapsedSeconds = Date().timeIntervalSince(startDate)
        let totalLine: String
        if let completedAt = finishedAt ?? workCompletedAt {
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
        var lines = [
            totalLine,
        ]
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
        return lines
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

        let lines = progressLines()
        let signature = lines.joined(separator: "\u{1E}")
        if !throttled, signature == lastLineLogSignature { return }
        lastLineLogSignature = signature
        write(lines.joined(separator: "\n") + "\n")
    }

    private func redrawTTY(clearOnly: Bool = false) {
        if drawnLineCount > 0 {
            for _ in 1 ..< drawnLineCount {
                write(cursorUp)
            }
        }

        if clearOnly {
            for idx in 0 ..< drawnLineCount {
                write("\r\(clearToEndOfLine)")
                if idx < drawnLineCount - 1 {
                    write("\n")
                }
            }
            write("\r")
            drawnLineCount = 0
            return
        }

        let lines = progressLines()
        for (idx, line) in lines.enumerated() {
            write("\r\(clearToEndOfLine)\(line)")
            if idx < lines.count - 1 {
                write("\n")
            }
        }
        write("\r")
        drawnLineCount = lines.count
    }

    private func redraw() {
        switch renderMode {
        case .lineLog:
            emitLineLogSnapshot(throttled: true)
        case .tty:
            redrawTTY(clearOnly: false)
        }
    }

    private func startTimerIfNeeded() {
        guard redrawTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self, !self.isFinished else { return }
            self.redraw()
        }
        redrawTimer = timer
        timer.resume()
    }

    private func write(_ s: String) {
        stderr.write((s).data(using: .utf8)!)
    }
}
