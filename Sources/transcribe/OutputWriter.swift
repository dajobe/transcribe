import Foundation

/// Basename of the input file without extension (e.g. "meeting.mp3" -> "meeting").
func outputBasename(audioPath: String) -> String {
    let name = (audioPath as NSString).lastPathComponent
    return (name as NSString).deletingPathExtension
}

/// Resolved output directory path (expanded tilde).
func resolvedOutputDir(_ outputDir: String) -> String {
    (outputDir as NSString).expandingTildeInPath
}

/// Throws TranscribeError(.outputWrite) if any of the requested output files exist and overwrite is false.
func checkOverwrite(
    outputDir: String,
    basename: String,
    formats: [String],
    writeTxtFile: Bool,
    overwrite: Bool
) throws {
    guard !overwrite else { return }
    let dir = resolvedOutputDir(outputDir)
    let extMap = ["txt": "txt", "json": "json", "srt": "srt", "vtt": "vtt"]
    for f in formats {
        guard let ext = extMap[f] else { continue }
        if f == "txt" && !writeTxtFile { continue }
        let path = (dir as NSString).appendingPathComponent("\(basename).\(ext)")
        if FileManager.default.fileExists(atPath: path) {
            throw TranscribeError(
                message: "Output file already exists: \(path). Use --overwrite to replace.",
                exitCode: .outputWrite
            )
        }
    }
}

/// Writes content to path atomically (write to temp file in same dir, then rename).
func writeAtomically(content: Data, to path: String) throws {
    let dir = (path as NSString).deletingLastPathComponent
    let name = (path as NSString).lastPathComponent
    let tempPath = (dir as NSString).appendingPathComponent(".\(name).tmp.\(ProcessInfo.processInfo.processIdentifier)")
    do {
        try content.write(to: URL(fileURLWithPath: tempPath))
        if FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
        try FileManager.default.moveItem(atPath: tempPath, toPath: path)
    } catch {
        try? FileManager.default.removeItem(atPath: tempPath)
        throw TranscribeError(message: "Failed to write output: \(error.localizedDescription)", exitCode: .outputWrite)
    }
}

/// Format seconds as HH:MM:SS for plain text.
func formatTimeRange(seconds: Double) -> String {
    let s = Int(seconds.rounded())
    let h = s / 3600
    let m = (s % 3600) / 60
    let sec = s % 60
    return String(format: "%02d:%02d:%02d", h, m, sec)
}

/// Format for SRT (comma for milliseconds).
func formatSRTTime(seconds: Double) -> String {
    let s = Int(seconds.rounded(.down))
    let ms = Int((seconds - Double(s)) * 1000)
    let h = s / 3600
    let m = (s % 3600) / 60
    let sec = s % 60
    return String(format: "%02d:%02d:%02d,%03d", h, m, sec, ms)
}

/// Format for VTT (dot for milliseconds).
func formatVTTTime(seconds: Double) -> String {
    let s = Int(seconds.rounded(.down))
    let ms = Int((seconds - Double(s)) * 1000)
    let h = s / 3600
    let m = (s % 3600) / 60
    let sec = s % 60
    return String(format: "%02d:%02d:%02d.%03d", h, m, sec, ms)
}

// MARK: - JSON encoding

struct JSONMetadata: Encodable {
    let audio_file: String
    let duration_seconds: Double
    let model: String
    let language: String?
    let diarization_enabled: Bool
    let speaker_strategy: String
    let speakers_detected: Int?
    let transcribe_version: String
    let created_at: String
}

struct JSONSegmentWord: Encodable {
    let word: String
    let start: Double
    let end: Double
}

struct JSONSegment: Encodable {
    let speaker: String?
    let start: Double
    let end: Double
    let text: String
    let words: [JSONSegmentWord]?
}

struct JSONTranscript: Encodable {
    let metadata: JSONMetadata
    let warnings: [String]
    let segments: [JSONSegment]
}

func renderJSON(output: TranscriptionOutput, audioFile: String, model: String, version: String) throws -> Data {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let createdAt = formatter.string(from: Date())

    let metadata = JSONMetadata(
        audio_file: (audioFile as NSString).lastPathComponent,
        duration_seconds: output.durationSeconds,
        model: model,
        language: output.language,
        diarization_enabled: output.diarizationEnabled,
        speaker_strategy: output.speakerStrategy,
        speakers_detected: output.speakersDetected,
        transcribe_version: version,
        created_at: createdAt
    )

    let segments = output.segments.map { seg in
        JSONSegment(
            speaker: seg.speaker,
            start: seg.start,
            end: seg.end,
            text: seg.text,
            words: seg.words.map { $0.map { JSONSegmentWord(word: $0.word, start: $0.start, end: $0.end) } }
        )
    }

    let transcript = JSONTranscript(metadata: metadata, warnings: output.warnings, segments: segments)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(transcript)
}

// MARK: - Plain text (merge consecutive same-speaker segments)

func renderTxt(output: TranscriptionOutput, includeSpeakerAndTime: Bool) -> String {
    var lines: [String] = []
    var currentSpeaker: String? = nil
    var currentBlock: [String] = []
    var blockStart: Double = 0
    var blockEnd: Double = 0

    func flushBlock() {
        guard !currentBlock.isEmpty else { return }
        let text = currentBlock.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if includeSpeakerAndTime {
            if let sp = currentSpeaker {
                lines.append("\(sp) [\(formatTimeRange(seconds: blockStart)) - \(formatTimeRange(seconds: blockEnd))]")
            } else {
                lines.append("[\(formatTimeRange(seconds: blockStart)) - \(formatTimeRange(seconds: blockEnd))]")
            }
        }
        lines.append(text)
        lines.append("")
        currentBlock = []
    }

    for seg in output.segments {
        if seg.speaker != currentSpeaker {
            flushBlock()
            currentSpeaker = seg.speaker
            blockStart = seg.start
            blockEnd = seg.end
            currentBlock = [seg.text]
        } else {
            blockEnd = seg.end
            currentBlock.append(seg.text)
        }
    }
    flushBlock()

    return lines.joined(separator: "\n")
}

// MARK: - SRT

func renderSRT(output: TranscriptionOutput) -> String {
    var lines: [String] = []
    for (i, seg) in output.segments.enumerated() {
        lines.append("\(i + 1)")
        lines.append("\(formatSRTTime(seconds: seg.start)) --> \(formatSRTTime(seconds: seg.end))")
        let prefix = seg.speaker.map { "[\($0)] " } ?? ""
        lines.append(prefix + seg.text.replacingOccurrences(of: "\n", with: " "))
        lines.append("")
    }
    return lines.joined(separator: "\n")
}

// MARK: - VTT

func renderVTT(output: TranscriptionOutput) -> String {
    var lines: [String] = ["WEBVTT", ""]
    for seg in output.segments {
        lines.append("\(formatVTTTime(seconds: seg.start)) --> \(formatVTTTime(seconds: seg.end))")
        let prefix = seg.speaker.map { "<v \($0)>" } ?? ""
        lines.append((prefix + seg.text).replacingOccurrences(of: "\n", with: " "))
        lines.append("")
    }
    return lines.joined(separator: "\n")
}

// MARK: - Write all outputs

/// Writes requested output formats. Uses atomic writes. For txt with --stdout, writes to stdout and does not create .txt file.
func writeOutputs(
    output: TranscriptionOutput,
    audioPath: String,
    outputDir: String,
    formats: [String],
    writeTxtToStdout: Bool,
    overwrite: Bool,
    model: String,
    version: String
) throws {
    let dir = resolvedOutputDir(outputDir)
    let basename = outputBasename(audioPath: audioPath)
    let includeSpeakerAndTime = output.diarizationEnabled || output.segments.contains { $0.speaker != nil }

    try checkOverwrite(
        outputDir: outputDir,
        basename: basename,
        formats: formats,
        writeTxtFile: formats.contains("txt") && !writeTxtToStdout,
        overwrite: overwrite
    )

    for f in formats {
        switch f {
        case "json":
            let data = try renderJSON(output: output, audioFile: audioPath, model: model, version: version)
            let path = (dir as NSString).appendingPathComponent("\(basename).json")
            try writeAtomically(content: data, to: path)
        case "txt":
            let text = renderTxt(output: output, includeSpeakerAndTime: includeSpeakerAndTime)
            if writeTxtToStdout {
                FileHandle.standardOutput.write((text + "\n").data(using: .utf8)!)
            } else {
                let path = (dir as NSString).appendingPathComponent("\(basename).txt")
                try writeAtomically(content: (text + "\n").data(using: .utf8)!, to: path)
            }
        case "srt":
            let text = renderSRT(output: output)
            let path = (dir as NSString).appendingPathComponent("\(basename).srt")
            try writeAtomically(content: (text + "\n").data(using: .utf8)!, to: path)
        case "vtt":
            let text = renderVTT(output: output)
            let path = (dir as NSString).appendingPathComponent("\(basename).vtt")
            try writeAtomically(content: (text + "\n").data(using: .utf8)!, to: path)
        default:
            break
        }
    }
}
