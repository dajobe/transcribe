import Foundation

/// Line-oriented input/output for the interactive review session, injectable
/// so tests can script a whole session in-process without a terminal.
struct InteractiveIO {
    var readLine: () -> String?
    var write: (String) -> Void

    /// Prompts go out without a trailing newline, so flush explicitly rather
    /// than waiting for line buffering that will not trigger.
    static let standard = InteractiveIO(
        readLine: { Swift.readLine(strippingNewline: true) },
        write: { text in
            fputs(text, Darwin.stdout)
            fflush(Darwin.stdout)
        }
    )
}

/// Control characters would let transcript or profile content redraw or
/// restyle the terminal; strip them from anything echoed back to the user.
private func safeText(_ text: String) -> String {
    text.components(separatedBy: .controlCharacters).joined(separator: " ")
}

/// One reply at the per-speaker prompt.
enum ReviewReply: Equatable {
    case acceptDefault
    case name(String)
    case listProfiles
    case profileIndex(Int)
    case moreSamples
    case dismiss
    case skip
    case quit

    /// End of input quits: with stdin exhausted every later prompt would
    /// quit anyway, and quitting applies the decisions already made.
    static func parse(_ line: String?) -> ReviewReply {
        guard let line else { return .quit }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        switch trimmed.lowercased() {
        case "": return .acceptDefault
        case "l": return .listProfiles
        case "m": return .moreSamples
        case "u": return .dismiss
        case "s": return .skip
        case "q": return .quit
        default:
            if trimmed.allSatisfy(\.isNumber), let index = Int(trimmed) {
                return .profileIndex(index)
            }
            return .name(trimmed)
        }
    }
}

/// What the user decided for one local speaker.
enum SpeakerDecision: Equatable {
    case newProfile(name: String)
    case existingProfile(id: String)
    /// This voice cannot be identified and that will not change; stop
    /// prompting for it in future sessions.
    case dismiss
}

enum SpeakerReview {
    // MARK: - Sample selection

    /// Segments shown to identify a voice from text alone. The first
    /// utterances of a speaker are often fragments ("Me? Yeah."), so instead
    /// of taking the transcript head this drops short segments and picks the
    /// wordiest segment from the beginning, middle, and end thirds of the
    /// speaker's turns. Passing the segments already shown excludes them, so
    /// asking for more samples spreads fresh ones across the recording
    /// instead of repeating the first selection; an empty result means every
    /// qualifying segment has been shown.
    static func selectSamples(
        from segments: [TranscriptSegment], speaker: String,
        count: Int = 3, minimumWords: Int = 4,
        excluding shown: [TranscriptSegment] = []
    ) -> [TranscriptSegment] {
        let turns = segments.filter { $0.speaker == speaker }
        var candidates = turns.filter { wordCount($0.text) >= minimumWords }
        if candidates.isEmpty { candidates = turns }
        candidates.removeAll { shown.contains($0) }
        guard candidates.count > count, count > 0 else { return candidates }
        let chunk = candidates.count / count
        return (0..<count).map { index in
            let start = index * chunk
            let end = index == count - 1 ? candidates.count : start + chunk
            return candidates[start..<end].max {
                wordCount($0.text) < wordCount($1.text)
            }!
        }
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    // MARK: - Interactive session

    struct Session {
        var io: InteractiveIO = .standard
        var color: TerminalColor = Terminal.stdout
        /// With --all, speakers that are already confirmed are revisited too.
        var includeConfirmed: Bool = false
        /// When on, each document's recorded exports are regenerated right
        /// after its decisions are applied: inside the file lock for a
        /// portable document, under the render lock after the commit for a
        /// managed one.
        var refreshExports: Bool = true

        /// Walks the documents in order, prompting for each speaker that
        /// needs attention. Returns after the last document or when the user
        /// quits; decisions are applied per document either way.
        func run(documents: [TranscriptRef]) throws {
            var changedAnything = false
            for ref in documents {
                let outcome = try review(document: ref)
                changedAnything = changedAnything || outcome.changed
                if outcome.quit { break }
            }
            if changedAnything && !refreshExports {
                io.write("Export again to update rendered files.\n")
            }
        }

        /// Whether any speaker in the document would be prompted, without
        /// any I/O; used to pass over settled documents silently.
        func needsAttention(_ document: CanonicalTranscript) -> Bool {
            needsAttention(TranscriptSummary(document))
        }

        /// The payload-free form planning uses, so walking every saved
        /// document never reads segment text.
        func needsAttention(_ summary: TranscriptSummary) -> Bool {
            !promptableSpeakers(
                embedded: summary.speakerEmbeddings.keys, matches: summary.speakerMatches,
                isDismissed: summary.isDismissed
            ).isEmpty
        }

        func promptableSpeakers(of document: CanonicalTranscript) -> [String] {
            promptableSpeakers(
                embedded: document.output.speakerEmbeddings.keys, matches: document.speakerMatches,
                isDismissed: document.isDismissed
            )
        }

        private func promptableSpeakers(
            embedded: Dictionary<String, [Float]>.Keys, matches: [String: SpeakerMatch],
            isDismissed: (String) -> Bool
        ) -> [String] {
            embedded.sorted().filter { speaker in
                includeConfirmed
                    || (matches[speaker]?.status != .confirmed && !isDismissed(speaker))
            }
        }

        private func review(document ref: TranscriptRef) throws -> (changed: Bool, quit: Bool) {
            let document = try SpeakerCommands.refreshedDocument(ref)
            let pending = promptableSpeakers(of: document)
            guard !pending.isEmpty else { return (false, false) }
            let profiles = try SpeakerProfileStore.profiles()

            printHeader(document)
            var decisions: [(speaker: String, decision: SpeakerDecision)] = []
            var quit = false
            for speaker in pending {
                switch prompt(for: speaker, in: document, profiles: profiles) {
                case .decided(let decision):
                    decisions.append((speaker, decision))
                case .skipped:
                    continue
                case .quit:
                    quit = true
                }
                if quit { break }
            }
            let changed = try SpeakerReview.apply(
                decisions, to: ref, io: io, color: color, refreshExports: refreshExports
            )
            // The ID is what speakers confirm/clear take to revise a
            // decision, so leave it on screen when the session moves on.
            io.write(color.dim("Transcript ID: \(document.id.uuidString.lowercased())") + "\n")
            return (changed, quit)
        }

        private enum PromptOutcome {
            case decided(SpeakerDecision)
            case skipped
            case quit
        }

        private func printHeader(_ document: CanonicalTranscript) {
            let speakers = document.output.speakerEmbeddings.keys
            let unidentified = speakers.filter { document.speakerMatches[$0] == nil }.count
            var parts = [
                durationText(document.output.durationSeconds),
                "\(speakers.count) speaker\(speakers.count == 1 ? "" : "s")",
            ]
            if unidentified > 0 { parts.append("\(unidentified) unidentified") }
            io.write("\n\(color.bold(safeText(document.basename))) — \(parts.joined(separator: ", "))\n")
        }

        private func prompt(
            for speaker: String, in document: CanonicalTranscript, profiles: [SpeakerProfile]
        ) -> PromptOutcome {
            var shown = SpeakerReview.selectSamples(from: document.output.segments, speaker: speaker)
            printSpeaker(speaker, in: document, samples: shown)
            let match = document.speakerMatches[speaker]
            let defaultName = match?.name
            while true {
                io.write(promptLine(defaultName: defaultName))
                switch ReviewReply.parse(io.readLine()) {
                case .quit:
                    return .quit
                case .skip:
                    return .skipped
                case .dismiss:
                    return .decided(.dismiss)
                case .acceptDefault:
                    guard let match else { return .skipped }
                    // Re-accepting a confirmed name changes nothing; only a
                    // suggestion or automatic guess gains a voice example.
                    if match.status == .confirmed { return .skipped }
                    return .decided(.existingProfile(id: match.profileID))
                case .moreSamples:
                    let more = SpeakerReview.selectSamples(
                        from: document.output.segments, speaker: speaker, excluding: shown
                    )
                    guard !more.isEmpty else {
                        io.write("No more samples for this speaker.\n")
                        continue
                    }
                    printSamples(more)
                    shown += more
                case .listProfiles:
                    printProfileMenu(profiles)
                case .profileIndex(let number):
                    guard number >= 1, number <= profiles.count else {
                        io.write(color.red("No profile numbered \(number).") + " Enter l to list profiles.\n")
                        continue
                    }
                    return .decided(.existingProfile(id: profiles[number - 1].id))
                case .name(let name):
                    if let existing = profiles.first(where: {
                        $0.name.caseInsensitiveCompare(name) == .orderedSame
                    }) {
                        return .decided(.existingProfile(id: existing.id))
                    }
                    return .decided(.newProfile(name: name))
                }
            }
        }

        private func printSpeaker(
            _ speaker: String, in document: CanonicalTranscript, samples: [TranscriptSegment]
        ) {
            let turns = document.output.segments.filter { $0.speaker == speaker }
            let speaking = turns.reduce(0.0) { $0 + max(0, $1.end - $1.start) }
            var line = "\n\(color.bold(safeText(speaker)))  (\(turns.count) turns, \(durationText(speaking)) speaking)"
            if let match = document.speakerMatches[speaker] {
                let distance = String(format: "%.3f", match.distance)
                let annotation = "\(match.status.rawValue): \(safeText(match.name)) (distance \(distance))"
                switch match.status {
                case .confirmed: line += "   " + color.green(annotation)
                case .automatic: line += "   " + color.cyan(annotation)
                case .suggested: line += "   " + color.yellow(annotation)
                }
            }
            if document.isDismissed(speaker) {
                line += "   " + color.dim("marked unidentifiable")
            }
            io.write(line + "\n")
            printSamples(samples)
        }

        private func printSamples(_ samples: [TranscriptSegment]) {
            for sample in samples {
                let stamp = color.dim("[\(formatTimeRange(seconds: sample.start))]")
                io.write("  \(stamp)  \(sampleText(sample.text))\n")
            }
        }

        private func promptLine(defaultName: String?) -> String {
            if let defaultName {
                return "Name [\(safeText(defaultName))], l profiles, m more, u unknown, s skip, q quit: "
            }
            return "Name, l profiles, m more, u unknown, s skip (Enter), q quit: "
        }

        private func printProfileMenu(_ profiles: [SpeakerProfile]) {
            guard !profiles.isEmpty else {
                io.write("No confirmed speaker profiles yet; type a name to create one.\n")
                return
            }
            for (index, profile) in profiles.enumerated() {
                let examples = "\(profile.examples.count) example\(profile.examples.count == 1 ? "" : "s")"
                io.write("  \(index + 1)  \(color.bold(safeText(profile.name)))  \(color.dim(examples))\n")
            }
        }

        private func sampleText(_ text: String) -> String {
            let flattened = safeText(text)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let limit = 100
            guard flattened.count > limit else { return flattened }
            return flattened.prefix(limit - 1) + "…"
        }

        private func durationText(_ seconds: Double) -> String {
            let total = Int(seconds.rounded())
            if total >= 3600 { return "\(total / 3600)h \((total % 3600) / 60)m" }
            if total >= 60 { return "\(total / 60)m" }
            return "\(total)s"
        }
    }

    // MARK: - Applying decisions


    /// Applies the collected decisions for one document. Prompting holds no
    /// locks or transactions — a session can wait on a human indefinitely —
    /// so the document is reloaded here and each decision re-checked against
    /// the fresh content before confirming. Returns whether anything changed.
    ///
    /// A managed document applies the whole batch in one write transaction
    /// covering its rows and the profile rows, and reports each decision only
    /// after the commit: a batch failing part-way rolls back every decision
    /// and must not claim any of them. A portable document stays two stores
    /// under its file lock, as before: profile changes commit one by one and
    /// are reported as they happen.
    static func apply(
        _ decisions: [(speaker: String, decision: SpeakerDecision)],
        to ref: TranscriptRef, io: InteractiveIO, color: TerminalColor,
        refreshExports: Bool = false
    ) throws -> Bool {
        guard !decisions.isEmpty else { return false }
        switch ref {
        case .portable(let url):
            return try SpeakerCommands.withDocumentLock(at: url) {
                var document = try CanonicalTranscriptStore.load(from: url)
                let changed = try applyDecisions(decisions, to: &document, color: color) {
                    io.write($0 + "\n")
                }
                if changed {
                    try CanonicalTranscriptStore.save(document, to: ref)
                    if refreshExports {
                        ExportRefresh.run(document: document, at: ref, io: io, color: color)
                    }
                }
                return changed
            }
        case .managed(let id):
            var lines: [String] = []
            let changed = try StateStore.withDatabase { database in
                try database.inTransaction(.write) {
                    var document = try CanonicalTranscriptStore.load(id: id)
                    let changed = try applyDecisions(decisions, to: &document, color: color) {
                        lines.append($0)
                    }
                    if changed { try CanonicalTranscriptStore.save(document, to: ref) }
                    return changed
                }
            }
            for line in lines { io.write(line + "\n") }
            if changed && refreshExports {
                SpeakerCommands.refreshManagedExports(id: id, io: io, color: color)
            }
            return changed
        }
    }

    /// Applies each decision to `document` and the profile store, passing
    /// one confirmation line per applied decision to `report`.
    private static func applyDecisions(
        _ decisions: [(speaker: String, decision: SpeakerDecision)],
        to document: inout CanonicalTranscript, color: TerminalColor,
        report: (String) -> Void
    ) throws -> Bool {
        let profiles = try SpeakerProfileStore.profiles()
        var changedAny = false
        for (speaker, decision) in decisions {
            guard let embedding = document.output.speakerEmbeddings[speaker] else {
                emitWarning("No embedding for local speaker '\(speaker)' in this document any more; not confirmed.")
                continue
            }
            let name: String
            var profileID: String?
            switch decision {
            case .dismiss:
                // Dismissing a previously confirmed speaker withdraws the
                // confirmation from the profile store too, as `speakers
                // clear` would; the user has decided the identification
                // was not supportable.
                if document.speakerMatches[speaker]?.status == .confirmed {
                    try SpeakerProfileStore.clearExamples(
                        transcriptID: document.evidenceID, speakerID: speaker
                    )
                }
                document.speakerMatches.removeValue(forKey: speaker)
                document.markDismissed(speaker)
                changedAny = true
                report(color.green("Marked \(safeText(speaker)) as unidentifiable; review will not prompt for it again (--all revisits)."))
                continue
            case .existingProfile(let id):
                guard let profile = profiles.first(where: { $0.id == id }) else {
                    emitWarning("Profile \(id) no longer exists; speaker '\(speaker)' not confirmed.")
                    continue
                }
                name = profile.name
                profileID = id
            case .newProfile(let newName):
                name = newName
            }
            let match = try SpeakerProfileStore.confirm(
                name: name, profileID: profileID, transcriptID: document.evidenceID,
                speakerID: speaker, embedding: embedding, modelID: document.embeddingModelID,
                sourceHashes: document.sourceHashes
            )
            document.speakerMatches[speaker] = match
            document.clearDismissed(speaker)
            changedAny = true
            report(color.green("Confirmed \(safeText(speaker)) as \(safeText(match.name)) (\(match.profileID))."))
        }
        return changedAny
    }
}
