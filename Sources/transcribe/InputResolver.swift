import ArgumentParser
import AVFoundation
import Foundation

/// The result of inspecting the positional `audioFile` argument: either a
/// single audio file or a directory of sequential audio clips already grouped
/// into one or more sessions (gap-based; the directory may yield N transcripts).
enum ResolvedInput: Equatable {
    case file(path: String)
    case directory(path: String, sessions: [AudioSession])
}

/// How directory inputs are ordered before concatenation.
enum InputSortOrder: String, CaseIterable, ExpressibleByArgument {
    /// Embedded recording timestamp (e.g. M4A creation_time atom). Falls
    /// back to file modification time, then natural-sort filename, when the
    /// embedded date is missing — which keeps a deterministic order even
    /// across mixed-format directories.
    case recorded
    /// Natural-sort by filename: handles "Note 1, Note 2, …, Note 10".
    case name
    /// File modification time, oldest first.
    case mtime
}

enum InputResolver {
    /// Resolves a user-supplied path into a single-file or directory input,
    /// sorting + grouping the directory contents into sessions.
    static func resolve(
        _ rawArg: String,
        sort: InputSortOrder = .recorded,
        sessionGapSeconds: Double = 0,
        logger: VerboseLogger? = nil
    ) async throws -> ResolvedInput {
        let expanded = (rawArg as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir) else {
            throw TranscribeError(
                message: "Input does not exist: \(rawArg)",
                exitCode: .inputFile
            )
        }

        if !isDir.boolValue {
            return .file(path: expanded)
        }

        // Standardise the directory path so later basename derivation sees an
        // absolute final component (e.g. `.` -> /Users/.../my-recordings).
        let absDirPath = URL(fileURLWithPath: expanded).standardizedFileURL.path

        let entries: [String]
        do {
            entries = try FileManager.default.contentsOfDirectory(atPath: absDirPath)
        } catch {
            throw TranscribeError(
                message: "Cannot read input directory: \(rawArg): \(error.localizedDescription)",
                exitCode: .inputFile
            )
        }

        let candidates = entries
            .filter { !$0.hasPrefix(".") }
            .filter { name in
                let ext = (name as NSString).pathExtension.lowercased()
                guard !ext.isEmpty,
                    AudioLoader.supportedExtensions.contains(ext) else { return false }
                let full = (absDirPath as NSString).appendingPathComponent(name)
                var entryIsDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: full, isDirectory: &entryIsDir) else {
                    return false
                }
                return !entryIsDir.boolValue
            }
            .map { (absDirPath as NSString).appendingPathComponent($0) }

        if candidates.isEmpty {
            throw TranscribeError(
                message:
                    "No audio files found in directory: \(rawArg). Supported formats: \(AudioLoader.supportedFormats).",
                exitCode: .inputFile
            )
        }

        // Probe per-clip metadata once, then sort and group from that data.
        let probed = await probeClips(candidates)
        let effectiveSort = recordedTrustCheck(probed, requested: sort, logger: logger)
        // If we couldn't trust the recorded dates for ordering, the same dates
        // can't be trusted for gap-based session splitting either — disable.
        let effectiveGap = (sort == .recorded && effectiveSort != .recorded) ? 0.0 : sessionGapSeconds
        if effectiveGap == 0 && sessionGapSeconds > 0 && sort == .recorded && effectiveSort != .recorded {
            logger?.log("Session splitting disabled: same untrusted recorded-date metadata.")
        }
        let sortedClips = sortClips(probed, by: effectiveSort, logger: logger)
        let sessions = SessionGrouper.groupIntoSessions(
            sortedClips,
            maxGapSeconds: effectiveGap,
            logger: logger
        )
        return .directory(path: absDirPath, sessions: sessions)
    }

    /// Returns one output basename per session. Honours `--output-prefix`:
    /// if set, replaces the directory-derived base; if unset, the directory's
    /// last path component is used (with a `Recording` fallback when the
    /// directory has no usable name). For multiple sessions a `" - Recording N"`
    /// suffix is appended (1-indexed).
    static func sessionBasenames(for resolved: ResolvedInput, prefixOverride: String?) -> [String] {
        switch resolved {
        case .file(let path):
            return [prefixOverride ?? outputBasename(audioPath: path)]
        case .directory(let path, let sessions):
            let raw = prefixOverride ?? outputBasename(directoryPath: path)
            let base = raw.isEmpty ? "" : raw
            let count = max(sessions.count, 1)
            if count <= 1 {
                return [base.isEmpty ? "Recording 1" : base]
            }
            return (1...count).map { idx in
                base.isEmpty ? "Recording \(idx)" : "\(base) - Recording \(idx)"
            }
        }
    }

    /// Convenience: list of sessions for a resolved input. Single-file inputs
    /// become a one-element session containing that file (with no metadata).
    static func sessions(for resolved: ResolvedInput) -> [AudioSession] {
        switch resolved {
        case .file(let path):
            return [AudioSession(files: [path], recordedAt: nil)]
        case .directory(_, let sessions):
            return sessions
        }
    }

    // MARK: - Internal helpers (test-visible)

    /// Determines whether recorded-at timestamps are trustworthy enough to use
    /// for ordering when the user requested `.recorded` sort. Voice Memos and
    /// similar apps reset the M4A `creation_time` atom on export to Files /
    /// iCloud, so a directory of sequentially-recorded clips ends up with
    /// timestamps clustered within a few seconds — useless for ordering.
    /// Heuristic: for sequential recordings, the next clip's recorded-at must
    /// start at least `duration_i` seconds after the current clip's recorded-at,
    /// so the spread of all recorded-at values must be at least the longest
    /// clip's duration. If it's smaller, the timestamps cannot represent real
    /// sequential recording starts. In that case demote to `.name` and emit a
    /// warning.
    /// - Returns: the sort order that should actually be used.
    static func recordedTrustCheck(
        _ clips: [AudioClip],
        requested: InputSortOrder,
        logger: VerboseLogger? = nil
    ) -> InputSortOrder {
        guard requested == .recorded else { return requested }
        let dated = clips.compactMap(\.recordedAt)
        guard dated.count >= 2 else { return requested }
        let durations = clips.compactMap(\.durationSeconds).filter { $0 > 0 }
        guard let maxDuration = durations.max() else { return requested }
        guard let earliest = dated.min(), let latest = dated.max() else { return requested }
        let spread = latest.timeIntervalSince(earliest)
        if spread < maxDuration {
            let warning =
                "Recorded timestamps span only \(formatDuration(spread)) across "
                + "\(dated.count) clip\(dated.count == 1 ? "" : "s") "
                + "but the longest clip is \(formatDuration(maxDuration)). The "
                + "container creation_time was likely reset during export and "
                + "does not reflect the original recording time. Falling back to "
                + "filename sort and disabling session splitting. Pass --input-sort "
                + "name explicitly to silence this warning."
            emitWarning(warning)
            logger?.log("Recorded-date trust check: failed; using sort=name fallback.")
            return .name
        }
        logger?.log(
            "Recorded-date trust check: spread=\(formatDuration(spread)) "
            + ">= longest-duration=\(formatDuration(maxDuration)); using sort=recorded."
        )
        return requested
    }

    // MARK: - Sorting

    private struct SortKey {
        let clip: AudioClip
        let mtime: Date?
        let name: String
    }

    /// Sorts pre-probed clips by `mode` with a stable fallback chain
    /// (recorded → mtime → natural-sort filename). Logs the per-clip keys
    /// in final order when verbose.
    private static func sortClips(
        _ clips: [AudioClip],
        by mode: InputSortOrder,
        logger: VerboseLogger? = nil
    ) -> [AudioClip] {
        var keys: [SortKey] = clips.map { clip in
            let mtime = (mode == .recorded || mode == .mtime) ? mtimeForPath(clip.path) : nil
            let name = (clip.path as NSString).lastPathComponent
            return SortKey(clip: clip, mtime: mtime, name: name)
        }

        keys.sort { lhs, rhs in
            switch mode {
            case .name:
                return lhs.name.compare(rhs.name, options: .numeric) == .orderedAscending
            case .mtime:
                if let l = lhs.mtime, let r = rhs.mtime, l != r {
                    return l < r
                }
                if (lhs.mtime == nil) != (rhs.mtime == nil) {
                    return lhs.mtime != nil
                }
                return lhs.name.compare(rhs.name, options: .numeric) == .orderedAscending
            case .recorded:
                if let l = lhs.clip.recordedAt, let r = rhs.clip.recordedAt, l != r {
                    return l < r
                }
                if (lhs.clip.recordedAt == nil) != (rhs.clip.recordedAt == nil) {
                    return lhs.clip.recordedAt != nil
                }
                if let l = lhs.mtime, let r = rhs.mtime, l != r {
                    return l < r
                }
                return lhs.name.compare(rhs.name, options: .numeric) == .orderedAscending
            }
        }

        if let logger {
            logger.log("sort=\(mode.rawValue): per-clip keys (in final order)")
            for k in keys {
                logger.log(formatSortKeyLine(k, mode: mode))
            }
        }

        return keys.map(\.clip)
    }

    /// Probes each file's recorded-at and AVAsset duration in parallel,
    /// returning `[AudioClip]` in the input order.
    private static func probeClips(_ paths: [String]) async -> [AudioClip] {
        let probed: [(Int, AudioClip)] = await withTaskGroup(of: (Int, AudioClip).self) { group in
            for (idx, path) in paths.enumerated() {
                group.addTask {
                    let recorded = await loadRecordedDate(path: path)
                    let duration = await loadDuration(path: path)
                    return (idx, AudioClip(path: path, recordedAt: recorded, durationSeconds: duration))
                }
            }
            var out: [(Int, AudioClip)] = []
            for await pair in group { out.append(pair) }
            return out
        }
        return probed.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private static func formatSortKeyLine(_ k: SortKey, mode: InputSortOrder) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let recordedStr = k.clip.recordedAt.map(formatter.string(from:)) ?? "<missing>"
        let mtimeStr = k.mtime.map(formatter.string(from:)) ?? "<missing>"
        var note = ""
        if mode == .recorded && k.clip.recordedAt == nil {
            note = " (fell back to mtime)"
        }
        return "  sort key: \(k.name) recorded=\(recordedStr) mtime=\(mtimeStr)\(note)"
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return "\(h)h \(m)m \(s)s" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    /// Reads the embedded creation timestamp from an M4A/MP4 (or other
    /// AVFoundation-supported) container. Returns nil when the file has no
    /// such metadata or AVFoundation rejects the file.
    private static func loadRecordedDate(path: String) async -> Date? {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        do {
            guard let item = try await asset.load(.creationDate) else { return nil }
            return try await item.load(.dateValue)
        } catch {
            return nil
        }
    }

    private static func loadDuration(path: String) async -> Double? {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        do {
            let cm = try await asset.load(.duration)
            let seconds = CMTimeGetSeconds(cm)
            return seconds.isFinite && seconds >= 0 ? seconds : nil
        } catch {
            return nil
        }
    }

    private static func mtimeForPath(_ path: String) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }
}
