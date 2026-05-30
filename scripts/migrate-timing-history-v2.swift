#!/usr/bin/env swift

import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

let v2Fields: [String: Any] = [
    "whisper_audio_processing_ms": 0,
    "whisper_logmels_ms": 0,
    "whisper_encoding_ms": 0,
    "whisper_decoding_loop_ms": 0,
    "whisper_total_audio_processing_runs": 0,
    "whisper_total_logmel_runs": 0,
    "whisper_total_encoding_runs": 0,
    "whisper_total_decoding_windows": 0,
    "whisper_first_progress_ms": 0,
    "speaker_diarization_ms": 0,
    "speaker_segmenter_ms": 0,
    "speaker_embedder_ms": 0,
    "speaker_clustering_ms": 0,
    "speaker_total_chunks": 0,
    "speaker_total_embeddings": 0,
]

struct MigrationError: Error, CustomStringConvertible {
    let description: String
}

func fail(_ message: String) throws -> Never {
    throw MigrationError(description: message)
}

func timingHistoryURL() -> URL {
    if let xdg = ProcessInfo.processInfo.environment["XDG_STATE_HOME"], !xdg.isEmpty {
        let expanded = (xdg as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
            .appendingPathComponent("transcribe", isDirectory: true)
            .appendingPathComponent("timing_history.jsonl", isDirectory: false)
    }

#if os(macOS)
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
    return base.appendingPathComponent("transcribe", isDirectory: true)
        .appendingPathComponent("timing_history.jsonl", isDirectory: false)
#else
    let home = (("~") as NSString).expandingTildeInPath
    return URL(fileURLWithPath: home, isDirectory: true)
        .appendingPathComponent(".local/state/transcribe", isDirectory: true)
        .appendingPathComponent("timing_history.jsonl", isDirectory: false)
#endif
}

func parseArgs(_ args: [String]) throws -> (path: URL, dryRun: Bool) {
    var path: URL?
    var dryRun = false
    var index = 0
    while index < args.count {
        switch args[index] {
        case "--dry-run":
            dryRun = true
            index += 1
        case "--path":
            guard index + 1 < args.count else {
                try fail("--path requires a file argument")
            }
            path = URL(fileURLWithPath: (args[index + 1] as NSString).expandingTildeInPath)
            index += 2
        case "--help", "-h":
            print("Usage: swift scripts/migrate-timing-history-v2.swift [--path <file>] [--dry-run]")
            exit(0)
        default:
            try fail("unknown argument: \(args[index])")
        }
    }
    return (path ?? timingHistoryURL(), dryRun)
}

func parseRows(from text: String) throws -> [[String: Any]] {
    var rows: [[String: Any]] = []
    for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let lineNumber = offset + 1
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { continue }
        guard let data = line.data(using: .utf8) else {
            try fail("line \(lineNumber): not valid UTF-8")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            try fail("line \(lineNumber): invalid JSON: \(error.localizedDescription)")
        }
        guard let row = object as? [String: Any] else {
            try fail("line \(lineNumber): JSON value is not an object")
        }
        rows.append(row)
    }
    return rows
}

func migrate(_ rows: [[String: Any]]) -> (rows: [[String: Any]], changedRows: Int, addedFields: Int) {
    var migratedRows: [[String: Any]] = []
    var changedRows = 0
    var addedFields = 0

    for original in rows {
        var row = original
        var changed = false
        if (row["schema_version"] as? Int) != 2 {
            row["schema_version"] = 2
            changed = true
        }
        for (field, value) in v2Fields where row[field] == nil {
            row[field] = value
            changed = true
            addedFields += 1
        }
        if changed {
            changedRows += 1
        }
        migratedRows.append(row)
    }

    return (migratedRows, changedRows, addedFields)
}

func jsonlData(from rows: [[String: Any]]) throws -> Data {
    var output = Data()
    for row in rows {
        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        output.append(data)
        output.append(0x0a)
    }
    return output
}

func timestamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter.string(from: Date())
}

do {
    let (historyURL, dryRun) = try parseArgs(Array(CommandLine.arguments.dropFirst()))
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: historyURL.path) else {
        print("No timing history found at \(historyURL.path)")
        exit(0)
    }

    let text = try String(contentsOf: historyURL, encoding: .utf8)
    let rows = try parseRows(from: text)
    let migrated = migrate(rows)

    if dryRun {
        print(
            "Would migrate \(rows.count) row(s) at \(historyURL.path): "
                + "\(migrated.changedRows) row(s) changed, \(migrated.addedFields) field(s) added."
        )
        exit(0)
    }

    let backupName = "\(historyURL.lastPathComponent).v1-backup-\(timestamp())"
    let backupURL = historyURL.deletingLastPathComponent().appendingPathComponent(backupName)
    let tmpURL = historyURL.deletingLastPathComponent()
        .appendingPathComponent(".\(historyURL.lastPathComponent).v2.tmp.\(UUID().uuidString)")
    let data = try jsonlData(from: migrated.rows)

    do {
        try data.write(to: tmpURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: tmpURL.path)
        try fileManager.copyItem(at: historyURL, to: backupURL)
        _ = try fileManager.replaceItemAt(historyURL, withItemAt: tmpURL)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: historyURL.path)
    } catch {
        try? fileManager.removeItem(at: tmpURL)
        try? fileManager.removeItem(at: backupURL)
        throw error
    }

    print(
        "Migrated \(rows.count) row(s) at \(historyURL.path): "
            + "\(migrated.changedRows) row(s) changed, \(migrated.addedFields) field(s) added."
    )
    print("Backup: \(backupURL.path)")
} catch let error as MigrationError {
    fputs("error: \(error.description)\n", stderr)
    exit(1)
} catch {
    fputs("error: \(error.localizedDescription)\n", stderr)
    exit(1)
}
