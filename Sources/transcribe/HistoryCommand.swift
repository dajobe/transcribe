import Foundation

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
            let path = (try? StatePaths.processingHistoryURL().path) ?? "<unknown>"
            HistoryCommand.write("No processing history yet (\(path)).\n")
            return
        }

        let rendered = HistoryFormatter.format(records: recent, now: Date()) + "\n"
        HistoryCommand.write(rendered)
    }

    private static func write(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
    }
}

enum HistoryFormatter {
    static let timeColumnWidth = 18
    static let kindColumnWidth = 18

    static func format(records: [ProcessingRecord], now: Date) -> String {
        records.map { line(for: $0, now: now) }.joined(separator: "\n")
    }

    static func line(for record: ProcessingRecord, now: Date) -> String {
        let time = formatTimestamp(record.completed_at, now: now)
        let kind = displayKind(record.source_kind)
        let label = displayLabel(record)
        return pad(time, timeColumnWidth) + "  " + pad(kind, kindColumnWidth) + "  " + label
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

    static func displayKind(_ kind: ProcessingSourceKind) -> String {
        switch kind {
        case .file: return "transcribed file"
        case .directorySession: return "transcribed dir"
        case .voiceMemos: return "transcribed voice"
        case .importedBaseline: return "imported"
        case .voiceMemosBaseline: return "imported voice"
        }
    }

    static func displayLabel(_ record: ProcessingRecord) -> String {
        if let title = record.recording_title, !title.isEmpty {
            return title
        }
        if let basename = record.basename, !basename.isEmpty {
            return basename
        }
        return record.source_id
    }

    static func pad(_ value: String, _ width: Int) -> String {
        let length = value.count
        if length >= width { return value }
        return value + String(repeating: " ", count: width - length)
    }
}
