import Foundation

private func safeText(_ text: String) -> String {
    text.components(separatedBy: .controlCharacters).joined(separator: " ")
}

/// Renders entries from the processing-history ledger.
enum HistoryCommand {
    static func run(count: Int) throws {
        guard count > 0 else {
            throw TranscribeError(
                message: "--count must be a positive integer.",
                exitCode: .invalidUsage
            )
        }

        let records = try ProcessingStore.loadRecords()
        // completed_at is canonical ISO 8601 UTC, so lexical sort == chronological sort.
        let sorted = records.sorted { $0.completed_at > $1.completed_at }
        let recent = Array(sorted.prefix(count))

        if recent.isEmpty {
            let path = (try? StatePaths.stateDatabaseURL().path) ?? "<unknown>"
            HistoryCommand.write("No processing history yet (state database \(path)).\n")
            return
        }

        // Document IDs are a convenience join; a failure to read them must
        // not take the history listing down with it.
        let join = (try? CanonicalTranscriptStore.documentIDsBySourceHashes()) ?? [:]
        let abbreviator = IDAbbreviator.fromStore()
        var documentIDs: [String: String] = [:]
        for record in recent {
            guard let key = HistoryFormatter.sourceHashesKey(record.source_fingerprint.files.map(\.sha256)),
                  let id = join[key] else { continue }
            documentIDs[key] = abbreviator.shorten(id)
        }
        let rendered = HistoryFormatter.format(records: recent, now: Date(), documentIDs: documentIDs) + "\n"
        HistoryCommand.write(rendered)
    }

    private static func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }
}

enum HistoryFormatter {
    /// Wide enough for a full stored timestamp ("2026-10-12T15:54:03Z", 20
    /// characters), which the relative phrasing falls back to after a week.
    static let timeColumnWidth = 20
    /// Minimum ID column width: `IDAbbreviator.floor`. The caller passes IDs
    /// already shortened git-style, and the column widens to the longest one.
    static let idColumnWidth = IDAbbreviator.floor
    static let whyColumnWidth = 11
    static let kindColumnWidth = 6
    static let recordedColumnWidth = 12

    static func format(records: [ProcessingRecord], now: Date, documentIDs: [String: String] = [:]) -> String {
        let idWidth = max(
            idColumnWidth,
            records.map { displayDocumentID($0, documentIDs: documentIDs).count }.max() ?? 0
        )
        // Style the header as one whole line: ANSI codes inside padded
        // columns would not change visible alignment, but styling after
        // padding keeps the width arithmetic obviously untouched.
        return ([Terminal.stdout.bold(header(idWidth: idWidth))]
            + records.map { line(for: $0, now: now, documentIDs: documentIDs, idWidth: idWidth) })
            .joined(separator: "\n")
    }

    static func header(idWidth: Int = idColumnWidth) -> String {
        pad("WHEN", timeColumnWidth) + "  "
            + pad("ID", idWidth) + "  "
            + pad("WHY", whyColumnWidth) + "  "
            + pad("KIND", kindColumnWidth) + "  "
            + pad("RECORDED", recordedColumnWidth) + "  "
            + "FILE"
    }

    static func line(for record: ProcessingRecord, now: Date, documentIDs: [String: String] = [:], idWidth: Int = idColumnWidth) -> String {
        // The timestamp fallback and the label come from ledger records,
        // which imports can fill with arbitrary text; sanitize like the ID.
        let time = safeText(formatTimestamp(record.completed_at, now: now))
        let id = displayDocumentID(record, documentIDs: documentIDs)
        let why = displayReason(record)
        let kind = displayKind(record)
        let recorded = displayRecordedAt(record)
        let label = safeText(displayLabel(record))
        return pad(time, timeColumnWidth) + "  "
            + pad(id, idWidth) + "  "
            + pad(why, whyColumnWidth) + "  "
            + pad(kind, kindColumnWidth) + "  "
            + pad(recorded, recordedColumnWidth) + "  "
            + label
    }

    /// The saved document covering the same audio bytes, joined through the
    /// source fingerprint, or "-" when none matches (stateless runs, deleted
    /// documents, records without fingerprints). A corrupt stored ID may
    /// hold control characters, so they are replaced before the text sizes
    /// the column or reaches the terminal.
    static func displayDocumentID(_ record: ProcessingRecord, documentIDs: [String: String]) -> String {
        guard let key = sourceHashesKey(record.source_fingerprint.files.map(\.sha256)),
              let id = documentIDs[key] else { return "-" }
        return safeText(id)
    }

    /// Canonical lookup key for a set of source content hashes: the match is
    /// set equality, the same rule `ExportRefresh.staleExportHint` applies.
    static func sourceHashesKey(_ hashes: [String]) -> String? {
        let normalized = Set(hashes.map { $0.lowercased() })
        guard !normalized.isEmpty else { return nil }
        return normalized.sorted().joined(separator: "\n")
    }

    /// Relative phrase for the most recent week ("just now", "5 mins ago",
    /// "3 days ago"); falls back to the stored ISO 8601 string for anything
    /// older than seven days or unparseable.
    static func formatTimestamp(_ stored: String, now: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: stored) else { return stored }
        let delta = now.timeIntervalSince(date)
        if delta < 0 { return stored }
        if delta < 5 { return "just now" }
        if delta < 60 {
            let secs = Int(delta)
            return secs == 1 ? "1 sec ago" : "\(secs) secs ago"
        }
        let mins = Int(delta / 60)
        if mins < 60 {
            return mins == 1 ? "1 min ago" : "\(mins) mins ago"
        }
        let hours = Int(delta / 3600)
        if hours < 24 {
            return hours == 1 ? "1 hour ago" : "\(hours) hours ago"
        }
        let days = Int(delta / 86400)
        if days < 7 {
            return days == 1 ? "1 day ago" : "\(days) days ago"
        }
        return stored
    }

    static func displayKind(_ record: ProcessingRecord) -> String {
        switch record.source_kind {
        case .file: return "file"
        case .directorySession: return "dir"
        case .voiceMemos: return "voice"
        case .voiceMemosBaseline: return "voice"
        case .importedBaseline:
            // Pre-2.1.2 always wrote `imported_baseline` regardless of source.
            // Voice Memos source ids always start with `voice_memos:`, so we
            // can recover the distinction for old records without rewriting
            // the ledger.
            if record.source_id.hasPrefix("voice_memos:") || record.voice_memos_unique_id != nil {
                return "voice"
            }
            return "import"
        }
    }

    static func displayReason(_ record: ProcessingRecord) -> String {
        let reason = record.history_reason ?? inferredLegacyReason(record)
        switch reason {
        case .firstRun: return "first run"
        case .skipDuplicate: return "skip dup"
        case .settingsChanged: return "settings"
        case .missingOutputs: return "missing out"
        case .redo: return "redo"
        case .imported: return "imported"
        case .changedFile: return "changed file"
        case .legacy: return "legacy"
        }
    }

    static func inferredLegacyReason(_ record: ProcessingRecord) -> ProcessingHistoryReason {
        switch record.source_kind {
        case .importedBaseline, .voiceMemosBaseline:
            return .imported
        case .file, .directorySession, .voiceMemos:
            return .legacy
        }
    }

    /// Date-only ("YYYY-MM-DD") slice of `recorded_at`, or "-" when absent.
    /// `recorded_at` is canonical ISO 8601, so the first 10 characters are
    /// the calendar date in UTC.
    static func displayRecordedAt(_ record: ProcessingRecord) -> String {
        guard let raw = record.recorded_at, raw.count >= 10 else { return "-" }
        return String(raw.prefix(10))
    }

    /// Prefer the actual audio file name. For multi-file sources fall back
    /// to the session basename plus a clip count; if even the fingerprint is
    /// empty (rare; pre-fingerprint records) drop back to title/basename.
    static func displayLabel(_ record: ProcessingRecord) -> String {
        let files = record.source_fingerprint.files
        if files.count == 1 {
            return URL(fileURLWithPath: files[0].path).lastPathComponent
        }
        if files.count > 1 {
            if let basename = record.basename, !basename.isEmpty {
                return "\(basename) (\(files.count) clips)"
            }
            let firstName = URL(fileURLWithPath: files[0].path).lastPathComponent
            return "\(firstName) (+\(files.count - 1) more)"
        }
        if let title = record.recording_title, !title.isEmpty { return title }
        if let basename = record.basename, !basename.isEmpty { return basename }
        return record.source_id
    }

    static func pad(_ value: String, _ width: Int) -> String {
        let length = value.count
        if length >= width { return value }
        return value + String(repeating: " ", count: width - length)
    }
}
