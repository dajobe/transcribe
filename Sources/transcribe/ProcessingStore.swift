import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#endif

enum ProcessingSourceKind: String, Codable, Equatable {
    case file
    case directorySession = "directory_session"
    case voiceMemos = "voice_memos"
    case importedBaseline = "imported_baseline"
    case voiceMemosBaseline = "voice_memos_baseline"
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
    let write_txt_to_stdout: Bool
    let transcribe_version: String
}

struct ProcessingRecord: Codable, Equatable {
    static let schemaVersion = 1

    var schema_version: Int = schemaVersion
    let completed_at: String
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
        try appendProcessingLine(Data(line.utf8), to: url)
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
        let records = try loadRecords()
        for record in records.reversed() {
            guard record.source_kind == sourceKind,
                  record.source_id == sourceID,
                  record.source_fingerprint == fingerprint,
                  record.settings_signature == settings,
                  record.output_paths == outputPaths else {
                continue
            }
            if outputPaths.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) {
                return true
            }
            return false
        }
        return false
    }

    static func shouldSkipImportedBaseline(
        sourceID: String,
        fingerprint: SourceFingerprint
    ) throws -> Bool {
        let records = try loadRecords()
        return records.reversed().contains { record in
            (record.source_kind == .importedBaseline || record.source_kind == .voiceMemosBaseline)
                && record.source_id == sourceID
                && record.source_fingerprint == fingerprint
        }
    }

    /// Path-agnostic dedup: skip a planned run when every input file's
    /// SHA-256 was already present in some prior record's fingerprint.
    ///
    /// - Completed records (`file`, `directory_session`, `voice_memos`) only
    ///   match when their `settings_signature` equals `settings` AND their
    ///   recorded `output_paths` still exist on disk; otherwise the prior
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
        let needed = Set(fingerprint.files.map { $0.sha256 })
        guard !needed.isEmpty else { return false }

        let records = try loadRecords()
        for record in records.reversed() {
            let recorded = Set(record.source_fingerprint.files.map { $0.sha256 })
            guard !recorded.isEmpty, needed.isSubset(of: recorded) else { continue }

            switch record.source_kind {
            case .importedBaseline, .voiceMemosBaseline:
                return true
            case .file, .directorySession, .voiceMemos:
                guard let prior = record.settings_signature, prior == settings else { continue }
                if !record.output_paths.isEmpty,
                   record.output_paths.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) {
                    return true
                }
            }
        }
        return false
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

private func appendProcessingLine(_ data: Data, to url: URL) throws {
    // macOS-only (Package.swift pins platforms: [.macOS(.v14)]). Uses an
    // O_APPEND fd plus an advisory flock(LOCK_EX) so concurrent transcribe
    // invocations serialize their ledger appends.
    let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, mode_t(0o644))
    guard fd >= 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    defer { close(fd) }

    guard flock(fd, LOCK_EX) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    defer { flock(fd, LOCK_UN) }

    try data.withUnsafeBytes { buffer in
        guard let baseAddress = buffer.baseAddress else { return }
        var bytesRemaining = buffer.count
        var offset = 0
        while bytesRemaining > 0 {
            let bytesWritten = write(fd, baseAddress.advanced(by: offset), bytesRemaining)
            if bytesWritten < 0 {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            bytesRemaining -= bytesWritten
            offset += bytesWritten
        }
    }
}
