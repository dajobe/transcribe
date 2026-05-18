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
        sessionGapSeconds: Double = -1,
        filenameTimeRecovery: Bool = true,
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
        let initialSort = recordedTrustCheck(probed, requested: sort, logger: logger)

        // When the trust check downgraded recorded-sort, OR when no clip has
        // any embedded recorded-at (Voice Memos export pattern), try
        // recovering recording times from filename prefixes.
        var clipsForOrdering = probed
        var effectiveSort = initialSort
        var recoveredFilenameTimes = false
        let trustDowngraded = (sort == .recorded && initialSort != .recorded)
        let allRecordedAtMissing = (sort == .recorded && probed.allSatisfy { $0.recordedAt == nil })
        let shouldTryRecovery = trustDowngraded || allRecordedAtMissing
        if shouldTryRecovery && filenameTimeRecovery {
            if let recovered = tryFilenameTimeRecovery(probed, logger: logger) {
                let recoveredSort = recordedTrustCheck(
                    recovered, requested: .recorded, logger: logger
                )
                if recoveredSort == .recorded {
                    clipsForOrdering = recovered
                    effectiveSort = .recorded
                    recoveredFilenameTimes = true
                    logger?.log(
                        "filename time recovery: applied; using sort=recorded with filename-derived dates"
                    )
                } else {
                    logger?.log(
                        "filename time recovery: parsed clips still fail trust check; using sort=name fallback"
                    )
                    effectiveSort = .name
                }
            } else if allRecordedAtMissing && !trustDowngraded {
                // No recorded times at all and recovery declined — fall back to
                // filename sort to give the user a deterministic order based on
                // whatever data is available.
                effectiveSort = .name
            }
        } else if shouldTryRecovery && !filenameTimeRecovery {
            logger?.log("filename time recovery: disabled (input-time-source is embedded or off)")
        }

        // If we couldn't trust the recorded dates for ordering, the same dates
        // can't be trusted for gap-based session splitting either — disable
        // via the internal negative sentinel that `SessionGrouper` understands.
        let trustDisabled = (sort == .recorded && effectiveSort != .recorded)
        let effectiveGap = trustDisabled ? -1.0 : sessionGapSeconds
        if trustDisabled && sessionGapSeconds >= 0 {
            logger?.log("Session splitting disabled: same untrusted recorded-date metadata.")
        }
        let sortedClips = sortClips(
            clipsForOrdering,
            by: effectiveSort,
            preferFilenameTiebreakForRecorded: recoveredFilenameTimes,
            logger: logger
        )
        let sessions = SessionGrouper.groupIntoSessions(
            sortedClips,
            maxGapSeconds: effectiveGap,
            logger: logger
        )
        return .directory(path: absDirPath, sessions: sessions)
    }

    /// Returns one output basename per session. Precedence:
    /// 1. `--output-prefix` (always wins; appends `" - Recording N"` for
    ///    multi-session runs).
    /// 2. When `autoSessionBasename` is true and a session contains ≥ 2 clips
    ///    with a meaningful shared filename prefix, the prefix is used as the
    ///    session basename.
    /// 3. When `autoSessionBasename` is true and a multi-session run has a
    ///    single-clip session, that clip's filename basename is used.
    /// 4. Otherwise the directory's last path component is used, suffixed
    ///    with `" - Recording N"` for multi-session runs. `Recording N` is
    ///    used as a fallback when the directory has no usable name.
    static func sessionBasenames(
        for resolved: ResolvedInput,
        prefixOverride: String?,
        autoSessionBasename: Bool = true
    ) -> [String] {
        switch resolved {
        case .file(let path):
            return [prefixOverride ?? outputBasename(audioPath: path)]
        case .directory(let path, let sessions):
            let raw = prefixOverride ?? outputBasename(directoryPath: path)
            let base = raw.isEmpty ? "" : raw
            let count = max(sessions.count, 1)

            // --output-prefix always wins; auto derivation is bypassed.
            if prefixOverride != nil {
                if count <= 1 { return [base] }
                return (1...count).map { idx in "\(base) - Recording \(idx)" }
            }

            // Single-session directory: keep the directory basename (current
            // behaviour) unless that one session has multiple clips with a
            // shared prefix worth using.
            if count <= 1 {
                if autoSessionBasename,
                   let one = sessions.first,
                   one.files.count >= 2,
                   let derived = commonPrefixBasename(forSessionFiles: one.files) {
                    return [derived]
                }
                return [base.isEmpty ? "Recording 1" : base]
            }

            // Multi-session: derive per session when possible.
            var out: [String] = []
            for (idx, session) in sessions.enumerated() {
                let i = idx + 1
                if autoSessionBasename {
                    if session.files.count >= 2,
                       let derived = commonPrefixBasename(forSessionFiles: session.files) {
                        out.append(derived)
                        continue
                    }
                    if session.files.count == 1 {
                        let single = outputBasename(audioPath: session.files[0])
                        if !single.isEmpty {
                            out.append(single)
                            continue
                        }
                    }
                }
                out.append(base.isEmpty ? "Recording \(i)" : "\(base) - Recording \(i)")
            }
            return uniquedSessionBasenames(out)
        }
    }

    /// Ensures auto-derived session basenames cannot collide within one run.
    /// This keeps a later session from overwriting, or failing after
    /// transcription because of, an earlier session with the same output name.
    private static func uniquedSessionBasenames(_ basenames: [String]) -> [String] {
        var originalCounts: [String: Int] = [:]
        for basename in basenames {
            originalCounts[basename.lowercased(), default: 0] += 1
        }
        var seen: [String: Int] = [:]
        var used: Set<String> = []
        return basenames.map { basename in
            let key = basename.lowercased()
            seen[key, default: 0] += 1
            var candidate = basename
            var suffix = seen[key]!
            var needsSuffix = suffix > 1
            var candidateKey = candidate.lowercased()
            while needsSuffix || used.contains(candidateKey) || (candidateKey != key && (originalCounts[candidateKey] ?? 0) > 0) {
                candidate = "\(basename) - Recording \(suffix)"
                candidateKey = candidate.lowercased()
                suffix += 1
                needsSuffix = false
            }
            used.insert(candidateKey)
            return candidate
        }
    }

    /// Computes the longest common prefix (filename minus extension) across
    /// the supplied paths. Strips trailing whitespace and common
    /// sequence-marker suffixes (` part `, `-`, `_`, `(`, trailing zero) and
    /// rejects results below the configured thresholds.
    /// - Returns: the derived prefix, or nil if no usable shared prefix
    ///   exists.
    static func commonPrefixBasename(forSessionFiles files: [String]) -> String? {
        guard files.count >= 2 else { return nil }
        let basenames = files.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }

        var lcp = basenames[0]
        for name in basenames.dropFirst() {
            lcp = lcp.commonPrefix(with: name)
            if lcp.isEmpty { return nil }
        }

        let trimmed = stripTrailingSequenceMarkers(lcp)
        guard !trimmed.isEmpty else { return nil }

        // Reject results that are too short or proportionally too small to
        // represent a meaningful shared name.
        let shortestLen = basenames.map(\.count).min() ?? 0
        guard trimmed.count >= 8 else { return nil }
        guard Double(trimmed.count) >= 0.3 * Double(shortestLen) else { return nil }

        return trimmed
    }

    /// Repeatedly strips trailing whitespace, common single-char markers
    /// (`-`, `_`, `(`, `0`), and the literal word `part` from the right side
    /// until none remain. Used to clean up a longest-common-prefix before
    /// returning it as a session basename.
    private static func stripTrailingSequenceMarkers(_ s: String) -> String {
        var result = s
        let trailingChars: Set<Character> = [" ", "\t", "-", "_", "(", "0"]
        var changed = true
        while changed {
            changed = false
            while let last = result.last, trailingChars.contains(last) || last.isWhitespace {
                result.removeLast()
                changed = true
            }
            // Strip a trailing literal "part" (case-insensitive, word-form).
            if result.lowercased().hasSuffix("part") {
                result.removeLast(4)
                changed = true
            }
        }
        return result
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
                + "filename sort and disabling session splitting. Pass --sort "
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

    // MARK: - Filename time-prefix recovery

    /// Parses a leading recording-time prefix from `filename` (just the basename;
    /// the extension is allowed but ignored). Recognises:
    ///
    /// - `YYYY-MM-DDTHH:MM[:SS]`
    /// - `YYYY-MM-DD HH:MM[:SS]`
    /// - `HH:MM[:SS]`
    /// - `HH-MM[-SS]` (filesystem-safe)
    /// - `HHMM` or `HHMMSS` followed by `_`
    ///
    /// Time-only forms (no explicit date) are combined with `fileMtime`'s date
    /// in the local timezone. Returns nil when the prefix is absent, the values
    /// are out of range, or the character following the prefix is alphanumeric
    /// (so e.g. `09:00abc` does not parse). The prefix must be followed by a
    /// non-alphanumeric character, end-of-string, or `_` (depending on form).
    static func parseFilenameRecordedAt(filename: String, fileMtime: Date) -> Date? {
        let s = filename.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }

        // Order matters: longest / most-specific patterns first.
        // 1. ISO-like with 'T' separator: 2026-01-15T09:48[:00]
        if let m = matchPattern(
            s,
            pattern: #"^(\d{4})-(\d{2})-(\d{2})T(\d{1,2}):(\d{2})(?::(\d{2}))?(?=[^0-9A-Za-z]|$)"#
        ) {
            return composeAbsolute(year: m[1], month: m[2], day: m[3], h: m[4], min: m[5], sec: m[6])
        }
        // 2. Date + space + time: 2026-01-15 09:48[:00]
        if let m = matchPattern(
            s,
            pattern: #"^(\d{4})-(\d{2})-(\d{2})\s+(\d{1,2}):(\d{2})(?::(\d{2}))?(?=[^0-9A-Za-z]|$)"#
        ) {
            return composeAbsolute(year: m[1], month: m[2], day: m[3], h: m[4], min: m[5], sec: m[6])
        }
        // 3. HH:MM[:SS] colon form
        if let m = matchPattern(
            s,
            pattern: #"^(\d{1,2}):(\d{2})(?::(\d{2}))?(?=[^0-9A-Za-z]|$)"#
        ) {
            return composeWithMtimeDate(h: m[1], min: m[2], sec: m[3], mtime: fileMtime)
        }
        // 4. HH-MM[-SS] dash form (HH must be ≤ 2 digits so YYYY-MM-DD doesn't match)
        if let m = matchPattern(
            s,
            pattern: #"^(\d{1,2})-(\d{2})(?:-(\d{2}))?(?=[^0-9A-Za-z]|$)"#
        ) {
            return composeWithMtimeDate(h: m[1], min: m[2], sec: m[3], mtime: fileMtime)
        }
        // 5. HHMM[SS]_ underscore form
        if let m = matchPattern(s, pattern: #"^(\d{2})(\d{2})(\d{2})?_"#) {
            return composeWithMtimeDate(h: m[1], min: m[2], sec: m[3], mtime: fileMtime)
        }
        return nil
    }

    /// Returns the captured groups (1-indexed in the original regex; index 0 is
    /// the full match). Each entry is the captured string or nil if the group
    /// did not participate in the match.
    private static func matchPattern(_ s: String, pattern: String) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let result = regex.firstMatch(in: s, range: range) else { return nil }
        var groups: [String?] = [nil]  // index 0 placeholder
        for i in 1..<result.numberOfRanges {
            let r = result.range(at: i)
            if r.location == NSNotFound {
                groups.append(nil)
            } else if let swiftRange = Range(r, in: s) {
                groups.append(String(s[swiftRange]))
            } else {
                groups.append(nil)
            }
        }
        return groups
    }

    private static func composeAbsolute(
        year: String?, month: String?, day: String?,
        h: String?, min: String?, sec: String?
    ) -> Date? {
        guard let year, let month, let day, let h, let min,
              let yearI = Int(year), let monthI = Int(month), let dayI = Int(day),
              let hI = Int(h), let minI = Int(min) else { return nil }
        let secI = sec.flatMap(Int.init) ?? 0
        guard yearI >= 1900, yearI <= 2099,
              monthI >= 1, monthI <= 12,
              dayI >= 1, dayI <= 31,
              hI >= 0, hI <= 23,
              minI >= 0, minI <= 59,
              secI >= 0, secI <= 59 else { return nil }
        var comps = DateComponents()
        comps.year = yearI
        comps.month = monthI
        comps.day = dayI
        comps.hour = hI
        comps.minute = minI
        comps.second = secI
        comps.timeZone = TimeZone.current
        return Calendar(identifier: .gregorian).date(from: comps)
    }

    private static func composeWithMtimeDate(
        h: String?, min: String?, sec: String?, mtime: Date
    ) -> Date? {
        guard let h, let min,
              let hI = Int(h), let minI = Int(min) else { return nil }
        let secI = sec.flatMap(Int.init) ?? 0
        guard hI >= 0, hI <= 23,
              minI >= 0, minI <= 59,
              secI >= 0, secI <= 59 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let dayComps = calendar.dateComponents([.year, .month, .day], from: mtime)
        var comps = DateComponents()
        comps.year = dayComps.year
        comps.month = dayComps.month
        comps.day = dayComps.day
        comps.hour = hI
        comps.minute = minI
        comps.second = secI
        comps.timeZone = TimeZone.current
        return calendar.date(from: comps)
    }

    /// Attempts to synthesize `recordedAt` from the filename time prefix of
    /// every clip. Returns the recovered clip set iff every clip parsed; nil
    /// otherwise (mixed inputs are rejected to avoid misordering).
    private static func tryFilenameTimeRecovery(
        _ clips: [AudioClip],
        logger: VerboseLogger?
    ) -> [AudioClip]? {
        var recovered: [AudioClip] = []
        var unparsed: [String] = []
        var parsedSamples: [(String, Date)] = []
        for clip in clips {
            let name = (clip.path as NSString).lastPathComponent
            let mtime = mtimeForPath(clip.path) ?? Date()
            if let date = parseFilenameRecordedAt(filename: name, fileMtime: mtime) {
                recovered.append(AudioClip(
                    path: clip.path,
                    recordedAt: date,
                    durationSeconds: clip.durationSeconds
                ))
                parsedSamples.append((name, date))
            } else {
                unparsed.append(name)
            }
        }
        if let logger {
            if unparsed.isEmpty {
                logger.log(
                    "filename time recovery: parsed \(recovered.count)/\(clips.count) clips"
                )
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                for (name, date) in parsedSamples {
                    logger.log("  parsed: \(name) -> \(formatter.string(from: date))")
                }
            } else {
                logger.log(
                    "filename time recovery: \(recovered.count)/\(clips.count) clips parsed; recovery declines (mixed)"
                )
                for name in unparsed {
                    logger.log("  unparsed: \(name)")
                }
            }
        }
        return unparsed.isEmpty ? recovered : nil
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
        preferFilenameTiebreakForRecorded: Bool = false,
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
                if preferFilenameTiebreakForRecorded {
                    let byName = lhs.name.compare(rhs.name, options: .numeric)
                    if byName != .orderedSame {
                        return byName == .orderedAscending
                    }
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
