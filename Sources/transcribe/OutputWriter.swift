import Foundation

/// Basename of the input file without extension (e.g. "meeting.mp3" -> "meeting").
func outputBasename(audioPath: String) -> String {
    let name = (audioPath as NSString).lastPathComponent
    return (name as NSString).deletingPathExtension
}

/// Basename derived from a directory input. Standardises the path first so
/// relative inputs like `.` or `..` resolve to absolute paths whose final
/// component is the cwd's name (not literal `.`). Returns an empty string
/// when no usable name can be derived (root, empty path, or final component
/// is `.`/`..`/`/`); callers should substitute their own fallback in that
/// case (e.g. "Recording 1"). No extension stripping — preserves names
/// like `2026.04.notes`.
func outputBasename(directoryPath: String) -> String {
    var trimmed = directoryPath
    while trimmed.count > 1 && trimmed.hasSuffix("/") {
        trimmed.removeLast()
    }
    let abs: String = {
        if trimmed.hasPrefix("/") { return trimmed }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }()
    let last = (abs as NSString).lastPathComponent
    if last.isEmpty || last == "." || last == ".." || last == "/" {
        return ""
    }
    return last
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
    if basename.contains("/") || basename.contains("..") {
        throw TranscribeError(
            message: "Output filename prefix cannot contain '/' or '..'",
            exitCode: .invalidUsage
        )
    }

    guard !overwrite else { return }
    let dir = resolvedOutputDir(outputDir)
    let extMap = ["txt": "txt", "json": "json", "srt": "srt", "vtt": "vtt", "md": "md"]
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
    let tempPath = (dir as NSString).appendingPathComponent(".\(name).tmp.\(UUID().uuidString)")
    let tempURL = URL(fileURLWithPath: tempPath)
    let targetURL = URL(fileURLWithPath: path)
    do {
        try content.write(to: tempURL)
        if FileManager.default.fileExists(atPath: path) {
            _ = try FileManager.default.replaceItemAt(targetURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: targetURL)
        }
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
    /// Source filenames in concat order when input was a directory of clips;
    /// nil for single-file input. Omitted from JSON when nil.
    let audio_files: [String]?
    let duration_seconds: Double
    let model: String
    let language: String?
    let diarization_enabled: Bool
    let speaker_strategy: String
    let speakers_detected: Int?
    let transcribe_version: String
    let created_at: String

    private enum CodingKeys: String, CodingKey {
        case audio_file, audio_files, duration_seconds, model, language
        case diarization_enabled, speaker_strategy, speakers_detected
        case transcribe_version, created_at
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(audio_file, forKey: .audio_file)
        try c.encodeIfPresent(audio_files, forKey: .audio_files)
        try c.encode(duration_seconds, forKey: .duration_seconds)
        try c.encode(model, forKey: .model)
        // Preserve prior behaviour: encode language and speakers_detected as
        // null when nil (not omitted), since downstream consumers may rely on
        // the keys being present.
        try c.encode(language, forKey: .language)
        try c.encode(diarization_enabled, forKey: .diarization_enabled)
        try c.encode(speaker_strategy, forKey: .speaker_strategy)
        try c.encode(speakers_detected, forKey: .speakers_detected)
        try c.encode(transcribe_version, forKey: .transcribe_version)
        try c.encode(created_at, forKey: .created_at)
    }
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

func renderJSON(
    output: TranscriptionOutput,
    audioFile: String,
    audioFiles: [String]? = nil,
    model: String,
    version: String
) throws -> Data {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let createdAt = formatter.string(from: Date())

    let metadata = JSONMetadata(
        audio_file: (audioFile as NSString).lastPathComponent,
        audio_files: audioFiles,
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

func renderTxt(output: TranscriptionOutput) -> String {
    var lines: [String] = []
    var currentSpeaker: String? = nil
    var currentBlock: [String] = []
    var blockStart: Double = 0
    var blockEnd: Double = 0

    func flushBlock() {
        guard !currentBlock.isEmpty else { return }
        let text = currentBlock.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if let sp = currentSpeaker {
            lines.append("\(sp) [\(formatTimeRange(seconds: blockStart)) - \(formatTimeRange(seconds: blockEnd))]")
        } else {
            lines.append("[\(formatTimeRange(seconds: blockStart)) - \(formatTimeRange(seconds: blockEnd))]")
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

    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Markdown

/// Strips characters that would break ATX headings or confuse block structure.
func markdownSanitizeHeadingFragment(_ s: String) -> String {
    s.replacingOccurrences(of: "#", with: "")
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func renderMarkdown(
    output: TranscriptionOutput,
    audioFile: String,
    audioFiles: [String]? = nil,
    model: String,
    version: String
) -> String {
    let basename = (audioFile as NSString).lastPathComponent
    let title = markdownSanitizeHeadingFragment((basename as NSString).deletingPathExtension)
    let titleLine = title.isEmpty ? "# Transcript" : "# \(title)"

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let createdAt = formatter.string(from: Date())

    var metaLines: [String] = [
        "## Metadata",
        "",
        "- **Source:** `\(basename)`",
        "- **Duration:** \(String(format: "%.1f", output.durationSeconds))s",
        "- **Model:** `\(model)`",
    ]
    if let files = audioFiles, !files.isEmpty {
        metaLines.append("- **Sources:**")
        for f in files {
            metaLines.append("  - `\(f)`")
        }
    }
    if let lang = output.language {
        metaLines.append("- **Language:** `\(lang)`")
    }
    metaLines.append("- **Diarization:** \(output.diarizationEnabled ? "on" : "off")")
    if output.diarizationEnabled {
        metaLines.append("- **Speaker strategy:** `\(output.speakerStrategy)`")
    }
    if let n = output.speakersDetected {
        metaLines.append("- **Speakers detected:** \(n)")
    }
    metaLines.append(contentsOf: [
        "- **transcribe:** `\(version)`",
        "- **Created:** \(createdAt)",
        "",
        "## Transcript",
        "",
    ])

    var bodyLines: [String] = []
    var currentSpeaker: String? = nil
    var currentBlock: [String] = []
    var blockStart: Double = 0
    var blockEnd: Double = 0

    func flushBlock() {
        guard !currentBlock.isEmpty else { return }
        let text = currentBlock.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let timeRange = "_\(formatTimeRange(seconds: blockStart)) – \(formatTimeRange(seconds: blockEnd))_"
        if let sp = currentSpeaker {
            let safe = markdownSanitizeHeadingFragment(sp)
            bodyLines.append("## **\(safe)** — \(timeRange)")
        } else {
            bodyLines.append("## \(timeRange)")
        }
        bodyLines.append("")
        bodyLines.append(text)
        bodyLines.append("")
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

    let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    let meta = metaLines.joined(separator: "\n")
    if body.isEmpty {
        return "\(titleLine)\n\n\(meta)\n"
    }
    return "\(titleLine)\n\n\(meta)\n\(body)\n"
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
/// - Parameter audioFiles: When the input was a directory of clips, the source filenames in concat order; nil for single-file input.
func writeOutputs(
    output: TranscriptionOutput,
    audioPath: String,
    audioFiles: [String]? = nil,
    outputDir: String,
    basename: String,
    formats: [String],
    writeTxtToStdout: Bool,
    overwrite: Bool,
    model: String,
    version: String
) throws {
    let dir = resolvedOutputDir(outputDir)

    if !FileManager.default.fileExists(atPath: dir) {
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            throw TranscribeError(
                message: "Cannot create output directory: \(error.localizedDescription)",
                exitCode: .outputWrite
            )
        }
    }

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
            let data = try renderJSON(
                output: output,
                audioFile: audioPath,
                audioFiles: audioFiles,
                model: model,
                version: version
            )
            let path = (dir as NSString).appendingPathComponent("\(basename).json")
            try writeAtomically(content: data, to: path)
        case "txt":
            let text = renderTxt(output: output)
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
        case "md":
            let text = renderMarkdown(
                output: output,
                audioFile: audioPath,
                audioFiles: audioFiles,
                model: model,
                version: version
            )
            let path = (dir as NSString).appendingPathComponent("\(basename).md")
            try writeAtomically(content: text.data(using: .utf8)!, to: path)
        default:
            break
        }
    }
}
