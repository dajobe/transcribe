import Foundation

struct VoiceMemoRecording: Equatable {
    let primaryKey: Int
    let uniqueID: String?
    let path: String
    let recordedAt: Date
    let durationSeconds: Double?
    let title: String
    let audioDigestHex: String?
    let flags: Int?
    let folderID: Int?

    var sourceID: String {
        if let uniqueID, !uniqueID.isEmpty {
            return "voice_memos:\(uniqueID)"
        }
        return "voice_memos:\(URL(fileURLWithPath: path).standardizedFileURL.path)"
    }
}

enum VoiceMemosImport {
    static let defaultRecordingsDirectory = "~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"

    static func loadRecordings(recordingsDirectory rawDirectory: String, logger: VerboseLogger? = nil) throws -> [VoiceMemoRecording] {
        let directory = (rawDirectory as NSString).expandingTildeInPath
        let dbPath = (directory as NSString).appendingPathComponent("CloudRecordings.db")
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw TranscribeError(
                message: "Cannot read Voice Memos database at \(dbPath). Grant Full Disk Access if macOS reports this path as unavailable.",
                exitCode: .inputFile
            )
        }

        let columns = try loadColumnNames(dbPath: dbPath)
        for required in ["Z_PK", "ZPATH", "ZDATE"] where !columns.contains(required) {
            throw TranscribeError(
                message: "Voice Memos database is missing required column \(required) in ZCLOUDRECORDING.",
                exitCode: .inputFile
            )
        }

        func columnOrEmpty(_ name: String) -> String {
            columns.contains(name) ? "IFNULL(\(name), '')" : "''"
        }

        let sql = """
            SELECT
              Z_PK,
              \(columnOrEmpty("ZUNIQUEID")),
              IFNULL(ZPATH, ''),
              IFNULL(ZDATE, ''),
              \(columnOrEmpty("ZDURATION")),
              \(columnOrEmpty("ZLOCALDURATION")),
              \(columnOrEmpty("ZCUSTOMLABEL")),
              \(columnOrEmpty("ZENCRYPTEDTITLE")),
              \(columns.contains("ZAUDIODIGEST") ? "IFNULL(hex(ZAUDIODIGEST), '')" : "''"),
              \(columnOrEmpty("ZFLAGS")),
              \(columnOrEmpty("ZFOLDER"))
            FROM ZCLOUDRECORDING
            WHERE ZPATH IS NOT NULL AND ZPATH != '' AND ZDATE IS NOT NULL
            ORDER BY ZDATE ASC, Z_PK ASC;
            """
        let rows = try runSQLiteQuery(dbPath: dbPath, sql: sql)
        var recordings: [VoiceMemoRecording] = []
        var skipped = 0
        for row in rows {
            guard row.count == 11,
                  let primaryKey = Int(row[0]),
                  let dateSeconds = Double(row[3]) else {
                skipped += 1
                continue
            }
            let resolvedPath = resolveRecordingPath(row[2], recordingsDirectory: directory)
            guard FileManager.default.fileExists(atPath: resolvedPath) else {
                skipped += 1
                emitWarning("Skipping Voice Memo row \(row[0]); audio file is missing: \(resolvedPath)")
                continue
            }

            let customTitle = nilIfEmpty(row[6])
            let encryptedTitle = nilIfEmpty(row[7])
            let title = customTitle ?? encryptedTitle ?? "New Recording"
            let duration = Double(row[4]) ?? Double(row[5])
            recordings.append(VoiceMemoRecording(
                primaryKey: primaryKey,
                uniqueID: nilIfEmpty(row[1]),
                path: resolvedPath,
                recordedAt: Date(timeIntervalSinceReferenceDate: dateSeconds),
                durationSeconds: duration,
                title: title,
                audioDigestHex: nilIfEmpty(row[8]),
                flags: Int(row[9]),
                folderID: Int(row[10])
            ))
        }

        if let logger {
            logger.log("Voice Memos: loaded \(recordings.count) recording\(recordings.count == 1 ? "" : "s") from CloudRecordings.db")
            if skipped > 0 {
                logger.log("Voice Memos: skipped \(skipped) row\(skipped == 1 ? "" : "s")")
            }
        }
        if recordings.isEmpty {
            throw TranscribeError(
                message: "No usable Voice Memos recordings found in \(directory).",
                exitCode: .inputFile
            )
        }
        return recordings
    }

    static func basenames(for recordings: [VoiceMemoRecording], prefixOverride: String? = nil) -> [String] {
        if let prefixOverride {
            if recordings.count <= 1 { return [prefixOverride] }
            return (1...recordings.count).map { "\(prefixOverride) - Recording \($0)" }
        }

        let raw = recordings.map { recording in
            let date = voiceMemoBasenameDate(recording.recordedAt)
            let title = sanitizeVoiceMemoTitle(recording.title)
            if title.isEmpty {
                return date
            }
            return "\(date) \(title)"
        }
        return uniqued(raw)
    }

    static func sessionBasenames(for groupedRecordings: [[VoiceMemoRecording]], prefixOverride: String? = nil) -> [String] {
        if let prefixOverride {
            if groupedRecordings.count <= 1 { return [prefixOverride] }
            return (1...groupedRecordings.count).map { "\(prefixOverride) - Recording \($0)" }
        }

        let raw = groupedRecordings.enumerated().map { index, group in
            if group.count == 1, let recording = group.first {
                return basenames(for: [recording])[0]
            }
            let recordedAt = group.first?.recordedAt ?? Date(timeIntervalSince1970: 0)
            return "\(voiceMemoBasenameDate(recordedAt)) Voice Memos Session \(index + 1)"
        }
        return uniqued(raw)
    }

    static func outputMetadata(for recording: VoiceMemoRecording) -> OutputSourceMetadata {
        OutputSourceMetadata(
            source: "voice_memos",
            recordedAt: iso8601String(recording.recordedAt),
            recordingTitle: recording.title,
            voiceMemosUniqueID: recording.uniqueID,
            voiceMemosPath: recording.path
        )
    }

    static func outputMetadata(for recordings: [VoiceMemoRecording]) -> OutputSourceMetadata? {
        guard let first = recordings.first else { return nil }
        if recordings.count == 1 {
            return outputMetadata(for: first)
        }
        return OutputSourceMetadata(
            source: "voice_memos",
            recordedAt: iso8601String(first.recordedAt),
            recordingTitle: "Voice Memos session",
            voiceMemosUniqueID: nil,
            voiceMemosPath: nil
        )
    }

    private static func runSQLiteQuery(dbPath: String, sql: String) throws -> [[String]] {
        let separator = "\u{1f}"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-init", "/dev/null", "-readonly", "-batch", "-list", "-separator", separator, dbPath, sql]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw TranscribeError(
                message: "Failed to run sqlite3 for Voice Memos import: \(error.localizedDescription)",
                exitCode: .runtimeFailure
            )
        }

        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let detail = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = detail.isEmpty ? "" : ": \(detail)"
            throw TranscribeError(
                message: "Failed to read Voice Memos database\(suffix). Grant Full Disk Access if macOS denies the recordings directory.",
                exitCode: .inputFile
            )
        }
        let text = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            line.split(separator: Character(separator), omittingEmptySubsequences: false).map(String.init)
        }
    }

    private static func loadColumnNames(dbPath: String) throws -> Set<String> {
        let rows = try runSQLiteQuery(dbPath: dbPath, sql: "PRAGMA table_info(ZCLOUDRECORDING);")
        return Set(rows.compactMap { row in
            guard row.count >= 2 else { return nil }
            return row[1]
        })
    }

    private static func resolveRecordingPath(_ rawPath: String, recordingsDirectory: String) -> String {
        let expanded = (rawPath as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }
        return URL(fileURLWithPath: recordingsDirectory, isDirectory: true)
            .appendingPathComponent(expanded)
            .standardizedFileURL
            .path
    }

    private static func sanitizeVoiceMemoTitle(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\0")
            .union(.newlines)
            .union(.controlCharacters)
        let components = title.components(separatedBy: invalid)
        let cleaned = components.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned == "." || cleaned == ".." { return "Recording" }
        return cleaned
    }

    private static func voiceMemoBasenameDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter.string(from: date)
    }

    private static func uniqued(_ basenames: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return basenames.map { basename in
            let key = basename.lowercased()
            seen[key, default: 0] += 1
            let count = seen[key]!
            if count == 1 { return basename }
            return "\(basename) - \(count)"
        }
    }

    private static func nilIfEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}
