import Darwin
import Foundation

/// Control characters would let document content redraw or restyle the
/// terminal; strip them from anything echoed back to the user.
private func safeText(_ text: String) -> String {
    text.components(separatedBy: .controlCharacters).joined(separator: " ")
}

/// Regenerates the rendered output files a canonical document has on record,
/// so speaker identifications propagate to previously exported formats
/// without a manual `export` round trip. Only files whose bytes still match
/// what transcribe last wrote are ever overwritten.
enum ExportRefresh {
    /// Whether refresh should run, from the highest-precedence source that
    /// expressed one: CLI flag, then `TRANSCRIBE_REFRESH_EXPORTS=0`, then the
    /// `speakers.refreshExports` config key, then the default of true. A
    /// config file that fails to load counts as absent here; the transcription
    /// pipeline reports malformed config on its own paths.
    static func enabled(flag: Bool?) -> Bool {
        if let flag { return flag }
        if ProcessInfo.processInfo.environment["TRANSCRIBE_REFRESH_EXPORTS"] == "0" { return false }
        if let url = try? ConfigPaths.configFileURL(),
           let config = try? UserConfigFile.loadOrEmpty(from: url),
           let value = config.speakers?.refreshExports {
            return value
        }
        return true
    }

    struct Summary: Equatable {
        var refreshedFormats: [String] = []
        var modifiedPaths: [String] = []
        var droppedPaths: [String] = []
        var recordsChanged = false

        var isQuiet: Bool { refreshedFormats.isEmpty && modifiedPaths.isEmpty && droppedPaths.isEmpty }
    }

    /// Refreshes every recorded export of `document`, which the caller has
    /// loaded under its document lock, and saves the document when records
    /// changed. Every failure degrades to a warning: a confirmation that
    /// triggered the refresh must stand whatever happens to derived files.
    @discardableResult
    static func run(
        document: CanonicalTranscript, at url: URL,
        io: InteractiveIO = .standard, color: TerminalColor = Terminal.stdout
    ) -> Summary {
        var document = document
        guard document.exports?.isEmpty == false else {
            if let hint = staleExportHint(for: document, at: url) {
                io.write(hint + "\n")
            }
            return Summary()
        }
        let summary = refresh(document: &document, documentURL: url)
        if summary.recordsChanged {
            do {
                _ = try CanonicalTranscriptStore.save(document, to: url)
            } catch {
                emitWarning("Export records not saved for \(document.basename): \(error.localizedDescription). The refreshed files themselves were written.")
            }
        }
        if let line = summaryLine(summary, basename: document.basename, color: color) {
            io.write(line + "\n")
        }
        return summary
    }

    /// The per-record decision loop. Mutates `document.exports` in place and
    /// leaves saving to the caller; write failures are warnings so the
    /// remaining records still refresh.
    static func refresh(document: inout CanonicalTranscript, documentURL: URL) -> Summary {
        var summary = Summary()
        let documentIdentity = fileIdentity(documentURL.path)
        var kept: [ExportRecord] = []
        for var record in document.exports ?? [] {
            // The guard export applies at record creation, re-checked here in
            // case a document was assembled by hand: refresh must never turn
            // the canonical transcript into one of its own renderings.
            if record.path == documentURL.path
                || (documentIdentity != nil && fileIdentity(record.path) == documentIdentity) {
                emitWarning("Export record for \(record.path) names the canonical transcript itself; not refreshed.")
                kept.append(record)
                continue
            }
            var status = stat()
            if lstat(record.path, &status) != 0 {
                if errno == ENOENT || errno == ENOTDIR {
                    // A deleted or moved export was a deliberate act; dropping
                    // the record instead of rewriting the file respects it.
                    summary.droppedPaths.append(record.path)
                    summary.recordsChanged = true
                } else {
                    // Unreadable is not deleted: keep the record so the export
                    // refreshes again once access is restored.
                    emitWarning("Export not refreshed at \(record.path): \(String(cString: strerror(errno)))")
                    kept.append(record)
                }
                continue
            }
            // Only a regular file transcribe wrote can be safely replaced; a
            // symlink or other special file at the recorded path was put
            // there by someone else, whatever its target's bytes hash to.
            guard status.st_mode & S_IFMT == S_IFREG else {
                emitWarning("Export record at \(record.path) is not a regular file; not refreshed.")
                kept.append(record)
                continue
            }
            guard let onDisk = try? Data(contentsOf: URL(fileURLWithPath: record.path)) else {
                emitWarning("Export not refreshed at \(record.path): file could not be read.")
                kept.append(record)
                continue
            }
            if sha256Hex(onDisk) != record.sha256 {
                summary.modifiedPaths.append(record.path)
                kept.append(record)
                continue
            }
            do {
                guard let data = try renderOutputData(
                    format: record.format, output: document.renderedOutput(),
                    audioPath: document.audioPath, audioFiles: document.audioFiles,
                    sourceMetadata: document.sourceMetadata, model: document.model,
                    version: document.transcribeVersion, createdAt: document.createdAt
                ) else {
                    kept.append(record)
                    continue
                }
                let digest = sha256Hex(data)
                if digest != record.sha256 {
                    try writeAtomically(content: data, to: record.path)
                    record.sha256 = digest
                    record.exportedAt = Date()
                    summary.refreshedFormats.append(record.format)
                    summary.recordsChanged = true
                }
            } catch {
                emitWarning("Export not refreshed at \(record.path): \(error.localizedDescription)")
            }
            kept.append(record)
        }
        document.exports = kept
        return summary
    }

    /// One human-facing line describing what a refresh did, or nil when there
    /// is nothing worth saying (everything already up to date).
    static func summaryLine(_ summary: Summary, basename: String, color: TerminalColor) -> String? {
        guard !summary.isQuiet else { return nil }
        var parts: [String] = []
        if !summary.refreshedFormats.isEmpty {
            let count = summary.refreshedFormats.count
            let formats = summary.refreshedFormats.joined(separator: ", ")
            parts.append(color.green("Refreshed \(count) export\(count == 1 ? "" : "s") for \(safeText(basename)) (\(formats))"))
        }
        if !summary.modifiedPaths.isEmpty {
            let count = summary.modifiedPaths.count
            let paths = summary.modifiedPaths.map(safeText).joined(separator: ", ")
            parts.append(color.yellow("\(count) skipped (locally modified: \(paths))"))
        }
        if !summary.droppedPaths.isEmpty {
            let count = summary.droppedPaths.count
            let paths = summary.droppedPaths.map(safeText).joined(separator: ", ")
            parts.append(color.dim("\(count) dropped (file missing: \(paths))"))
        }
        return parts.joined(separator: "; ") + "."
    }

    /// For a document without export records — everything saved before this
    /// feature — an actionable command rebuilt from processing history, whose
    /// records carry output paths but no content hashes. Nothing is ever
    /// overwritten automatically on this path; running the printed command
    /// once seeds records and makes the document self-refreshing.
    static func staleExportHint(for document: CanonicalTranscript, at url: URL) -> String? {
        guard let records = try? ProcessingStore.loadRecords() else {
            return "Export again to update rendered files."
        }
        let evidence = Set(document.sourceHashes)
        let match = records.reversed().first { record in
            !record.output_paths.isEmpty
                && Set(record.source_fingerprint.files.map { $0.sha256.lowercased() }) == evidence
        }
        guard let match else { return "Export again to update rendered files." }
        let formats = match.output_paths
            .map { ($0 as NSString).pathExtension.lowercased() }
            .filter { validOutputFormats.contains($0) }
        guard !formats.isEmpty else { return "Export again to update rendered files." }
        var command = "transcribe export \(shellQuoted(url.path)) --format \(Array(Set(formats)).sorted().joined(separator: ","))"
        if let dir = match.output_dir {
            command += " -o \(shellQuoted(dir))"
        }
        if let recordBasename = match.basename, recordBasename != document.basename {
            command += " --output-prefix \(shellQuoted(recordBasename))"
        }
        command += " --overwrite"
        return "Previous exports may show old speaker names. Refresh them once with: \(safeText(command))"
    }

    /// Single-quote shell quoting for the hint command, so paths with spaces
    /// or metacharacters paste back into a shell as one argument.
    private static func shellQuoted(_ value: String) -> String {
        let plain = value.allSatisfy { $0.isLetter || $0.isNumber || "+-_./:@%,=".contains($0) }
        if !value.isEmpty && plain { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
