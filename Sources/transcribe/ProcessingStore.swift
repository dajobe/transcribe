import CryptoKit
import Foundation

enum ProcessingSourceKind: String, Codable, Equatable {
    case file
    case directorySession = "directory_session"
    case voiceMemos = "voice_memos"
    case importedBaseline = "imported_baseline"
    case voiceMemosBaseline = "voice_memos_baseline"
}

enum ProcessingHistoryReason: String, Codable, Equatable {
    case firstRun = "first_run"
    case skipDuplicate = "skip_duplicate"
    case settingsChanged = "settings_changed"
    case missingOutputs = "missing_outputs"
    case redo
    case imported
    case changedFile = "changed_file"
    case legacy
}

enum ProcessingDecisionAction: Equatable {
    case process
    case skip
}

struct ProcessingDecision: Equatable {
    let action: ProcessingDecisionAction
    let reason: ProcessingHistoryReason
    let recordsSkipHistory: Bool

    init(
        action: ProcessingDecisionAction,
        reason: ProcessingHistoryReason,
        recordsSkipHistory: Bool = true
    ) {
        self.action = action
        self.reason = reason
        self.recordsSkipHistory = recordsSkipHistory
    }

    var shouldSkip: Bool { action == .skip }
}

struct FileFingerprint: Codable, Equatable {
    let path: String
    let sha256: String
    let bytes: Int64
    let mtime: String?
}

struct SourceFingerprint: Codable, Equatable {
    let files: [FileFingerprint]
}

struct ProcessingSettingsSignature: Codable, Equatable {
    let model: String
    let language: String?
    let diarization_enabled: Bool
    let speaker_strategy: String
    let min_speakers: Int?
    let max_speakers: Int?
    let formats: [String]
    let transcribe_version: String
    let legacy_write_txt_to_stdout: Bool

    enum CodingKeys: String, CodingKey {
        case model
        case language
        case diarization_enabled
        case speaker_strategy
        case min_speakers
        case max_speakers
        case formats
        case write_txt_to_stdout
        case transcribe_version
    }

    init(
        model: String,
        language: String?,
        diarization_enabled: Bool,
        speaker_strategy: String,
        min_speakers: Int?,
        max_speakers: Int?,
        formats: [String],
        transcribe_version: String,
        legacy_write_txt_to_stdout: Bool = false
    ) {
        self.model = model
        self.language = language
        self.diarization_enabled = diarization_enabled
        self.speaker_strategy = speaker_strategy
        self.min_speakers = min_speakers
        self.max_speakers = max_speakers
        self.formats = formats
        self.transcribe_version = transcribe_version
        self.legacy_write_txt_to_stdout = legacy_write_txt_to_stdout
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decode(String.self, forKey: .model)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        diarization_enabled = try container.decode(Bool.self, forKey: .diarization_enabled)
        speaker_strategy = try container.decode(String.self, forKey: .speaker_strategy)
        min_speakers = try container.decodeIfPresent(Int.self, forKey: .min_speakers)
        max_speakers = try container.decodeIfPresent(Int.self, forKey: .max_speakers)
        formats = try container.decode([String].self, forKey: .formats)
        transcribe_version = try container.decode(String.self, forKey: .transcribe_version)
        legacy_write_txt_to_stdout = try container.decodeIfPresent(Bool.self, forKey: .write_txt_to_stdout) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encode(diarization_enabled, forKey: .diarization_enabled)
        try container.encode(speaker_strategy, forKey: .speaker_strategy)
        try container.encodeIfPresent(min_speakers, forKey: .min_speakers)
        try container.encodeIfPresent(max_speakers, forKey: .max_speakers)
        try container.encode(formats, forKey: .formats)
        try container.encode(transcribe_version, forKey: .transcribe_version)
    }

    func isCompatibleForSkip(with other: ProcessingSettingsSignature) -> Bool {
        model == other.model
            && language == other.language
            && diarization_enabled == other.diarization_enabled
            && speaker_strategy == other.speaker_strategy
            && min_speakers == other.min_speakers
            && max_speakers == other.max_speakers
            && formats == other.formats
            && !legacy_write_txt_to_stdout
            && !other.legacy_write_txt_to_stdout
    }
}

struct ProcessingRecord: Codable, Equatable {
    static let schemaVersion = 1

    var schema_version: Int = schemaVersion
    let completed_at: String
    let history_reason: ProcessingHistoryReason?
    let source_kind: ProcessingSourceKind
    let source_id: String
    let source_fingerprint: SourceFingerprint
    let settings_signature: ProcessingSettingsSignature?
    let output_dir: String?
    let basename: String?
    let output_paths: [String]
    let audio_duration_s: Double?
    let warning_count: Int
    let recording_title: String?
    let recorded_at: String?
    let voice_memos_unique_id: String?
    let voice_memos_path: String?
}

enum ProcessingStore {
    static func append(_ record: ProcessingRecord) throws {
        let url = try StatePaths.processingHistoryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard var line = String(data: data, encoding: .utf8) else {
            throw TranscribeError(message: "Failed to encode processing record.", exitCode: .outputWrite)
        }
        line.append("\n")
        try LockedAppendWriter.append(Data(line.utf8), to: url)
    }

    static func loadRecords() throws -> [ProcessingRecord] {
        let url = try StatePaths.processingHistoryURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        var out: [ProcessingRecord] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let row = line.data(using: .utf8),
                  let record = try? decoder.decode(ProcessingRecord.self, from: row) else {
                continue
            }
            out.append(record)
        }
        return out
    }

    static func shouldSkipCompleted(
        sourceKind: ProcessingSourceKind,
        sourceID: String,
        fingerprint: SourceFingerprint,
        settings: ProcessingSettingsSignature,
        outputPaths: [String]
    ) throws -> Bool {
        try completionDecision(
            sourceKind: sourceKind,
            sourceID: sourceID,
            fingerprint: fingerprint,
            settings: settings,
            outputPaths: outputPaths
        ).shouldSkip
    }

    static func completionDecision(
        sourceKind: ProcessingSourceKind,
        sourceID: String,
        fingerprint: SourceFingerprint,
        settings: ProcessingSettingsSignature,
        outputPaths: [String]
    ) throws -> ProcessingDecision {
        let records = try loadRecords()
        for record in records.reversed() {
            guard record.source_kind == sourceKind,
                  record.source_id == sourceID else {
                continue
            }
            guard record.source_fingerprint == fingerprint else {
                return ProcessingDecision(action: .process, reason: .changedFile)
            }
            guard let prior = record.settings_signature,
                  prior.isCompatibleForSkip(with: settings),
                  record.output_paths == outputPaths else {
                return ProcessingDecision(action: .process, reason: .settingsChanged)
            }
            if outputPaths.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) {
                return ProcessingDecision(action: .skip, reason: .skipDuplicate)
            }
            return ProcessingDecision(action: .process, reason: .missingOutputs)
        }
        return ProcessingDecision(action: .process, reason: .firstRun)
    }

    static func shouldSkipImportedBaseline(
        sourceID: String,
        fingerprint: SourceFingerprint
    ) throws -> Bool {
        try importedBaselineDecision(sourceID: sourceID, fingerprint: fingerprint).shouldSkip
    }

    static func importedBaselineDecision(
        sourceID: String,
        fingerprint: SourceFingerprint
    ) throws -> ProcessingDecision {
        let records = try loadRecords()
        for record in records.reversed() {
            guard record.source_kind == .importedBaseline || record.source_kind == .voiceMemosBaseline,
                  record.source_id == sourceID else {
                continue
            }
            guard record.source_fingerprint == fingerprint else {
                return ProcessingDecision(action: .process, reason: .changedFile)
            }
            return ProcessingDecision(action: .skip, reason: .skipDuplicate, recordsSkipHistory: false)
        }
        return ProcessingDecision(action: .process, reason: .firstRun)
    }

    /// Path-agnostic dedup: skip a planned run when every input file's
    /// SHA-256 was already present in some prior record's fingerprint.
    ///
    /// - Completed records (`file`, `directory_session`, `voice_memos`) only
    ///   match when their `settings_signature` is compatible with `settings`
    ///   AND their recorded `output_paths` still exist on disk; otherwise the prior
    ///   transcript is gone or stale and we re-run.
    /// - Baseline records (`imported_baseline`, `voice_memos_baseline`) match
    ///   on content alone — they exist precisely to say "treat as done"
    ///   without producing outputs.
    ///
    /// Subset semantics: a new session matches when its hash set is a subset
    /// of a prior record's hash set (so a single-file run can match a
    /// previous multi-file session, but a new session containing genuinely
    /// new files does not).
    static func shouldSkipByContent(
        fingerprint: SourceFingerprint,
        settings: ProcessingSettingsSignature
    ) throws -> Bool {
        try contentDecision(fingerprint: fingerprint, settings: settings).shouldSkip
    }

    static func contentDecision(
        fingerprint: SourceFingerprint,
        settings: ProcessingSettingsSignature
    ) throws -> ProcessingDecision {
        let needed = Set(fingerprint.files.map { $0.sha256 })
        guard !needed.isEmpty else {
            return ProcessingDecision(action: .process, reason: .firstRun)
        }

        let records = try loadRecords()
        var pendingReason: ProcessingHistoryReason?
        for record in records.reversed() {
            let recorded = Set(record.source_fingerprint.files.map { $0.sha256 })
            guard !recorded.isEmpty, needed.isSubset(of: recorded) else { continue }

            switch record.source_kind {
            case .importedBaseline, .voiceMemosBaseline:
                return ProcessingDecision(action: .skip, reason: .skipDuplicate, recordsSkipHistory: false)
            case .file, .directorySession, .voiceMemos:
                guard let prior = record.settings_signature,
                      prior.isCompatibleForSkip(with: settings) else {
                    pendingReason = pendingReason ?? .settingsChanged
                    continue
                }
                if !record.output_paths.isEmpty,
                   record.output_paths.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) {
                    return ProcessingDecision(action: .skip, reason: .skipDuplicate)
                }
                pendingReason = pendingReason ?? .missingOutputs
            }
        }
        return ProcessingDecision(action: .process, reason: pendingReason ?? .firstRun)
    }

    static func fingerprint(files paths: [String]) throws -> SourceFingerprint {
        let files = try paths.map { path in
            try fingerprint(file: path)
        }
        return SourceFingerprint(files: files)
    }

    private static func fingerprint(file path: String) throws -> FileFingerprint {
        let expanded = (path as NSString).expandingTildeInPath
        do {
            let url = URL(fileURLWithPath: expanded)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            // Stream the file through SHA256 in 1 MiB chunks so multi-hour
            // recordings don't pin the whole file in memory.
            var hasher = SHA256()
            var byteCount: Int64 = 0
            let chunkSize = 1 << 20
            while true {
                let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
                byteCount += Int64(chunk.count)
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()

            let attrs = try FileManager.default.attributesOfItem(atPath: expanded)
            let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? byteCount
            let mtime = (attrs[.modificationDate] as? Date).map(iso8601String)
            return FileFingerprint(
                path: url.standardizedFileURL.path,
                sha256: digest,
                bytes: bytes,
                mtime: mtime
            )
        } catch {
            throw TranscribeError(
                message: "Failed to fingerprint input file: \(path): \(error.localizedDescription)",
                exitCode: .inputFile
            )
        }
    }
}

func iso8601String(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

func sourceIDForFiles(kind: ProcessingSourceKind, files: [String]) -> String {
    let paths = files.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL.path }
    return "\(kind.rawValue):" + paths.joined(separator: "\u{1f}")
}
