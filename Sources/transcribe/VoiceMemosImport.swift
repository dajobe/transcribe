import Foundation

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
              \(quotedColumnOrNull("ZFOLDER")),
              \(quotedColumnOrNull("ZCUSTOMLABELFORSORTING")),
              \(quotedColumnOrNull("ZAUDIOFUTUREFLAGS")),
              \(quotedColumnOrNull("ZSHAREDFLAGS")),
              \(quotedColumnOrNull("ZSILENCEREMOVERENABLED")),
              \(quotedColumnOrNull("ZSKIPSILENCEENABLED")),
              \(quotedColumnOrNull("ZSTUDIOMIXENABLED")),
              \(quotedColumnOrNull("ZSTUDIOMIXLEVEL"))
            FROM "ZCLOUDRECORDING"
            WHERE \(usableRecordingPredicate(columns: columns))
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

            let (title, titleSource) = resolveTitle(
                customLabel: nilIfEmpty(row.text(6)),
                sortingLabel: nilIfEmpty(row.text(11)),
                encryptedTitle: nilIfEmpty(row.text(7))
            )
            let duration = row.double(4) ?? row.double(5)
            let digestHex = nilIfEmpty(row.blob(8).map { $0.hexEncodedString })
            let enhancements = optionalEnhancements(
                audioFutureFlags: row.int(12).map(Int.init),
                sharedFlags: row.int(13).map(Int.init),
                silenceRemoverEnabled: optionalBool(row.int(14)),
                skipSilenceEnabled: optionalBool(row.int(15)),
                studioMixEnabled: optionalBool(row.int(16)),
                studioMixLevel: row.double(17)
            )
            return VoiceMemoRecording(
                primaryKey: primaryKey,
                uniqueID: nilIfEmpty(row.text(1)),
                path: resolvedPath,
                recordedAt: Date(timeIntervalSinceReferenceDate: dateSeconds),
                durationSeconds: duration,
                title: title,
                audioDigestHex: digestHex,
                flags: row.int(9).map(Int.init),
                folderID: row.int(10).map(Int.init),
                titleSource: titleSource,
                titleForSorting: nilIfEmpty(row.text(11)),
                enhancements: enhancements
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
            let title = sanitizeVoiceMemoTitle(sessionTitle(for: group, sessionIndex: index + 1))
            return "\(voiceMemoBasenameDate(recordedAt)) \(title)"
        }
        return uniqued(raw)
    }

    static func outputMetadata(for recording: VoiceMemoRecording) -> OutputSourceMetadata {
        let sessionTitle = sessionTitle(for: [recording], sessionIndex: 1)
        return OutputSourceMetadata(
            source: "voice_memos",
            recordedAt: iso8601String(recording.recordedAt),
            recordingTitle: sessionTitle,
            voiceMemosUniqueID: recording.uniqueID,
            voiceMemosPath: recording.path,
            voiceMemos: VoiceMemosOutputMetadata(
                sessionTitle: sessionTitle,
                recordingCount: 1,
                recordings: [recording.outputRecording()]
            )
        )
    }

    static func outputMetadata(for recordings: [VoiceMemoRecording], sessionIndex: Int = 1) -> OutputSourceMetadata? {
        guard let first = recordings.first else { return nil }
        if recordings.count == 1 {
            return outputMetadata(for: first)
        }
        let sessionTitle = sessionTitle(for: recordings, sessionIndex: sessionIndex)
        return OutputSourceMetadata(
            source: "voice_memos",
            recordedAt: iso8601String(first.recordedAt),
            recordingTitle: sessionTitle,
            voiceMemosUniqueID: nil,
            voiceMemosPath: nil,
            voiceMemos: VoiceMemosOutputMetadata(
                sessionTitle: sessionTitle,
                recordingCount: recordings.count,
                recordings: recordings.map { $0.outputRecording() }
            )
        )
    }

    static func sessionTitle(for recordings: [VoiceMemoRecording], sessionIndex: Int) -> String {
        guard !recordings.isEmpty else { return "Voice Memos Session \(sessionIndex)" }
        if recordings.count == 1, let first = recordings.first {
            return first.title
        }

        let usefulTitles = recordings
            .filter(\.hasUserTitle)
            .map(\.title)
            .map(sanitizeVoiceMemoTitle)
            .filter { !$0.isEmpty }
        let base = commonTitlePrefix(usefulTitles)
            ?? usefulTitles.first
            ?? "Voice Memos Session \(sessionIndex)"
        return "\(base) +\(recordings.count) memos"
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
        let names = try database.query(#"PRAGMA table_info("ZCLOUDRECORDING");"#) { row in
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

    private static func usableRecordingPredicate(columns: Set<String>) -> String {
        var predicates = [
            #""ZPATH" IS NOT NULL"#,
            #""ZPATH" != ''"#,
            #""ZDATE" IS NOT NULL"#,
        ]
        if columns.contains("ZEVICTIONDATE") {
            predicates.append(#""ZEVICTIONDATE" IS NULL"#)
        }
        return predicates.joined(separator: " AND ")
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

    private static func resolveTitle(
        customLabel: String?,
        sortingLabel: String?,
        encryptedTitle: String?
    ) -> (String, VoiceMemoTitleSource) {
        if let customLabel, !isTimestampFallbackTitle(customLabel) {
            return (customLabel, .customLabel)
        }
        if let sortingLabel, !isTimestampFallbackTitle(sortingLabel) {
            return (sortingLabel, .sortingLabel)
        }
        if let encryptedTitle, !isTimestampFallbackTitle(encryptedTitle) {
            return (encryptedTitle, .encryptedTitle)
        }
        if let customLabel {
            return (customLabel, .customLabel)
        }
        if let sortingLabel {
            return (sortingLabel, .sortingLabel)
        }
        if let encryptedTitle {
            return (encryptedTitle, .encryptedTitle)
        }
        return ("New Recording", .fallback)
    }

    private static func isTimestampFallbackTitle(_ value: String) -> Bool {
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}[: ]\d{2}[: ]\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})$"#
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: pattern, options: .regularExpression) != nil
    }

    private static func optionalBool(_ value: Int64?) -> Bool? {
        value.map { $0 != 0 }
    }

    private static func optionalEnhancements(
        audioFutureFlags: Int?,
        sharedFlags: Int?,
        silenceRemoverEnabled: Bool?,
        skipSilenceEnabled: Bool?,
        studioMixEnabled: Bool?,
        studioMixLevel: Double?
    ) -> VoiceMemoEnhancements? {
        let enhancements = VoiceMemoEnhancements(
            audioFutureFlags: audioFutureFlags,
            sharedFlags: sharedFlags,
            silenceRemoverEnabled: silenceRemoverEnabled,
            skipSilenceEnabled: skipSilenceEnabled,
            studioMixEnabled: studioMixEnabled,
            studioMixLevel: studioMixLevel
        )
        return enhancements.isEmpty ? nil : enhancements
    }

    private static func commonTitlePrefix(_ titles: [String]) -> String? {
        guard titles.count >= 2 else { return nil }
        var prefix = titles[0]
        for title in titles.dropFirst() {
            prefix = prefix.commonPrefix(with: title)
            if prefix.isEmpty { return nil }
        }
        let trimmed = stripTrailingSequenceMarkers(prefix)
        guard !trimmed.isEmpty else { return nil }
        let shortestLen = titles.map(\.count).min() ?? 0
        guard trimmed.count >= 8 else { return nil }
        guard Double(trimmed.count) >= 0.3 * Double(shortestLen) else { return nil }
        return trimmed
    }

    private static func stripTrailingSequenceMarkers(_ value: String) -> String {
        var result = value
        let trailingChars: Set<Character> = [" ", "\t", "-", "_", "(", "0"]
        var changed = true
        while changed {
            changed = false
            while let last = result.last, trailingChars.contains(last) || last.isWhitespace {
                result.removeLast()
                changed = true
            }
            if result.lowercased().hasSuffix("part") {
                result.removeLast(4)
                changed = true
            }
        }
        return result
    }
}
