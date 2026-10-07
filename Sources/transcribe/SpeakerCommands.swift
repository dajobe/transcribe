import ArgumentParser
import Darwin
import Foundation

struct TranscriptExportArguments: ParsableArguments {
    @Argument(help: "Saved document ID (from transcribe transcripts) or path; omit with --refresh to walk every saved transcript.")
    var transcript: String?
    @Option(name: [.short, .long], help: "Comma-separated formats, or all.")
    var format: String?
    @Option(name: [.customShort("o"), .long], help: "Destination directory.")
    var outputDir: String?
    @Option(name: .long, help: "Override the saved output basename.")
    var outputPrefix: String?
    @Flag(name: .long, help: "Replace existing exports.")
    var overwrite: Bool = false
    @Flag(name: .long, help: "Rewrite the document's recorded exports with current speaker names; files edited or deleted since transcribe wrote them are left alone.")
    var refresh: Bool = false
}

struct TranscriptExportDocumentArguments: ParsableArguments {
    @Argument(help: "Saved document ID (from transcribe transcripts); any unique prefix works.")
    var transcript: String
    @Argument(help: "Destination .transcript.json file.")
    var path: String
    @Flag(name: .long, help: "Replace an existing file.")
    var overwrite: Bool = false
}

struct TranscriptImportArguments: ParsableArguments {
    @Argument(help: "Portable .transcript.json file to store as a saved document.")
    var path: String
}

struct TranscriptExportLegacyArguments: ParsableArguments {
    @Argument(help: "New or empty directory to write the 2.x state files into.")
    var directory: String
}

struct SpeakerReviewArguments: ParsableArguments {
    @Argument(help: "Saved document ID (from transcribe transcripts) or path; omit to review all saved transcripts.")
    var transcript: String?
    @Flag(help: "Save refreshed suggestions and strong automatic matches to this document without prompting.")
    var apply: Bool = false
    @Flag(help: "Also revisit speakers that are already confirmed.")
    var all: Bool = false
    @Flag(inversion: .prefixedNo, help: "Force or disable the interactive session (default: interactive on a terminal).")
    var interactive: Bool?
    @Flag(inversion: .prefixedNo, help: "Regenerate this document's recorded exports after saving changed speakers (default: on).")
    var refreshExports: Bool?
}

struct SpeakerConfirmArguments: ParsableArguments {
    @Argument(help: "Saved document ID (from transcribe transcripts) or path; quote paths containing spaces.") var transcript: String
    @Argument(help: "Local speaker ID listed by inspect or speakers review, for example SPEAKER_0 or 0.") var speaker: String
    @Option(help: "Name for a new profile; quote names containing spaces.") var name: String?
    @Option(help: "Existing profile ID printed by speakers list or review.") var profile: String?
    @Flag(inversion: .prefixedNo, help: "Regenerate this document's recorded exports after confirming (default: on).")
    var refreshExports: Bool?
}

struct SpeakerClearArguments: ParsableArguments {
    @Argument(help: "Saved document ID (from transcribe transcripts) or path; quote paths containing spaces.") var transcript: String
    @Argument(help: "Local speaker ID listed by inspect or speakers review, for example SPEAKER_0 or 0.") var speaker: String
    @Flag(inversion: .prefixedNo, help: "Regenerate this document's recorded exports after clearing (default: on).")
    var refreshExports: Bool?
}

enum SpeakerCommands {
    private static let color = Terminal.stdout

    static func transcriptsHelpText() -> String {
        """
        USAGE: transcribe transcripts
               transcribe transcripts migration-status
               transcribe transcripts export-document <id> <path> [--overwrite]
               transcribe transcripts import <path>
               transcribe transcripts export-legacy <directory>

        Lists saved canonical transcripts: title and ID. Pass the ID (any unique
        prefix works) to inspect, speakers review/confirm/clear, or export;
        those commands also accept a path to a portable .transcript.json file.

        migration-status shows what the move from 2.x JSON state files into the
        state database imported, archived, skipped, or left in place.

        export-document writes a saved document to <path> as a portable
        .transcript.json file. --overwrite replaces an existing file.

        import stores a portable .transcript.json file as a saved document and
        prints its ID. A saved document for the same recording is replaced and
        keeps its ID, confirmed speakers, unidentifiable marks, and recorded
        exports. This is also how to retry a file migration skipped.

        export-legacy writes the complete state as 2.x files into a new or
        empty directory: transcripts/<id>.transcript.json,
        speaker_profiles.json, processing_history.jsonl, and
        timing_history.jsonl (empty when there is no history). It fails,
        writing nothing, if any state has no 2.x form. Use it to go back to a
        2.x release: stop every transcribe process, replace the state
        directory's files with the export, and delete state.db*.
        """
    }

    static func transcripts(_ args: [String]) throws {
        if args == ["--help"] || args == ["-h"] {
            print(transcriptsHelpText())
            return
        }
        if let subcommand = args.first, ["migration-status", "export-document", "import", "export-legacy"].contains(subcommand) {
            let rest = Array(args.dropFirst())
            if rest == ["--help"] || rest == ["-h"] {
                print(transcriptsHelpText())
                return
            }
            switch subcommand {
            case "migration-status": try migrationStatus(rest)
            case "export-document": try exportDocument(parse(TranscriptExportDocumentArguments.self, rest), arguments: rest)
            case "import": try importDocument(parse(TranscriptImportArguments.self, rest), arguments: rest)
            default: try exportLegacy(parse(TranscriptExportLegacyArguments.self, rest))
            }
            return
        }
        try require(args.isEmpty, "Usage: transcribe transcripts [migration-status | export-document | import | export-legacy]. Run transcribe transcripts --help.")
        let listing = try CanonicalTranscriptStore.listing(order: .id)
        if listing.isEmpty { print("No saved canonical transcripts.") }
        for entry in listing {
            let id = entry.id?.uuidString.lowercased() ?? safeText(entry.rawID)
            // A row this command cannot use is reported in place so the rest
            // of the listing still reaches the user.
            guard entry.id != nil else {
                let reason = errorText(CanonicalTranscriptStore.StoreError.invalidData("stored document ID is not a UUID"))
                print("\(Terminal.stdout.red("(unreadable)"))\t\(id)\t\(safeText(reason))")
                continue
            }
            guard !entry.basename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                let reason = errorText(CanonicalTranscriptStore.StoreError.invalidData("basename is empty"))
                print("\(Terminal.stdout.red("(unreadable)"))\t\(id)\t\(safeText(reason))")
                continue
            }
            // The ID is the argument speaker commands accept, so it gets its
            // own copyable column.
            print("\(Terminal.stdout.bold(safeText(entry.basename)))\t\(id)")
        }
    }

    /// Prints the migration manifest (`migration_sources`) grouped by
    /// outcome, so a user can see what moved, why a file was left in place,
    /// and which files an older binary recreated afterwards.
    static func migrationStatus(_ args: [String]) throws {
        try require(args.isEmpty, "Usage: transcribe transcripts migration-status")
        let (importMarker, archiveMarker, rows, databasePath) = try StateStore.withDatabase { database in
            try database.inTransaction(.read) {
                (
                    try database.metaValue("import_complete"),
                    try database.metaValue("archive_complete"),
                    try StateMigration.manifestRows(in: database),
                    database.databaseURL.path
                )
            }
        }
        let archive = try StateMigration.archiveDirectoryURL().path
        if importMarker == "migrated" {
            print("Migrated 2.x state files into \(safeText(databasePath)).")
            if archiveMarker == "migrated" {
                print("Originals moved to \(safeText(archive))/; plain-text manifest: \(safeText(archive))/\(StateMigration.manifestFileName)")
            } else {
                print("Moving the originals to \(safeText(archive))/ is unfinished; transcribe resumes it on its next run.")
            }
        } else if rows.isEmpty {
            print("Nothing was migrated: the state database \(safeText(databasePath)) was created fresh, with no 2.x state files to import.")
            return
        } else {
            print("The state database \(safeText(databasePath)) was created fresh; nothing was migrated at creation.")
        }

        func line(_ row: MigrationSourceRow, showStatus: Bool = false) -> String {
            var text = "  " + safeText(row.filePath)
            if showStatus { text += " [\(safeText(row.status))]" }
            if let archived = row.archivedPath, !archived.isEmpty { text += " -> " + safeText(archived) }
            if let detail = row.detail, !detail.isEmpty {
                text += row.status == "imported" ? " (\(safeText(detail)))" : ": " + safeText(detail)
            }
            return text
        }
        let reappeared = rows.filter(\.isReappeared)
        let original = rows.filter { !$0.isReappeared }
        let sections: [(String, [MigrationSourceRow])] = [
            ("Imported", original.filter { $0.status == "imported" }),
            ("Skipped", original.filter { $0.status == "skipped" }),
            ("Conflicts", original.filter { $0.status == "conflict" }),
            ("Imported later with transcripts import", original.filter { $0.status == StateMigration.importedLaterStatus }),
        ]
        for (title, members) in sections where !members.isEmpty {
            print("\n\(title) (\(members.count)):")
            members.forEach { print(line($0)) }
        }
        if !reappeared.isEmpty {
            print("\nReappeared after migration (\(reappeared.count)):")
            reappeared.forEach { print(line($0, showStatus: true)) }
        }
        if rows.contains(where: { $0.status == "skipped" || $0.status == "conflict" }) {
            print("\nFiles not imported were left where they are. After repairing one, import it with transcribe transcripts import <path>.")
        }
    }

    /// `transcripts export-document`: the portable JSON of a saved document,
    /// byte for byte what an explicit-destination save writes.
    private static func exportDocument(_ options: TranscriptExportDocumentArguments, arguments: [String]) throws {
        let ref = try transcriptRef(options.transcript, arguments: arguments)
        guard case .managed(let id) = ref else {
            throw usage("export-document takes a saved document ID; \(safeText(ref.displayName)) is already a portable file.")
        }
        let document = try loadTranscript(ref, arguments: arguments)
        // Write through a symlink to its target rather than replacing the link.
        let destination = URL(fileURLWithPath: (options.path as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else {
                throw usage("\(safeText(destination.path)) is a directory; give the path of the .transcript.json file to write.")
            }
            guard options.overwrite else {
                throw TranscribeError(
                    message: "Output file already exists: \(safeText(destination.path)). Use --overwrite to replace.",
                    exitCode: .outputWrite
                )
            }
        }
        do {
            let data = try CanonicalTranscriptStore.portableData(document)
            let parent = destination.deletingLastPathComponent()
            // An existing directory keeps the permissions the user chose for it.
            if !FileManager.default.fileExists(atPath: parent.path) {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            let parentFD = open(parent.path, O_RDONLY | O_DIRECTORY)
            guard parentFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(parentFD) }
            // Without --overwrite the publish never replaces a file that
            // appeared after the check above.
            try publishPrivateFile(
                data: data, named: destination.lastPathComponent, inDirectory: parentFD,
                displayPath: destination.path, replace: options.overwrite
            )
        } catch is DestinationExistsError {
            throw TranscribeError(
                message: "Output file already exists: \(safeText(destination.path)). Use --overwrite to replace.",
                exitCode: .outputWrite
            )
        } catch {
            throw TranscribeError(
                message: "Cannot write \(safeText(destination.path)): \(safeText(errorText(error)))",
                exitCode: .outputWrite
            )
        }
        print(color.green("Exported \(id.uuidString.lowercased()) to \(safeText(destination.path))."))
    }

    /// Test seam: runs after import has read its file and before it opens
    /// the write transaction.
    static var afterImportRead: (() throws -> Void)?

    /// `transcripts import`: stores a portable file with managed-save
    /// semantics (see `CanonicalTranscriptStore.importPortable`), and marks a
    /// file migration had skipped or set aside as imported later.
    private static func importDocument(_ options: TranscriptImportArguments, arguments: [String]) throws {
        let url = URL(fileURLWithPath: (options.path as NSString).expandingTildeInPath).resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw TranscribeError(
                message: withSplitPathHint("No transcript file at \(safeText(url.path)).", arguments),
                exitCode: .inputFile
            )
        }
        // No document lock: import only reads the file, and portable saves
        // replace it atomically, so the read sees one whole version. The
        // identity comes from the descriptor that read it, so a file swapped
        // in afterwards is never the one marked imported in the manifest.
        let document: CanonicalTranscript
        let identity: FileID
        do {
            let fd = open(url.path, O_RDONLY)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            identity = FileID(info)
            let data = try handle.readToEnd() ?? Data()
            try handle.close()
            document = try CanonicalTranscriptStore.load(data: data)
        } catch {
            throw unreadable(.portable(url), error, arguments: arguments)
        }
        try afterImportRead?()
        let (outcome, manifestRows) = try inWriteTransaction { () -> (CanonicalTranscriptStore.ImportOutcome, Int) in
            let outcome = try CanonicalTranscriptStore.importPortable(document)
            let rows = try StateStore.withDatabase {
                try StateMigration.recordLaterImport(ofFileWithIdentity: identity, as: outcome.id, in: $0)
            }
            return (outcome, rows)
        }
        if manifestRows > 0 {
            // Best effort, as on every open: the dirty flag committed with
            // the rows, so a failed rewrite is retried next time.
            try? StateStore.withDatabase { try StateMigration.writeManifest($0) }
        }
        let id = outcome.id.uuidString.lowercased()
        if outcome.replacedExisting {
            print(color.green("Imported \(safeText(url.path)) as \(id), replacing the saved transcript of the same recording; its confirmed speakers, unidentifiable marks, and recorded exports carry forward."))
        } else if let previous = outcome.reassignedFrom {
            print(color.green("Imported \(safeText(url.path)) as \(id).") + " Its own ID \(previous.uuidString.lowercased()) belongs to a different saved recording, so it was given a new one.")
        } else {
            print(color.green("Imported \(safeText(url.path)) as \(id)."))
        }
        if manifestRows > 0 {
            print("Recorded in the migration manifest; transcribe transcripts migration-status lists it as imported later.")
        }
    }

    /// `transcripts export-legacy`: see `LegacyExport`.
    private static func exportLegacy(_ options: TranscriptExportLegacyArguments) throws {
        let directory = URL(fileURLWithPath: (options.directory as NSString).expandingTildeInPath, isDirectory: true)
        // Fail on a non-empty destination before reading any state.
        try LegacyExport.checkDestination(directory)
        let snapshot = try LegacyExport.snapshot()
        try LegacyExport.write(snapshot, to: directory)
        func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
        print(color.green(
            "Exported \(count(snapshot.documents.count, "transcript")), \(count(snapshot.profileCount, "speaker profile")), \(count(snapshot.processingLines.count, "processing history row")), and \(count(snapshot.timingLines.count, "timing history row")) as 2.x files to \(safeText(directory.path))."
        ))
    }

    static func helpText() -> String {
        """
        USAGE: transcribe speakers <subcommand>

          list
          review [transcript] [--all] [--apply] [--[no-]interactive]
          confirm <transcript> <SPEAKER_n> --name <name>
          confirm <transcript> <SPEAKER_n> --profile <profile-id>
          clear <transcript> <SPEAKER_n>
          rename <profile-id> <name>
          delete <profile-id>

        <transcript> is a saved document's ID — the UUID printed by
        transcripts, inspect, and review; any unique prefix of at least four
        characters works — or a path to a portable .transcript.json file,
        which is edited in place. <SPEAKER_n> is a local speaker ID in that
        transcript (SPEAKER_0, or just 0); inspect and review list them, and
        an unknown ID prints the valid ones. Quote paths containing spaces.

        review, confirm, and clear take --[no-]refresh-exports (default on).

        On a terminal, review is an interactive session showing speech samples
        for each speaker needing attention and prompting for a name; without a
        transcript it walks every saved document. --all also revisits confirmed
        speakers. Piped output keeps the read-only table, and --apply saves
        refreshed suggestions and strong automatic matches without prompting.
        Only explicit confirmation adds a voice example to a profile.
        In the session, m prints more speech samples when the first ones are
        not enough, and u marks the speaker unidentifiable: review stops
        prompting for it and automatic matching leaves it alone. --all
        revisits it, and confirming a name or clear removes the mark.
        Automatic names require two independent confirmed recordings and a clear
        matching margin. Distances are heuristics, not identity probabilities.
        Clear removes this document's assignment, confirmed example, and
        unidentifiable mark. Delete
        removes a profile and its examples; saved transcript name snapshots remain.
        After a change, exports the document has on record are regenerated so
        rendered files pick up the new names; files edited or deleted since
        transcribe wrote them are left alone. Disable with --no-refresh-exports,
        TRANSCRIBE_REFRESH_EXPORTS=0, or:
        transcribe config set speakers.refreshExports false
        """
    }

    static func exportHelpText() -> String {
        """
        USAGE: transcribe export <transcript> [--format txt,json,srt,vtt,md,tsv,all]
                                 [-o <directory>] [--output-prefix <name>] [--overwrite]
               transcribe export [transcript] --refresh

        <transcript> is a saved document's ID (from transcribe transcripts;
        any unique prefix works) or a path to a portable .transcript.json file.

        Renders a saved canonical transcript without audio, models, or downloads.
        Saved confirmed and automatic names are used; suggestions remain local IDs.
        Existing JSON exports retain their prior schema and contain no embeddings.
        --refresh rewrites the files the document has on record with current
        speaker names instead of taking a format list; files edited or deleted
        since transcribe wrote them are left alone. Without a transcript it
        walks every saved document.
        """
    }

    static func run(_ argv: [String]) throws {
        guard let command = argv.first, command != "--help", command != "-h" else {
            print(helpText())
            return
        }
        let args = Array(argv.dropFirst())
        if args == ["--help"] || args == ["-h"] {
            print(helpText())
            return
        }
        switch command {
        case "list":
            try require(args.isEmpty, "Usage: transcribe speakers list")
            let profiles = try SpeakerProfileStore.profiles()
            if profiles.isEmpty { print("No confirmed speaker profiles.") }
            for profile in profiles {
                print("\(color.dim(profile.id))\t\(color.bold(safeText(profile.name)))\texamples=\(profile.examples.count)")
            }
        case "review":
            try review(parse(SpeakerReviewArguments.self, args), arguments: args)
        case "confirm":
            try confirm(parse(SpeakerConfirmArguments.self, args), arguments: args)
        case "clear":
            try clear(parse(SpeakerClearArguments.self, args), arguments: args)
        case "rename":
            try require(args.count == 2, "Usage: transcribe speakers rename <profile-id> <name>")
            try SpeakerProfileStore.rename(profileID: args[0], name: args[1])
            print("Renamed profile. Use review --apply and export to refresh saved names.")
        case "delete":
            try require(args.count == 1, "Usage: transcribe speakers delete <profile-id>")
            try SpeakerProfileStore.delete(profileID: args[0])
            print("Deleted profile and its confirmed examples. Saved transcript snapshots are unchanged.")
        default:
            throw usage("Unknown speakers command '\(command)'. Run transcribe speakers --help.")
        }
    }

    // MARK: - Confirm and clear

    private static func confirm(_ options: SpeakerConfirmArguments, arguments args: [String]) throws {
        try require((options.name != nil) != (options.profile != nil), "Use exactly one of --name or --profile.")
        let speaker = localSpeakerID(options.speaker)
        let ref = try transcriptRef(options.transcript, arguments: args)
        let refresh = ExportRefresh.enabled(flag: options.refreshExports)
        func report(_ match: SpeakerMatch) {
            let line = color.green("Confirmed \(speaker) as \(safeText(match.name)) (\(match.profileID)).")
            print(refresh ? line : line + " Export again to update rendered files.")
        }
        switch ref {
        case .portable(let url):
            // A portable file and the profile rows are two stores with no
            // joint transaction, so a failed file save leaves the profile
            // example committed; the message says how to finish.
            try withDocumentLock(at: url) {
                var document = try loadTranscript(ref, arguments: args)
                let match = try confirmSpeaker(speaker, in: &document, options: options)
                do {
                    try CanonicalTranscriptStore.save(document, to: ref)
                } catch {
                    throw TranscribeError(
                        message: "Profile was confirmed, but the transcript could not be saved: \(error). Retry confirmation with --profile \(match.profileID); it will not duplicate the example.",
                        exitCode: .outputWrite
                    )
                }
                report(match)
                if refresh { ExportRefresh.run(document: document, at: ref, color: color) }
            }
        case .managed(let id):
            // Profile and document rows commit together or not at all. A
            // save failure still deserves the output-write exit code, not a
            // generic failure; there is no partial state to recover from.
            let match: SpeakerMatch
            do {
                match = try inWriteTransaction {
                    var document = try loadTranscript(ref, arguments: args)
                    let match = try confirmSpeaker(speaker, in: &document, options: options)
                    try CanonicalTranscriptStore.save(document, to: ref)
                    return match
                }
            } catch let error as StateDatabaseError {
                throw TranscribeError(
                    message: "Speaker was not confirmed; nothing was saved: \(error.localizedDescription)",
                    exitCode: .outputWrite
                )
            } catch let error as CanonicalTranscriptStore.StoreError {
                throw TranscribeError(
                    message: "Speaker was not confirmed; nothing was saved: \(error.localizedDescription)",
                    exitCode: .outputWrite
                )
            }
            report(match)
            if refresh { refreshManagedExports(id: id, color: color) }
        }
    }

    private static func confirmSpeaker(
        _ speaker: String, in document: inout CanonicalTranscript, options: SpeakerConfirmArguments
    ) throws -> SpeakerMatch {
        guard let embedding = document.output.speakerEmbeddings[speaker] else {
            throw unknownSpeaker(speaker, in: document)
        }
        let name: String
        if let profileID = options.profile {
            guard let profile = try SpeakerProfileStore.profiles().first(where: { $0.id == profileID }) else {
                throw usage("Unknown profile '\(profileID)'. Run transcribe speakers list.")
            }
            name = profile.name
        } else {
            name = options.name!
        }
        let match = try SpeakerProfileStore.confirm(
            name: name, profileID: options.profile, transcriptID: document.evidenceID,
            speakerID: speaker, embedding: embedding, modelID: document.embeddingModelID,
            sourceHashes: document.sourceHashes
        )
        document.speakerMatches[speaker] = match
        document.clearDismissed(speaker)
        return match
    }

    private static func clear(_ options: SpeakerClearArguments, arguments args: [String]) throws {
        let speaker = localSpeakerID(options.speaker)
        let ref = try transcriptRef(options.transcript, arguments: args)
        let refresh = ExportRefresh.enabled(flag: options.refreshExports)
        func clearSpeaker() throws -> CanonicalTranscript {
            var document = try loadTranscript(ref, arguments: args)
            guard document.output.speakerEmbeddings[speaker] != nil else {
                throw unknownSpeaker(speaker, in: document)
            }
            // Remove any confirmed example, including one left behind by a
            // portable confirmation whose document save failed.
            try SpeakerProfileStore.clearExamples(transcriptID: document.evidenceID, speakerID: speaker)
            document.speakerMatches.removeValue(forKey: speaker)
            document.clearDismissed(speaker)
            try CanonicalTranscriptStore.save(document, to: ref)
            return document
        }
        let cleared = color.green("Cleared \(speaker).") + " Future explicit review can suggest matches again."
        switch ref {
        case .portable(let url):
            try withDocumentLock(at: url) {
                let document = try clearSpeaker()
                print(cleared)
                if refresh { ExportRefresh.run(document: document, at: ref, color: color) }
            }
        case .managed(let id):
            _ = try inWriteTransaction { try clearSpeaker() }
            print(cleared)
            if refresh { refreshManagedExports(id: id, color: color) }
        }
    }

    // MARK: - Export

    static func export(_ args: [String]) throws {
        if args == ["--help"] || args == ["-h"] {
            print(exportHelpText())
            return
        }
        let options = try parse(TranscriptExportArguments.self, args)
        if options.refresh {
            try require(
                options.format == nil && options.outputDir == nil
                    && options.outputPrefix == nil && !options.overwrite,
                "--refresh regenerates the document's recorded exports; it does not take --format, -o, --output-prefix, or --overwrite."
            )
            try refreshRecordedExports(transcript: options.transcript, arguments: args)
            return
        }
        guard let transcript = options.transcript else {
            throw usage("Missing transcript path. Run transcribe transcripts to list saved documents.")
        }
        if let prefix = options.outputPrefix {
            try require(
                !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Output filename prefix cannot be empty."
            )
        }
        let outputDir = options.outputDir ?? "."
        let ref = try transcriptRef(transcript, arguments: args)
        // Load, render, write, and record under one lock, so a concurrent
        // speaker change cannot slip between the render and the record merge
        // and leave a record whose hash describes files rendered from an
        // older document.
        try withRenderingLock(for: ref) {
            let document = try loadTranscript(ref, arguments: args)
            let formats = parseOutputFormats(options.format ?? "txt,json")
            try require(!formats.isEmpty && formats.allSatisfy(validOutputFormats.contains), "Unsupported or empty output format list.")
            let basename = options.outputPrefix ?? document.basename
            let destinations = outputPaths(
                outputDir: outputDir, basename: basename,
                formats: formats, writeTxtFile: formats.contains("txt")
            )
            if case .portable(let url) = ref {
                let inputPath = url.standardizedFileURL.resolvingSymlinksInPath().path
                let inputIdentity = fileIdentity(inputPath)
                // String equality alone misses a destination that names the
                // input by another spelling: a case-flipped prefix on a
                // case-insensitive volume, or a symlink. Compare on-disk
                // identity whenever the destination already exists, since
                // only an existing file can be replaced by the export.
                for destination in destinations {
                    let sameFile = destination == inputPath
                        || (inputIdentity != nil && fileIdentity(destination) == inputIdentity)
                    try require(!sameFile, "An export cannot replace its canonical transcript. Choose another output prefix or directory.")
                }
            }
            let records = try writeOutputs(
                output: document.renderedOutput(), audioPath: document.audioPath,
                audioFiles: document.audioFiles, sourceMetadata: document.sourceMetadata,
                outputDir: outputDir, basename: basename,
                formats: formats, overwrite: options.overwrite,
                model: document.model, version: document.transcribeVersion,
                createdAt: document.createdAt
            )
            print(color.green("Exported \(formats.joined(separator: ",")) to \(resolvedOutputDir(outputDir))."))
            do {
                try CanonicalTranscriptStore.mergeExports(records, into: ref)
            } catch {
                emitWarning("Export records not saved to \(ref.displayName): \(error.localizedDescription). Speaker changes will not auto-refresh these files until a later export records them.")
            }
        }
    }

    /// Remembers what a pipeline run just wrote, so later speaker changes can
    /// regenerate the same files. The merge reads the stored records under
    /// the document's lock — the render ran unlocked. Failure is a warning:
    /// the files the user asked for were written.
    static func updateExportRecords(for ref: TranscriptRef, adding records: [ExportRecord]) {
        guard !records.isEmpty else { return }
        do {
            try withRenderingLock(for: ref) {
                try CanonicalTranscriptStore.mergeExports(records, into: ref)
            }
        } catch {
            emitWarning("Export records not saved to \(ref.displayName): \(error.localizedDescription). Speaker changes will not auto-refresh these files until a later export records them.")
        }
    }

    /// `export --refresh`: reruns the refresh routine outside any speaker
    /// change, for one document or across every saved transcript. Documents
    /// whose recorded exports are all current print nothing.
    private static func refreshRecordedExports(transcript: String?, arguments: [String]) throws {
        if let transcript {
            let ref = try transcriptRef(transcript, arguments: arguments)
            try withRenderingLock(for: ref) {
                let document = try loadTranscript(ref, arguments: arguments)
                ExportRefresh.run(document: document, at: ref, color: color)
            }
            return
        }
        let listing = try CanonicalTranscriptStore.listing(order: .recentlyUpdated)
        guard !listing.isEmpty else {
            print("No saved canonical transcripts.")
            return
        }
        for entry in listing {
            guard let id = entry.id else {
                print("\(color.red("(unreadable)"))\t\(safeText(entry.rawID))\t\(safeText(errorText(CanonicalTranscriptStore.StoreError.invalidData("stored document ID is not a UUID"))))")
                continue
            }
            let ref = TranscriptRef.managed(id: id)
            do {
                try withRenderingLock(for: ref) {
                    let document = try CanonicalTranscriptStore.load(ref)
                    ExportRefresh.run(document: document, at: ref, color: color)
                }
            } catch {
                print("\(color.red("(unreadable)"))\t\(ref.displayName)\t\(safeText(errorText(error)))")
            }
        }
    }

    /// Regenerates a managed document's recorded exports after a committed
    /// speaker change, under its render lock and from a fresh load, so the
    /// rendered names are the committed ones even if another change landed
    /// meanwhile. Like the refresh itself, failure is only a warning.
    static func refreshManagedExports(
        id: UUID, io: InteractiveIO = .standard, color: TerminalColor = Terminal.stdout
    ) {
        let ref = TranscriptRef.managed(id: id)
        do {
            try withRenderingLock(for: ref) {
                let document = try CanonicalTranscriptStore.load(ref)
                ExportRefresh.run(document: document, at: ref, io: io, color: color)
            }
        } catch {
            emitWarning("Exports not refreshed for \(ref.displayName): \(error.localizedDescription)")
        }
    }

    // MARK: - Inspect and review

    static func inspect(_ args: [String]) throws {
        if args == ["--help"] || args == ["-h"] {
            print("USAGE: transcribe inspect <transcript>\nShows metadata and saved assignments without printing voice embeddings. <transcript> is a saved document ID (from transcribe transcripts) or a path to a portable .transcript.json file.")
            return
        }
        try require(args.count == 1, withSplitPathHint("Usage: transcribe inspect <transcript>", args))
        let summary = try loadSummary(transcriptRef(args[0], arguments: args), arguments: args)
        print("Transcript: \(summary.id)\nModel: \(safeText(summary.model))\nDuration: \(summary.durationSeconds)s\nSegments: \(summary.segmentCount)")
        printReview(summary)
    }

    /// Routes `speakers review`. On a terminal this is an interactive
    /// identification session; scripts keep the 2.6.0 read-only table
    /// (piped streams) and `--apply` semantics. Without a transcript
    /// argument the review spans every saved canonical document.
    private static func review(_ options: SpeakerReviewArguments, arguments: [String]) throws {
        try require(!(options.apply && options.interactive == true), "Use --apply or --interactive, not both.")
        if options.apply {
            guard let transcript = options.transcript else {
                throw usage("--apply needs a transcript path; run transcribe transcripts to list them.")
            }
            try applyRefreshedMatches(
                transcriptRef(transcript, arguments: arguments), options: options, arguments: arguments
            )
            return
        }
        let interactive = options.interactive ?? Terminal.isInteractive
        let session = SpeakerReview.Session(
            includeConfirmed: options.all,
            refreshExports: ExportRefresh.enabled(flag: options.refreshExports)
        )
        if let transcript = options.transcript {
            let ref = try transcriptRef(transcript, arguments: arguments)
            let summary = try refreshed(loadSummary(ref, arguments: arguments))
            guard interactive else {
                printReview(summary)
                print(color.dim("Transcript ID: \(summary.id.uuidString.lowercased())"))
                return
            }
            guard session.needsAttention(summary) else {
                print(idleMessage(for: summary, all: options.all))
                return
            }
            try session.run(documents: [ref])
            return
        }
        let listing = try CanonicalTranscriptStore.listing(order: .recentlyUpdated)
        guard !listing.isEmpty else {
            print("No saved canonical transcripts.")
            return
        }
        guard interactive else {
            for entry in listing {
                let id = entry.id?.uuidString.lowercased() ?? safeText(entry.rawID)
                do {
                    guard let uuid = entry.id else {
                        throw CanonicalTranscriptStore.StoreError.invalidData("stored document ID is not a UUID")
                    }
                    let summary = try refreshed(CanonicalTranscriptStore.summary(id: uuid))
                    print("\(color.bold(safeText(summary.basename)))\t\(id)")
                    printReview(summary)
                } catch {
                    print("\(color.red("(unreadable)"))\t\(id)\t\(safeText(errorText(error)))")
                }
            }
            return
        }
        var reviewable: [TranscriptRef] = []
        for entry in listing {
            let id = entry.id?.uuidString.lowercased() ?? safeText(entry.rawID)
            do {
                guard let uuid = entry.id else {
                    throw CanonicalTranscriptStore.StoreError.invalidData("stored document ID is not a UUID")
                }
                if session.needsAttention(try refreshed(CanonicalTranscriptStore.summary(id: uuid))) {
                    reviewable.append(.managed(id: uuid))
                }
            } catch {
                print("\(color.red("(unreadable)"))\t\(id)\t\(safeText(errorText(error)))")
            }
        }
        guard !reviewable.isEmpty else {
            print(options.all
                ? "No saved transcripts with diarized speakers."
                : "All speakers in saved transcripts are confirmed; run with --all to revisit them.")
            return
        }
        try session.run(documents: reviewable)
    }

    /// `review --apply`: saves refreshed suggestions and automatic matches.
    private static func applyRefreshedMatches(
        _ ref: TranscriptRef, options: SpeakerReviewArguments, arguments: [String]
    ) throws {
        let refresh = ExportRefresh.enabled(flag: options.refreshExports)
        func report(_ saved: String) {
            print(refresh ? saved : saved + " Export again to update rendered files.")
        }
        switch ref {
        case .portable(let url):
            try withDocumentLock(at: url) {
                let document = try refreshed(loadTranscript(ref, arguments: arguments))
                printReview(TranscriptSummary(document))
                try CanonicalTranscriptStore.save(document, to: ref)
                report(color.green("Saved assignments to \(url.path)."))
                if refresh { ExportRefresh.run(document: document, at: ref, color: color) }
            }
        case .managed(let id):
            let document = try inWriteTransaction {
                let document = try refreshed(loadTranscript(ref, arguments: arguments))
                try CanonicalTranscriptStore.save(document, to: ref)
                return document
            }
            printReview(TranscriptSummary(document))
            report(color.green("Saved assignments for \(ref.displayName)."))
            if refresh { refreshManagedExports(id: id, color: color) }
        }
    }

    private static func idleMessage(for summary: TranscriptSummary, all: Bool) -> String {
        if summary.speakerEmbeddings.isEmpty {
            return "No diarized speakers in this transcript."
        }
        if all { return "No diarized speakers to revisit in this transcript." }
        return (summary.dismissedSpeakers?.isEmpty == false)
            ? "All speakers are confirmed or marked unidentifiable; run with --all to revisit them."
            : "All speakers are confirmed; run with --all to revisit them."
    }

    /// Loads a document and returns it with its speaker matches recomputed
    /// against the current profile store. The result is not saved; only
    /// review --apply writes it back.
    static func refreshedDocument(_ ref: TranscriptRef) throws -> CanonicalTranscript {
        try refreshed(CanonicalTranscriptStore.load(ref))
    }

    /// `refreshedDocument(_:)` for a document the caller already loaded.
    private static func refreshed(_ loaded: CanonicalTranscript) throws -> CanonicalTranscript {
        var document = loaded
        document.speakerMatches = try refreshedMatches(
            embeddings: document.output.speakerEmbeddings, modelID: document.embeddingModelID,
            evidenceID: document.evidenceID, sourceHashes: document.sourceHashes,
            stored: document.speakerMatches, dismissed: document.dismissedSpeakers
        )
        return document
    }

    /// The same refresh over a payload-free summary.
    private static func refreshed(_ loaded: TranscriptSummary) throws -> TranscriptSummary {
        var summary = loaded
        summary.speakerMatches = try refreshedMatches(
            embeddings: summary.speakerEmbeddings, modelID: summary.embeddingModelID,
            evidenceID: summary.evidenceID, sourceHashes: summary.sourceHashes,
            stored: summary.speakerMatches, dismissed: summary.dismissedSpeakers
        )
        return summary
    }

    private static func refreshedMatches(
        embeddings: [String: [Float]], modelID: String, evidenceID: String, sourceHashes: [String],
        stored: [String: SpeakerMatch], dismissed: [String]?
    ) throws -> [String: SpeakerMatch] {
        let matches = try SpeakerProfileStore.matches(
            embeddings: embeddings, modelID: modelID,
            excludingTranscriptID: evidenceID, excludingSourceHashes: sourceHashes
        )
        let profiles = try SpeakerProfileStore.profiles()
        var refreshed = matches
        for (speaker, existing) in stored where existing.status == .confirmed {
            if let profile = profiles.first(where: { $0.id == existing.profileID }) {
                refreshed[speaker] = SpeakerMatch(
                    profileID: existing.profileID, name: profile.name,
                    distance: existing.distance, margin: existing.margin,
                    confirmedExampleCount: existing.confirmedExampleCount, status: .confirmed
                )
            } else {
                // A portable document retains explicit human labels even on
                // a computer without the originating private profile store.
                refreshed[speaker] = existing
            }
        }
        // A dismissed speaker was decided to be unidentifiable, so a fresh
        // suggestion or automatic match must not resurrect it; an explicit
        // confirmation (which clears the dismissal) still wins defensively.
        for speaker in dismissed ?? [] where refreshed[speaker]?.status != .confirmed {
            refreshed.removeValue(forKey: speaker)
        }
        return SpeakerProfileStore.demoteConflictingAutomaticMatches(refreshed)
    }

    private static func printReview(_ summary: TranscriptSummary) {
        let speakers = Set(summary.segmentSpeakers).union(summary.speakerEmbeddings.keys).sorted()
        if speakers.isEmpty { print("No diarized speakers in this transcript.") }
        for speaker in speakers {
            if let match = summary.speakerMatches[speaker] {
                let distance = String(format: "%.3f", match.distance)
                let status: String
                switch match.status {
                case .confirmed: status = color.green(match.status.rawValue)
                case .automatic: status = color.cyan(match.status.rawValue)
                case .suggested: status = color.yellow(match.status.rawValue)
                }
                print("\(safeText(speaker))\t\(status)\t\(color.bold(safeText(match.name)))\tprofile=\(match.profileID)\tdistance=\(distance)\texamples=\(match.confirmedExampleCount)")
            } else if summary.isDismissed(speaker) {
                print("\(safeText(speaker))\t\(color.dim("dismissed"))")
            } else {
                print("\(safeText(speaker))\t\(color.red("unidentified"))")
            }
        }
    }

    // MARK: - Locking and transactions

    /// One write transaction on the shared state database. A managed
    /// document edit runs its document and profile changes inside it, so
    /// they commit together.
    private static func inWriteTransaction<T>(_ body: () throws -> T) throws -> T {
        try StateStore.withDatabase { database in
            try database.inTransaction(.write) { try body() }
        }
    }

    /// The lock that serializes rendering a document's exports with
    /// recording them: the file lock of a portable document, the render lock
    /// of a managed one.
    static func withRenderingLock<T>(for ref: TranscriptRef, _ body: () throws -> T) throws -> T {
        switch ref {
        case .portable(let url): return try withDocumentLock(at: url, body)
        case .managed(let id): return try withRenderLock(id: id, body)
        }
    }

    /// Serializes a read-modify-write of one portable document. Speaker
    /// commands load, edit and save the same file, so two concurrent runs
    /// would otherwise both start from the same content and the later save
    /// would silently drop the earlier one's assignment. The lock file sits
    /// beside the document and is taken before any database transaction
    /// (file lock outer, transaction inner).
    static func withDocumentLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
        // A path with no document needs no lock; running the body unlocked
        // reports the missing file instead of leaving a lock beside a typo.
        guard FileManager.default.fileExists(atPath: url.path) else { return try body() }
        return try withFileLock(at: url.appendingPathExtension("lock"), body)
    }

    /// Serializes export rendering and record commit for one managed
    /// document. Refresh replaces the whole record list and treats any hash
    /// mismatch as a local edit, so two unserialized refreshes could leave a
    /// fresh export marked "locally modified" forever. Database transactions
    /// do not cover rendering, hence this advisory lock in
    /// `<state>/locks/`. Plain speaker-state edits do not take it.
    static func withRenderLock<T>(id: UUID, _ body: () throws -> T) throws -> T {
        let directory = try StatePaths.locksDirectoryURL()
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            } catch {
                // Another process may have created it first.
                guard FileManager.default.fileExists(atPath: directory.path) else { throw error }
            }
            try tightenPermissions(ofPath: directory.path, to: privateDirectoryMode)
        }
        let lock = directory.appendingPathComponent("\(id.uuidString.lowercased()).lock", isDirectory: false)
        return try withFileLock(at: lock, body)
    }

    private static func withFileLock<T>(at lock: URL, _ body: () throws -> T) throws -> T {
        let fd = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, privateFileMode)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        try tightenPermissions(ofFileDescriptor: fd, at: lock.path, to: privateFileMode)
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    // MARK: - Transcript arguments

    /// Resolves a command-line transcript argument. A path to an existing
    /// file is a portable document, used in place. Otherwise a value shaped
    /// like a saved-document ID (the UUID printed by transcripts, inspect,
    /// and review, or a unique prefix of one) resolves against the stored
    /// documents. Managed documents have no file, so any other path is an
    /// error that points at the ID form — including the 2.x managed paths
    /// scripts may still hold.
    private static func transcriptRef(_ reference: String, arguments: [String]) throws -> TranscriptRef {
        // Use the same target for a portable file's sidecar lock, read, and
        // atomic replace.
        // Renaming over an unresolved symlink would detach it from its target.
        let url = URL(fileURLWithPath: (reference as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath()
        if FileManager.default.fileExists(atPath: url.path) { return .portable(url) }
        guard let candidate = transcriptIDCandidate(reference) else {
            throw TranscribeError(
                message: withSplitPathHint(
                    "No transcript at \(safeText(url.path)). Run transcribe transcripts to list saved documents. Saved transcripts are addressed by ID (or a unique prefix of at least four characters), not by a path.",
                    arguments
                ),
                exitCode: .inputFile
            )
        }
        let matches = try CanonicalTranscriptStore.documentIDs(withPrefix: candidate)
        switch matches.count {
        case 1:
            guard let id = UUID(uuidString: matches[0]) else {
                throw CanonicalTranscriptStore.StoreError.invalidData("stored document ID \(matches[0]) is not a UUID")
            }
            return .managed(id: id)
        case 0:
            throw TranscribeError(
                message: "No transcript at \(safeText(reference)) and no saved transcript ID starts with it. Run transcribe transcripts to list saved documents.",
                exitCode: .inputFile
            )
        default:
            throw usage(
                "Transcript ID '\(safeText(reference))' is ambiguous: \(matches.joined(separator: ", ")). Give more characters or the full ID."
            )
        }
    }

    /// The lowercased saved-document ID an argument may name: hex digits and
    /// dashes only, at least four characters so a short filename cannot match
    /// by accident, optionally carrying the 2.x listing's .transcript.json
    /// suffix. Anything else is treated as a path.
    private static func transcriptIDCandidate(_ reference: String) -> String? {
        var text = reference.trimmingCharacters(in: .whitespaces).lowercased()
        let suffix = ".transcript.json"
        if text.hasSuffix(suffix) { text = String(text.dropLast(suffix.count)) }
        guard text.count >= 4, text.count <= 36,
              text.allSatisfy({ $0 == "-" || ($0.isASCII && $0.isHexDigit) })
        else { return nil }
        return text
    }

    /// One-line reason for a document that could not be listed or read. A
    /// decoding error's localizedDescription drops the field that failed, so
    /// name it here.
    static func errorText(_ error: Error) -> String {
        switch error {
        case let error as DecodingError:
            switch error {
            case .keyNotFound(let key, _):
                return "missing field '\(key.stringValue)'"
            case .typeMismatch(_, let context), .valueNotFound(_, let context):
                let path = context.codingPath.map(\.stringValue).joined(separator: ".")
                return path.isEmpty ? "unexpected document structure" : "invalid field '\(path)'"
            case .dataCorrupted(let context):
                return context.debugDescription
            @unknown default:
                return error.localizedDescription
            }
        case let error as TranscribeError:
            return error.message
        case let error as LocalizedError:
            return error.errorDescription ?? error.localizedDescription
        default:
            return error.localizedDescription
        }
    }

    /// Loads a document named on the command line. A missing file or a
    /// document that does not decode is reported with its path or ID and the
    /// reason, plus a quoting hint when the shell split the intended path at
    /// its spaces.
    private static func loadTranscript(_ ref: TranscriptRef, arguments: [String]) throws -> CanonicalTranscript {
        if case .portable(let url) = ref, !FileManager.default.fileExists(atPath: url.path) {
            throw TranscribeError(
                message: withSplitPathHint("No transcript at \(safeText(url.path)). Run transcribe transcripts to list saved documents.", arguments),
                exitCode: .inputFile
            )
        }
        do {
            return try CanonicalTranscriptStore.load(ref)
        } catch {
            throw unreadable(ref, error, arguments: arguments)
        }
    }

    /// `loadTranscript` for commands that never need segment text. A managed
    /// document's summary comes from lifted columns without reading the
    /// payload; a portable file has to be read whole.
    private static func loadSummary(_ ref: TranscriptRef, arguments: [String]) throws -> TranscriptSummary {
        switch ref {
        case .portable:
            return TranscriptSummary(try loadTranscript(ref, arguments: arguments))
        case .managed(let id):
            do {
                return try CanonicalTranscriptStore.summary(id: id)
            } catch {
                throw unreadable(ref, error, arguments: arguments)
            }
        }
    }

    private static func unreadable(_ ref: TranscriptRef, _ error: Error, arguments: [String]) -> TranscribeError {
        var reason = safeText(errorText(error))
        if !reason.hasSuffix(".") { reason += "." }
        return TranscribeError(
            message: withSplitPathHint("Cannot read transcript \(safeText(ref.displayName)): \(reason)", arguments),
            exitCode: .inputFile
        )
    }

    /// A path with spaces reaches the command as several arguments when it
    /// was not quoted, which otherwise surfaces as an unexpected argument or
    /// as an unrelated file under the first fragment. When adjacent arguments
    /// rejoin into an existing file, append that path, shell-quoted.
    private static func withSplitPathHint(_ message: String, _ arguments: [String]) -> String {
        guard let path = splitPath(arguments) else { return message }
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return message + "\nThe path contains spaces and was split into separate arguments; quote it: \(safeText(quoted))"
    }

    private static func splitPath(_ arguments: [String]) -> String? {
        for start in arguments.indices where !arguments[start].hasPrefix("-") {
            // Longest run first, so the whole intended path wins over a
            // shorter prefix that also happens to exist.
            for end in stride(from: arguments.count - 1, to: start, by: -1) {
                let run = arguments[start...end]
                guard !run.contains(where: { $0.hasPrefix("-") }) else { continue }
                let joined = run.joined(separator: " ")
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: (joined as NSString).expandingTildeInPath, isDirectory: &isDirectory),
                   !isDirectory.boolValue {
                    return joined
                }
            }
        }
        return nil
    }

    /// Accepts `SPEAKER_0`, `speaker_0`, or a bare `0` for the local ID
    /// SPEAKER_0; anything else passes through for the lookup to reject.
    static func localSpeakerID(_ value: String) -> String {
        let prefix = "SPEAKER_"
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return prefix + trimmed
        }
        if trimmed.prefix(prefix.count).uppercased() == prefix {
            return prefix + trimmed.dropFirst(prefix.count)
        }
        return value
    }

    /// Names the speakers the document does have, so a wrong ID is one retry
    /// from the right one rather than a trip through inspect.
    private static func unknownSpeaker(_ speaker: String, in document: CanonicalTranscript) -> TranscribeError {
        if document.output.segments.contains(where: { $0.speaker == speaker }) {
            return usage("Local speaker '\(safeText(speaker))' has no voice embedding in this transcript.")
        }
        // SPEAKER_2 sorts before SPEAKER_10: fewer digits means a smaller number.
        let known = document.output.speakerEmbeddings.keys.sorted { ($0.count, $0) < ($1.count, $1) }
        guard !known.isEmpty else {
            return usage("Unknown local speaker '\(safeText(speaker))'; this transcript has no diarized speakers.")
        }
        let listing = known.map { id -> String in
            guard let match = document.speakerMatches[id] else { return "\(id) (unidentified)" }
            return "\(id) (\(safeText(match.name)), \(match.status.rawValue))"
        }
        return usage("Unknown local speaker '\(safeText(speaker))'. Speakers in this transcript: \(listing.joined(separator: ", ")).")
    }

    private static func safeText(_ text: String) -> String {
        text.components(separatedBy: .controlCharacters).joined(separator: " ")
    }

    private static func parse<T: ParsableArguments>(_ type: T.Type, _ args: [String]) throws -> T {
        do { return try type.parse(args) }
        catch { throw usage(withSplitPathHint(type.message(for: error), args)) }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw usage(message) }
    }

    private static func usage(_ message: String) -> TranscribeError {
        TranscribeError(message: message, exitCode: .invalidUsage)
    }
}
