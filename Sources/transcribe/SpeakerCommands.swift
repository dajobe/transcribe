import ArgumentParser
import Darwin
import Foundation

struct TranscriptExportArguments: ParsableArguments {
    @Argument(help: "Path to a saved .transcript.json document.")
    var transcript: String
    @Option(name: [.short, .long], help: "Comma-separated formats, or all.")
    var format: String = "txt,json"
    @Option(name: [.customShort("o"), .long], help: "Destination directory.")
    var outputDir: String = "."
    @Option(name: .long, help: "Override the saved output basename.")
    var outputPrefix: String?
    @Flag(name: .long, help: "Replace existing exports.")
    var overwrite: Bool = false
}

struct SpeakerReviewArguments: ParsableArguments {
    @Argument(help: "Path to a saved .transcript.json document; omit to review all saved transcripts.")
    var transcript: String?
    @Flag(help: "Save refreshed suggestions and strong automatic matches to this document without prompting.")
    var apply: Bool = false
    @Flag(help: "Also revisit speakers that are already confirmed.")
    var all: Bool = false
    @Flag(inversion: .prefixedNo, help: "Force or disable the interactive session (default: interactive on a terminal).")
    var interactive: Bool?
}

struct SpeakerConfirmArguments: ParsableArguments {
    @Argument var transcript: String
    @Argument(help: "Local speaker ID, for example SPEAKER_0.") var speaker: String
    @Option(help: "Name for a new profile; quote names containing spaces.") var name: String?
    @Option(help: "Existing profile ID printed by speakers list or review.") var profile: String?
}

enum SpeakerCommands {
    private static let color = Terminal.stdout

    /// The only fields the listing prints. Decoding this instead of the whole
    /// canonical document keeps one damaged, truncated or newer-schema file
    /// from hiding every other saved transcript, and avoids reading embedding
    /// vectors and recomputing evidence IDs just to print two columns.
    private struct TranscriptListing: Decodable {
        let basename: String
    }

    static func transcripts(_ args: [String]) throws {
        if args == ["--help"] || args == ["-h"] {
            print("USAGE: transcribe transcripts\nLists saved canonical transcript paths. Copy a path into inspect, speakers review, or export.")
            return
        }
        try require(args.isEmpty, "Usage: transcribe transcripts")
        let directory = try StatePaths.stateDirectoryURL().appendingPathComponent("transcripts")
        guard FileManager.default.fileExists(atPath: directory.path) else {
            print("No saved canonical transcripts.")
            return
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".transcript.json") }.sorted { $0.path < $1.path }
        if files.isEmpty { print("No saved canonical transcripts.") }
        for file in files {
            // A file this command cannot read is reported in place so the rest
            // of the listing still reaches the user.
            do {
                let listing = try JSONDecoder().decode(TranscriptListing.self, from: Data(contentsOf: file))
                let basename = listing.basename.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !basename.isEmpty else { throw CanonicalTranscriptStore.StoreError.invalidData("basename is empty") }
                print("\(Terminal.stdout.bold(safeText(listing.basename)))\t\(Terminal.stdout.dim(file.path))")
            } catch {
                print("\(Terminal.stdout.red("(unreadable)"))\t\(Terminal.stdout.dim(file.path))\t\(safeText(errorText(error)))")
            }
        }
    }

    static func helpText() -> String {
        """
        USAGE: transcribe speakers <subcommand>

          list
          review [transcript.json] [--all] [--apply] [--[no-]interactive]
          confirm <transcript.json> <SPEAKER_n> --name <name>
          confirm <transcript.json> <SPEAKER_n> --profile <profile-id>
          clear <transcript.json> <SPEAKER_n>
          rename <profile-id> <name>
          delete <profile-id>

        On a terminal, review is an interactive session showing speech samples
        for each speaker needing attention and prompting for a name; without a
        transcript it walks every saved document. --all also revisits confirmed
        speakers. Piped output keeps the read-only table, and --apply saves
        refreshed suggestions and strong automatic matches without prompting.
        Only explicit confirmation adds a voice example to a profile.
        Automatic names require two independent confirmed recordings and a clear
        matching margin. Distances are heuristics, not identity probabilities.
        Clear removes this document's assignment and confirmed example. Delete
        removes a profile and its examples; saved transcript name snapshots remain.
        """
    }

    static func exportHelpText() -> String {
        """
        USAGE: transcribe export <transcript.json> [--format txt,json,srt,vtt,md,tsv,all]
                                 [-o <directory>] [--output-prefix <name>] [--overwrite]

        Renders a saved canonical transcript without audio, models, or downloads.
        Saved confirmed and automatic names are used; suggestions remain local IDs.
        Existing JSON exports retain their prior schema and contain no embeddings.
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
            try review(parse(SpeakerReviewArguments.self, args))
        case "confirm":
            let options = try parse(SpeakerConfirmArguments.self, args)
            try require((options.name != nil) != (options.profile != nil), "Use exactly one of --name or --profile.")
            let url = transcriptURL(options.transcript)
            try withDocumentLock(at: url) {
                var document = try CanonicalTranscriptStore.load(from: url)
                guard let embedding = document.output.speakerEmbeddings[options.speaker] else {
                    throw usage("No embedding for local speaker '\(options.speaker)' in this document.")
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
                    speakerID: options.speaker, embedding: embedding, modelID: document.embeddingModelID,
                    sourceHashes: document.sourceHashes
                )
                document.speakerMatches[options.speaker] = match
                do {
                    _ = try CanonicalTranscriptStore.save(document, to: url)
                } catch {
                    throw TranscribeError(
                        message: "Profile was confirmed, but the transcript could not be saved: \(error). Retry confirmation with --profile \(match.profileID); it will not duplicate the example.",
                        exitCode: .outputWrite
                    )
                }
                print(color.green("Confirmed \(options.speaker) as \(safeText(match.name)) (\(match.profileID)).") + " Export again to update rendered files.")
            }
        case "clear":
            try require(args.count == 2, "Usage: transcribe speakers clear <transcript.json> <SPEAKER_n>")
            let url = transcriptURL(args[0])
            try withDocumentLock(at: url) {
                var document = try CanonicalTranscriptStore.load(from: url)
                try require(document.output.speakerEmbeddings[args[1]] != nil, "Unknown local speaker '\(args[1])'.")
                // Remove any confirmed example, including a confirmation whose
                // document save previously failed.
                try SpeakerProfileStore.clearExamples(transcriptID: document.evidenceID, speakerID: args[1])
                document.speakerMatches.removeValue(forKey: args[1])
                _ = try CanonicalTranscriptStore.save(document, to: url)
                print(color.green("Cleared \(safeText(args[1])).") + " Future explicit review can suggest matches again.")
            }
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

    static func export(_ args: [String]) throws {
        if args == ["--help"] || args == ["-h"] {
            print(exportHelpText())
            return
        }
        let options = try parse(TranscriptExportArguments.self, args)
        if let prefix = options.outputPrefix {
            try require(
                !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Output filename prefix cannot be empty."
            )
        }
        let document = try CanonicalTranscriptStore.load(from: transcriptURL(options.transcript))
        let formats = parseOutputFormats(options.format)
        try require(!formats.isEmpty && formats.allSatisfy(validOutputFormats.contains), "Unsupported or empty output format list.")
        let basename = options.outputPrefix ?? document.basename
        let inputPath = transcriptURL(options.transcript).standardizedFileURL.resolvingSymlinksInPath().path
        let inputIdentity = fileIdentity(inputPath)
        let destinations = outputPaths(
            outputDir: options.outputDir, basename: basename,
            formats: formats, writeTxtFile: formats.contains("txt")
        )
        // String equality alone misses a destination that names the input by
        // another spelling: a case-flipped prefix on a case-insensitive
        // volume, or a symlink. Compare on-disk identity whenever the
        // destination already exists, since only an existing file can be
        // replaced by the export.
        for destination in destinations {
            let sameFile = destination == inputPath
                || (inputIdentity != nil && fileIdentity(destination) == inputIdentity)
            try require(!sameFile, "An export cannot replace its canonical transcript. Choose another output prefix or directory.")
        }
        try writeOutputs(
            output: document.renderedOutput(), audioPath: document.audioPath,
            audioFiles: document.audioFiles, sourceMetadata: document.sourceMetadata,
            outputDir: options.outputDir, basename: basename,
            formats: formats, overwrite: options.overwrite,
            model: document.model, version: document.transcribeVersion
        )
        print(color.green("Exported \(formats.joined(separator: ",")) to \(resolvedOutputDir(options.outputDir))."))
    }

    static func inspect(_ args: [String]) throws {
        if args == ["--help"] || args == ["-h"] {
            print("USAGE: transcribe inspect <transcript.json>\nShows metadata and saved assignments without printing voice embeddings.")
            return
        }
        try require(args.count == 1, "Usage: transcribe inspect <transcript.json>")
        let document = try CanonicalTranscriptStore.load(from: transcriptURL(args[0]))
        print("Transcript: \(document.id)\nModel: \(safeText(document.model))\nDuration: \(document.output.durationSeconds)s\nSegments: \(document.output.segments.count)")
        printReview(document)
    }

    /// Routes `speakers review`. On a terminal this is an interactive
    /// identification session; scripts keep the 2.6.0 read-only table
    /// (piped streams) and `--apply` semantics. Without a transcript
    /// argument the review spans every saved canonical document.
    private static func review(_ options: SpeakerReviewArguments) throws {
        try require(!(options.apply && options.interactive == true), "Use --apply or --interactive, not both.")
        if options.apply {
            guard let transcript = options.transcript else {
                throw usage("--apply needs a transcript path; run transcribe transcripts to list them.")
            }
            let url = transcriptURL(transcript)
            try withDocumentLock(at: url) {
                let document = try refreshedDocument(at: url)
                printReview(document)
                _ = try CanonicalTranscriptStore.save(document, to: url)
                print(color.green("Saved assignments to \(url.path).") + " Export again to update rendered files.")
            }
            return
        }
        let interactive = options.interactive ?? Terminal.isInteractive
        let session = SpeakerReview.Session(includeConfirmed: options.all)
        if let transcript = options.transcript {
            let url = transcriptURL(transcript)
            guard interactive else {
                printReview(try refreshedDocument(at: url))
                return
            }
            let document = try refreshedDocument(at: url)
            guard session.needsAttention(document) else {
                print(idleMessage(for: document, all: options.all))
                return
            }
            try session.run(documents: [url])
            return
        }
        let urls = try savedTranscriptURLs()
        guard !urls.isEmpty else {
            print("No saved canonical transcripts.")
            return
        }
        guard interactive else {
            for url in urls {
                do {
                    let document = try refreshedDocument(at: url)
                    print("\(color.bold(safeText(document.basename)))\t\(color.dim(url.path))")
                    printReview(document)
                } catch {
                    print("\(color.red("(unreadable)"))\t\(color.dim(url.path))\t\(safeText(errorText(error)))")
                }
            }
            return
        }
        var reviewable: [URL] = []
        for url in urls {
            do {
                if session.needsAttention(try refreshedDocument(at: url)) { reviewable.append(url) }
            } catch {
                print("\(color.red("(unreadable)"))\t\(color.dim(url.path))\t\(safeText(errorText(error)))")
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

    private static func idleMessage(for document: CanonicalTranscript, all: Bool) -> String {
        if document.output.speakerEmbeddings.isEmpty {
            return "No diarized speakers in this transcript."
        }
        return all
            ? "No diarized speakers to revisit in this transcript."
            : "All speakers are confirmed; run with --all to revisit them."
    }

    /// Saved canonical documents, newest first, so an all-documents review
    /// reaches recent recordings before the backlog.
    private static func savedTranscriptURLs() throws -> [URL] {
        let directory = try StatePaths.stateDirectoryURL().appendingPathComponent("transcripts")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let key = URLResourceKey.contentModificationDateKey
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [key])
            .filter { $0.lastPathComponent.hasSuffix(".transcript.json") }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [key]).contentModificationDate) ?? .distantPast
        }
        return files.sorted { (modified($0), $0.path) > (modified($1), $1.path) }
    }

    /// Loads a document and returns it with its speaker matches recomputed
    /// against the current profile store. The result is not saved; only
    /// review --apply writes it back.
    static func refreshedDocument(at url: URL) throws -> CanonicalTranscript {
        var document = try CanonicalTranscriptStore.load(from: url)
        let matches = try SpeakerProfileStore.matches(
            embeddings: document.output.speakerEmbeddings,
            modelID: document.embeddingModelID,
            excludingTranscriptID: document.evidenceID,
            excludingSourceHashes: document.sourceHashes
        )
        let profiles = try SpeakerProfileStore.profiles()
        var refreshed = matches
        for (speaker, existing) in document.speakerMatches where existing.status == .confirmed {
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
        document.speakerMatches = SpeakerProfileStore.demoteConflictingAutomaticMatches(refreshed)
        return document
    }

    /// Serializes a read-modify-write of one canonical document. Speaker
    /// commands load, edit and save the same file, so two concurrent runs
    /// would otherwise both start from the same content and the later save
    /// would silently drop the earlier one's assignment. The lock file sits
    /// beside the document; the profile store takes its own lock inside this
    /// one, so document-then-profile is the single lock order in this tool.
    static func withDocumentLock<T>(at url: URL, _ body: () throws -> T) throws -> T {
        // A path with no document needs no lock; running the body unlocked
        // reports the missing file instead of leaving a lock beside a typo.
        guard FileManager.default.fileExists(atPath: url.path) else { return try body() }
        let lock = url.appendingPathExtension("lock")
        let fd = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, privateFileMode)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        try tightenPermissions(ofFileDescriptor: fd, at: lock.path, to: privateFileMode)
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    /// Device and inode of an existing file, or nil when it does not exist.
    /// Two paths naming the same identity are the same file whatever the
    /// spelling: a case-insensitive volume, a symlink, or a hard link.
    private static func fileIdentity(_ path: String) -> String? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }

    private static func printReview(_ document: CanonicalTranscript) {
        let speakers = Set(document.output.segments.compactMap(\.speaker))
            .union(document.output.speakerEmbeddings.keys).sorted()
        if speakers.isEmpty { print("No diarized speakers in this transcript.") }
        for speaker in speakers {
            if let match = document.speakerMatches[speaker] {
                let distance = String(format: "%.3f", match.distance)
                let status: String
                switch match.status {
                case .confirmed: status = color.green(match.status.rawValue)
                case .automatic: status = color.cyan(match.status.rawValue)
                case .suggested: status = color.yellow(match.status.rawValue)
                }
                print("\(safeText(speaker))\t\(status)\t\(color.bold(safeText(match.name)))\tprofile=\(match.profileID)\tdistance=\(distance)\texamples=\(match.confirmedExampleCount)")
            } else {
                print("\(safeText(speaker))\t\(color.red("unidentified"))")
            }
        }
    }

    private static func transcriptURL(_ path: String) -> URL {
        // Use the same target for the sidecar lock, read, and atomic replace.
        // Renaming over an unresolved symlink would detach it from its target.
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath()
    }

    /// One-line reason for a file that could not be listed. A decoding error's
    /// localizedDescription drops the field that failed, so name it here.
    private static func errorText(_ error: Error) -> String {
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
        case let error as LocalizedError:
            return error.errorDescription ?? error.localizedDescription
        default:
            return error.localizedDescription
        }
    }

    private static func safeText(_ text: String) -> String {
        text.components(separatedBy: .controlCharacters).joined(separator: " ")
    }

    private static func parse<T: ParsableArguments>(_ type: T.Type, _ args: [String]) throws -> T {
        do { return try type.parse(args) }
        catch { throw usage(type.message(for: error)) }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw usage(message) }
    }

    private static func usage(_ message: String) -> TranscribeError {
        TranscribeError(message: message, exitCode: .invalidUsage)
    }
}
