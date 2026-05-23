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

        let database = try ReadOnlyDatabase(path: dbPath)
        let columns = try loadColumnNames(database: database)
        for required in ["Z_PK", "ZPATH", "ZDATE"] where !columns.contains(required) {
            throw TranscribeError(
                message: "Voice Memos database is missing required column \(required) in ZCLOUDRECORDING.",
                exitCode: .inputFile
            )
        }

        func quotedColumnOrNull(_ name: String) -> String {
            Self.quotedColumnOrNull(name, columns: columns)
        }

        let sql = """
            SELECT
              "Z_PK",
              \(quotedColumnOrNull("ZUNIQUEID")),
              "ZPATH",
              "ZDATE",
              \(quotedColumnOrNull("ZDURATION")),
              \(quotedColumnOrNull("ZLOCALDURATION")),
              \(quotedColumnOrNull("ZCUSTOMLABEL")),
              \(quotedColumnOrNull("ZENCRYPTEDTITLE")),
              \(quotedColumnOrNull("ZAUDIODIGEST")),
              \(quotedColumnOrNull("ZFLAGS")),
              \(quotedColumnOrNull("ZFOLDER"))
            FROM ZCLOUDRECORDING
            WHERE "ZPATH" IS NOT NULL AND "ZPATH" != '' AND "ZDATE" IS NOT NULL
            ORDER BY "ZDATE" ASC, "Z_PK" ASC;
            """
        let rawRecordings: [VoiceMemoRecording?] = try database.query(sql) { row in
            guard let primaryKey = row.int(0).map(Int.init),
                  let rawPath = nilIfEmpty(row.text(2)),
                  let dateSeconds = row.double(3) else {
                return nil
            }
            let resolvedPath = resolveRecordingPath(rawPath, recordingsDirectory: directory)
            guard FileManager.default.fileExists(atPath: resolvedPath) else {
                emitWarning("Skipping Voice Memo row \(primaryKey); audio file is missing: \(resolvedPath)")
                return nil
            }

            let customTitle = nilIfEmpty(row.text(6))
            let encryptedTitle = nilIfEmpty(row.text(7))
            let title = customTitle ?? encryptedTitle ?? "New Recording"
            let duration = row.double(4) ?? row.double(5)
            let digestHex = nilIfEmpty(row.blob(8).map { $0.hexEncodedString })
            return VoiceMemoRecording(
                primaryKey: primaryKey,
                uniqueID: nilIfEmpty(row.text(1)),
                path: resolvedPath,
                recordedAt: Date(timeIntervalSinceReferenceDate: dateSeconds),
                durationSeconds: duration,
                title: title,
                audioDigestHex: digestHex,
                flags: row.int(9).map(Int.init),
                folderID: row.int(10).map(Int.init)
            )
        }
        let recordings = rawRecordings.compactMap { $0 }
        let skipped = rawRecordings.count - recordings.count

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

    private static func isSafeColumnName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter, first.isUppercase else { return false }
        for character in name.dropFirst() {
            if character == "_" { continue }
            guard character.isNumber || (character.isLetter && character.isUppercase) else {
                return false
            }
        }
        return true
    }

    private static func quotedColumnOrNull(_ name: String, columns: Set<String>) -> String {
        guard columns.contains(name), isSafeColumnName(name) else { return "NULL" }
        return "\"\(name)\""
    }

    private static func loadColumnNames(database: ReadOnlyDatabase) throws -> Set<String> {
        let names = try database.query("PRAGMA table_info(ZCLOUDRECORDING);") { row in
            row.text(1) ?? ""
        }
        let filtered = names.filter { !$0.isEmpty }
        for name in filtered where !isSafeColumnName(name) {
            throw TranscribeError(
                message: "Voice Memos database has an unexpected column name in ZCLOUDRECORDING: \(name)",
                exitCode: .inputFile
            )
        }
        return Set(filtered)
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

    private static func nilIfEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
