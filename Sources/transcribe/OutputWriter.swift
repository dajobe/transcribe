import CryptoKit
import Darwin
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

/// Resolved output directory path (expanded tilde, canonicalized).
func resolvedOutputDir(_ outputDir: String) -> String {
    let expanded = (outputDir as NSString).expandingTildeInPath
    return URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
}

/// Throws TranscribeError(.outputWrite) if any of the requested output files exist and overwrite is false.
func checkOverwrite(
    outputDir: String,
    basename: String,
    formats: [String],
    writeTxtFile: Bool,
    overwrite: Bool
) throws {
    if basename.trimmingCharacters(in: .whitespaces).isEmpty {
        throw TranscribeError(
            message: "Output filename prefix cannot be empty.",
            exitCode: .invalidUsage
        )
    }
    if basename.contains("/") || basename.contains("..") {
        throw TranscribeError(
            message: "Output filename prefix cannot contain '/' or '..'",
            exitCode: .invalidUsage
        )
    }

    guard !overwrite else { return }
    let dir = resolvedOutputDir(outputDir)
    let extMap = ["txt": "txt", "json": "json", "srt": "srt", "vtt": "vtt", "md": "md", "tsv": "tsv"]
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

func outputPaths(
    outputDir: String,
    basename: String,
    formats: [String],
    writeTxtFile: Bool
) -> [String] {
    let dir = resolvedOutputDir(outputDir)
    let extMap = ["txt": "txt", "json": "json", "srt": "srt", "vtt": "vtt", "md": "md", "tsv": "tsv"]
    return formats.compactMap { format in
        guard let ext = extMap[format] else { return nil }
        if format == "txt" && !writeTxtFile { return nil }
        return (dir as NSString).appendingPathComponent("\(basename).\(ext)")
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

// MARK: - Private state files

/// Owner-only mode for state files this tool creates.
let privateFileMode: mode_t = 0o600
/// Owner-only mode for state directories this tool creates.
let privateDirectoryMode: mode_t = 0o700

/// Writes `data` to `url` atomically and privately: the content is written to
/// a temporary file created with `O_EXCL` in the destination directory, forced
/// to disk, then renamed over the destination. POSIX rename replaces the
/// destination atomically and carries the mode of the temporary file, so a
/// reader never sees a partial file and the result never inherits a wider mode
/// from an older copy. Used for state the tool owns (speaker profiles,
/// canonical transcripts); user-facing outputs keep `writeAtomically`, whose
/// files are meant to follow the user's umask.
func writePrivateAtomically(data: Data, to url: URL, mode: mode_t = privateFileMode) throws {
    let directory = url.deletingLastPathComponent()
    let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    defer { try? FileManager.default.removeItem(at: temporary) }

    let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY, mode)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    do {
        // open() masks the requested mode with the process umask, so restore it.
        try tightenPermissions(ofFileDescriptor: fd, at: temporary.path, to: mode)
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
    } catch {
        try? handle.close()
        throw error
    }

    guard Darwin.rename(temporary.path, url.path) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    syncDirectory(directory)
}

/// Flushes the directory entry so a crash cannot lose a completed rename.
/// Best effort: filesystems that reject the open or the fsync still hold a
/// correctly renamed file, only without the durability guarantee.
private func syncDirectory(_ directory: URL) {
    let fd = open(directory.path, O_RDONLY)
    guard fd >= 0 else { return }
    defer { close(fd) }
    _ = fsync(fd)
}

/// Sets `path` to `mode` unless it already has exactly that mode.
func tightenPermissions(ofPath path: String, to mode: mode_t) throws {
    var info = stat()
    if stat(path, &info) == 0, info.st_mode & 0o7777 == mode { return }
    guard chmod(path, mode) != 0 else { return }
    try handlePermissionFailure(code: errno, path: path)
}

/// Sets an open file to `mode` unless it already has exactly that mode.
func tightenPermissions(ofFileDescriptor fd: Int32, at path: String, to mode: mode_t) throws {
    var info = stat()
    if fstat(fd, &info) == 0, info.st_mode & 0o7777 == mode { return }
    guard fchmod(fd, mode) != 0 else { return }
    try handlePermissionFailure(code: errno, path: path)
}

/// Network and FUSE mounts reject chmod with ENOTSUP, or EPERM when the mount
/// maps ownership to another user. Files there cannot be made owner-only, but
/// refusing to read or update state at all is worse than saying so once and
/// continuing. Any other errno is a real failure and is reported as itself.
func handlePermissionFailure(code: Int32, path: String) throws {
    guard code == ENOTSUP || code == EPERM else {
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    emitWarning(
        "Cannot set owner-only permissions on \(path): \(String(cString: strerror(code))). "
            + "Continuing; other users may be able to read it."
    )
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
    let source: String?
    let recorded_at: String?
    let recording_title: String?
    let voice_memos_unique_id: String?
    let voice_memos_path: String?
    let voice_memos: VoiceMemosOutputMetadata?

    private enum CodingKeys: String, CodingKey {
        case audio_file, audio_files, duration_seconds, model, language
        case diarization_enabled, speaker_strategy, speakers_detected
        case transcribe_version, created_at
        case source, recorded_at, recording_title, voice_memos_unique_id, voice_memos_path, voice_memos
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
        try c.encodeIfPresent(source, forKey: .source)
        try c.encodeIfPresent(recorded_at, forKey: .recorded_at)
        try c.encodeIfPresent(recording_title, forKey: .recording_title)
        try c.encodeIfPresent(voice_memos_unique_id, forKey: .voice_memos_unique_id)
        try c.encodeIfPresent(voice_memos_path, forKey: .voice_memos_path)
        try c.encodeIfPresent(voice_memos, forKey: .voice_memos)
    }
}

struct OutputSourceMetadata: Codable, Equatable {
    let source: String
    let recordedAt: String?
    let recordingTitle: String?
    let voiceMemosUniqueID: String?
    let voiceMemosPath: String?
    let voiceMemos: VoiceMemosOutputMetadata?

    init(
        source: String,
        recordedAt: String?,
        recordingTitle: String?,
        voiceMemosUniqueID: String?,
        voiceMemosPath: String?,
        voiceMemos: VoiceMemosOutputMetadata? = nil
    ) {
        self.source = source
        self.recordedAt = recordedAt
        self.recordingTitle = recordingTitle
        self.voiceMemosUniqueID = voiceMemosUniqueID
        self.voiceMemosPath = voiceMemosPath
        self.voiceMemos = voiceMemos
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
    sourceMetadata: OutputSourceMetadata? = nil,
    model: String,
    version: String,
    createdAt date: Date = Date()
) throws -> Data {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let createdAt = formatter.string(from: date)

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
        created_at: createdAt,
        source: sourceMetadata?.source,
        recorded_at: sourceMetadata?.recordedAt,
        recording_title: sourceMetadata?.recordingTitle,
        voice_memos_unique_id: sourceMetadata?.voiceMemosUniqueID,
        voice_memos_path: sourceMetadata?.voiceMemosPath,
        voice_memos: sourceMetadata?.voiceMemos
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
    sourceMetadata: OutputSourceMetadata? = nil,
    model: String,
    version: String,
    createdAt date: Date = Date()
) -> String {
    let basename = (audioFile as NSString).lastPathComponent
    let title = markdownSanitizeHeadingFragment((basename as NSString).deletingPathExtension)
    let titleLine = title.isEmpty ? "# Transcript" : "# \(title)"

    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let createdAt = formatter.string(from: date)
    let frontmatter = renderMarkdownFrontmatter(
        output: output,
        audioFile: audioFile,
        audioFiles: audioFiles,
        sourceMetadata: sourceMetadata,
        model: model,
        version: version,
        createdAt: createdAt
    )

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
    if let sourceMetadata {
        metaLines.append("- **Input source:** `\(sourceMetadata.source)`")
        if let recordedAt = sourceMetadata.recordedAt {
            metaLines.append("- **Recorded:** \(recordedAt)")
        }
        if let title = sourceMetadata.recordingTitle {
            metaLines.append("- **Recording title:** `\(title)`")
        }
        if let uniqueID = sourceMetadata.voiceMemosUniqueID {
            metaLines.append("- **Voice Memos ID:** `\(uniqueID)`")
        }
        if let path = sourceMetadata.voiceMemosPath {
            metaLines.append("- **Voice Memos path:** `\(path)`")
        }
    }
    if let lang = output.language {
        metaLines.append("- **Language:** `\(lang)`")
    }
    metaLines.append("- **Diarization:** \(output.diarizationEnabled ? "on" : "off")")
    if output.diarizationEnabled {
        metaLines.append("- **Speaker merge:** `\(output.speakerStrategy)`")
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
        return "\(frontmatter)\n\(titleLine)\n\n\(meta)\n"
    }
    return "\(frontmatter)\n\(titleLine)\n\n\(meta)\n\(body)\n"
}

private func renderMarkdownFrontmatter(
    output: TranscriptionOutput,
    audioFile: String,
    audioFiles: [String]?,
    sourceMetadata: OutputSourceMetadata?,
    model: String,
    version: String,
    createdAt: String
) -> String {
    let basename = (audioFile as NSString).lastPathComponent
    var lines: [String] = [
        "---",
        "audio_file: \(yamlQuoted(basename))",
    ]
    if let audioFiles, !audioFiles.isEmpty {
        lines.append("audio_files:")
        for file in audioFiles {
            lines.append("  - \(yamlQuoted(file))")
        }
    }
    lines.append("duration_seconds: \(yamlNumber(output.durationSeconds))")
    lines.append("model: \(yamlQuoted(model))")
    if let language = output.language {
        lines.append("language: \(yamlQuoted(language))")
    }
    lines.append("diarization_enabled: \(output.diarizationEnabled ? "true" : "false")")
    lines.append("speaker_strategy: \(yamlQuoted(output.speakerStrategy))")
    if let speakersDetected = output.speakersDetected {
        lines.append("speakers_detected: \(speakersDetected)")
    }
    lines.append("transcribe_version: \(yamlQuoted(version))")
    lines.append("created_at: \(yamlQuoted(createdAt))")

    if let sourceMetadata {
        lines.append("source: \(yamlQuoted(sourceMetadata.source))")
        appendOptionalString(sourceMetadata.recordedAt, key: "recorded_at", indent: "", to: &lines)
        appendOptionalString(sourceMetadata.recordingTitle, key: "recording_title", indent: "", to: &lines)
        appendOptionalString(sourceMetadata.voiceMemosUniqueID, key: "voice_memos_unique_id", indent: "", to: &lines)
        appendOptionalString(sourceMetadata.voiceMemosPath, key: "voice_memos_path", indent: "", to: &lines)
        if let voiceMemos = sourceMetadata.voiceMemos {
            appendVoiceMemosYAML(voiceMemos, to: &lines)
        }
    }

    lines.append("---")
    lines.append("")
    return lines.joined(separator: "\n")
}

private func appendVoiceMemosYAML(_ metadata: VoiceMemosOutputMetadata, to lines: inout [String]) {
    lines.append("voice_memos:")
    lines.append("  session_title: \(yamlQuoted(metadata.sessionTitle))")
    lines.append("  recording_count: \(metadata.recordingCount)")
    lines.append("  recordings:")
    for recording in metadata.recordings {
        lines.append("    - title: \(yamlQuoted(recording.title))")
        lines.append("      title_source: \(yamlQuoted(recording.titleSource.rawValue))")
        appendOptionalString(recording.titleForSorting, key: "title_for_sorting", indent: "      ", to: &lines)
        lines.append("      recorded_at: \(yamlQuoted(recording.recordedAt))")
        appendOptionalNumber(recording.durationSeconds, key: "duration_seconds", indent: "      ", to: &lines)
        appendOptionalString(recording.uniqueID, key: "unique_id", indent: "      ", to: &lines)
        appendOptionalString(recording.path, key: "path", indent: "      ", to: &lines)
        appendOptionalInt(recording.folderID, key: "folder_id", indent: "      ", to: &lines)
        appendOptionalInt(recording.flags, key: "flags", indent: "      ", to: &lines)
        appendOptionalString(recording.audioDigestHex, key: "audio_digest", indent: "      ", to: &lines)
        if let enhancements = recording.enhancements {
            lines.append("      enhancements:")
            appendOptionalInt(enhancements.audioFutureFlags, key: "audio_future_flags", indent: "        ", to: &lines)
            appendOptionalInt(enhancements.sharedFlags, key: "shared_flags", indent: "        ", to: &lines)
            appendOptionalBool(enhancements.silenceRemoverEnabled, key: "silence_remover_enabled", indent: "        ", to: &lines)
            appendOptionalBool(enhancements.skipSilenceEnabled, key: "skip_silence_enabled", indent: "        ", to: &lines)
            appendOptionalBool(enhancements.studioMixEnabled, key: "studio_mix_enabled", indent: "        ", to: &lines)
            appendOptionalNumber(enhancements.studioMixLevel, key: "studio_mix_level", indent: "        ", to: &lines)
        }
    }
}

private func appendOptionalString(_ value: String?, key: String, indent: String, to lines: inout [String]) {
    guard let value else { return }
    lines.append("\(indent)\(key): \(yamlQuoted(value))")
}

private func appendOptionalInt(_ value: Int?, key: String, indent: String, to lines: inout [String]) {
    guard let value else { return }
    lines.append("\(indent)\(key): \(value)")
}

private func appendOptionalBool(_ value: Bool?, key: String, indent: String, to lines: inout [String]) {
    guard let value else { return }
    lines.append("\(indent)\(key): \(value ? "true" : "false")")
}

private func appendOptionalNumber(_ value: Double?, key: String, indent: String, to lines: inout [String]) {
    guard let value else { return }
    lines.append("\(indent)\(key): \(yamlNumber(value))")
}

private func yamlQuoted(_ value: String) -> String {
    let escaped = value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
    return "\"\(escaped)\""
}

private func yamlNumber(_ value: Double) -> String {
    String(format: "%.6g", value)
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

// MARK: - TSV

/// Matches whisperx's segment-level TSV: header line, integer milliseconds,
/// three columns, and no speaker column. Milliseconds use ties-to-even
/// rounding so exact half-millisecond values match Python's `round()`, which
/// is what whisperx applies to the same values.
func renderTSV(output: TranscriptionOutput) -> String {
    var lines: [String] = ["start\tend\ttext"]
    for seg in output.segments {
        let start = Int((seg.start * 1000).rounded(.toNearestOrEven))
        let end = Int((seg.end * 1000).rounded(.toNearestOrEven))
        let text = seg.text
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("\(start)\t\(end)\t\(text)")
    }
    return lines.joined(separator: "\n")
}

// MARK: - Write all outputs

/// Writes requested output formats. Uses atomic writes.
/// - Parameter audioFiles: When the input was a directory of clips, the source filenames in concat order; nil for single-file input.
/// The exact bytes one output format would contain, or nil for an unknown
/// format. Shared by writeOutputs and the export-refresh routine so a
/// re-render is byte-identical to the original write when nothing changed.
func renderOutputData(
    format: String,
    output: TranscriptionOutput,
    audioPath: String,
    audioFiles: [String]? = nil,
    sourceMetadata: OutputSourceMetadata? = nil,
    model: String,
    version: String,
    createdAt: Date = Date()
) throws -> Data? {
    switch format {
    case "json":
        return try renderJSON(
            output: output,
            audioFile: audioPath,
            audioFiles: audioFiles,
            sourceMetadata: sourceMetadata,
            model: model,
            version: version,
            createdAt: createdAt
        )
    case "txt":
        return (renderTxt(output: output) + "\n").data(using: .utf8)!
    case "srt":
        return (renderSRT(output: output) + "\n").data(using: .utf8)!
    case "vtt":
        return (renderVTT(output: output) + "\n").data(using: .utf8)!
    case "tsv":
        return (renderTSV(output: output) + "\n").data(using: .utf8)!
    case "md":
        let text = renderMarkdown(
            output: output,
            audioFile: audioPath,
            audioFiles: audioFiles,
            sourceMetadata: sourceMetadata,
            model: model,
            version: version,
            createdAt: createdAt
        )
        return text.data(using: .utf8)!
    default:
        return nil
    }
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Device and inode of an existing file, or nil when it does not exist.
/// Two paths naming the same identity are the same file whatever the
/// spelling: a case-insensitive volume, a symlink, or a hard link.
func fileIdentity(_ path: String) -> String? {
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    return "\(info.st_dev):\(info.st_ino)"
}

@discardableResult
func writeOutputs(
    output: TranscriptionOutput,
    audioPath: String,
    audioFiles: [String]? = nil,
    sourceMetadata: OutputSourceMetadata? = nil,
    outputDir: String,
    basename: String,
    formats: [String],
    overwrite: Bool,
    model: String,
    version: String,
    createdAt: Date = Date()
) throws -> [ExportRecord] {
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
        writeTxtFile: formats.contains("txt"),
        overwrite: overwrite
    )

    var records: [ExportRecord] = []
    for f in formats {
        guard let data = try renderOutputData(
            format: f, output: output, audioPath: audioPath, audioFiles: audioFiles,
            sourceMetadata: sourceMetadata, model: model, version: version, createdAt: createdAt
        ) else { continue }
        let path = (dir as NSString).appendingPathComponent("\(basename).\(f)")
        try writeAtomically(content: data, to: path)
        records.append(ExportRecord(path: path, format: f, sha256: sha256Hex(data), exportedAt: Date()))
    }
    return records
}
