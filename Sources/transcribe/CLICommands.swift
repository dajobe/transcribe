import ArgumentParser
import Foundation

struct FileSourceArguments: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "file",
        abstract: "Transcribe one audio file.",
        usage: "transcribe [<global-options>] file <audio-file>",
        discussion: "Run `transcribe --help` to see global model, output, diarization, idempotency, timing, and compute options."
    )

    @Argument(help: "Path to an audio file.")
    var audioFile: String
}

struct DirSourceArguments: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "dir",
        abstract: "Transcribe a directory of sequential audio clips.",
        usage: "transcribe [<global-options>] dir [<dir-options>] <directory>",
        discussion: "Run `transcribe --help` to see global model, output, diarization, idempotency, timing, and compute options."
    )

    @OptionGroup var options: DirectoryInputOptions

    @Argument(help: "Path to a directory of top-level audio clips.")
    var directory: String
}

struct HistoryArguments: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "history",
        abstract: "Show recent transcription and import history.",
        usage: "transcribe history [--count <n>]",
        discussion: """
            Reads the append-only processing-history ledger written by previous \
            runs (and by --mark-imported). Entries appear newest first with a \
            relative timestamp; entries older than seven days are shown as ISO \
            8601 UTC.
            """
    )

    @Option(name: .long, help: "Number of entries to show (default: 10).")
    var count: Int = 10
}

struct VoiceMemosSourceArguments: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "voice-memos",
        abstract: "Import synced Apple Voice Memos directly from the local database and audio files.",
        usage: "transcribe [<global-options>] voice-memos [<voice-memos-options>]",
        discussion: "Run `transcribe --help` to see global model, output, diarization, idempotency, timing, and compute options."
    )

    @Option(
        name: .long,
        help: """
            Voice Memos recordings directory containing CloudRecordings.db \
            (default: \(TranscriptionDefaults.voiceMemosRecordingsDir)).
            """
    )
    var recordingsDir: String?

    @Option(
        name: .long,
        help: """
            Split Voice Memos into separate transcripts at gaps larger than N minutes between recordings \
            (0 disables; default: \(TranscriptionDefaults.voiceMemosSessionGapMinutes)).
            """
    )
    var sessionGap: Int?
}

struct SourceCommandDispatcher {
    let options: SharedTranscriptionOptions
    let sourceArgs: [String]

    func run() async throws {
        if sourceArgs.count == 1 && (sourceArgs[0] == "--help" || sourceArgs[0] == "-h") {
            printHelp(Transcribe.helpMessage())
            return
        }
        if sourceArgs.count == 1 && sourceArgs[0] == "--version" {
            printHelp(Transcribe.version)
            return
        }

        guard let source = sourceArgs.first else {
            printHelp(Self.defaultBanner())
            return
        }

        let args = Array(sourceArgs.dropFirst())
        switch source {
        case "help":
            try printSourceHelp(args)
        case "config":
            try runConfig(args)
        case "file":
            try await runFile(args)
        case "dir":
            try await runDirectory(args)
        case "voice-memos":
            try await runVoiceMemos(args)
        case "history":
            try runHistory(args)
        default:
            // Anything starting with `-` at the source position is an
            // unrecognised global flag/option that ArgumentParser couldn't
            // match (so .captureForPassthrough swallowed it and everything
            // after into sourceArgs). Reporting it as a "root path alias"
            // would be misleading.
            if source.hasPrefix("-") {
                throw TranscribeError(
                    message: "Unknown global option `\(source)`. Run `transcribe --help` to see the supported global options; source-specific options go after the source command (e.g. `transcribe voice-memos --session-gap 10`).",
                    exitCode: .invalidUsage
                )
            }
            try await runRootAlias(path: source, remaining: args)
        }
    }

    private func runFile(_ args: [String]) async throws {
        if isHelpRequest(args) {
            printHelp(FileSourceArguments.helpMessage())
            return
        }
        let source = try parse(FileSourceArguments.self, args)
        try SourcePlanner.validateFilePath(source.audioFile)
        let userFile = try ConfigMerge.loadUserFile()
        let merged = try ConfigMerge.mergeShared(cli: options, file: userFile)
        try await PipelineRunner(
            request: .file(path: source.audioFile),
            options: merged
        ).run()
    }

    private func runDirectory(_ args: [String]) async throws {
        if isHelpRequest(args) {
            printHelp(DirSourceArguments.helpMessage())
            return
        }
        let source = try parse(DirSourceArguments.self, args)
        try SourcePlanner.validateDirectoryPath(source.directory)
        let userFile = try ConfigMerge.loadUserFile()
        let mergedShared = try ConfigMerge.mergeShared(cli: options, file: userFile)
        let mergedDir = try ConfigMerge.mergeDirectory(cli: source.options, file: userFile)
        try await PipelineRunner(
            request: .directory(path: source.directory, options: mergedDir),
            options: mergedShared
        ).run()
    }

    private func runVoiceMemos(_ args: [String]) async throws {
        if isHelpRequest(args) {
            printHelp(VoiceMemosSourceArguments.helpMessage())
            return
        }
        let source = try parse(VoiceMemosSourceArguments.self, args)
        let userFile = try ConfigMerge.loadUserFile()
        let mergedShared = try ConfigMerge.mergeShared(cli: options, file: userFile)
        let mergedVM = ConfigMerge.mergeVoiceMemos(cli: source, file: userFile)
        try await PipelineRunner(
            request: .voiceMemos(recordingsDir: mergedVM.recordingsDir, sessionGap: mergedVM.sessionGap),
            options: mergedShared
        ).run()
    }

    private func runHistory(_ args: [String]) throws {
        if isHelpRequest(args) {
            printHelp(HistoryArguments.helpMessage())
            return
        }
        let parsed = try parse(HistoryArguments.self, args)
        try HistoryCommand.run(count: parsed.count)
    }

    private func runConfig(_ args: [String]) throws {
        try ConfigCommand.run(globalArgs: options, argv: args)
    }

    private func runRootAlias(path: String, remaining: [String]) async throws {
        guard remaining.isEmpty else {
            throw TranscribeError(
                message: "Unexpected argument(s) after root path alias: \(remaining.joined(separator: " ")). Put global options before the path, or use `transcribe dir` for directory-specific options.",
                exitCode: .invalidUsage
            )
        }

        let mode = try SourcePlanner.modeForAliasPath(path)
        let userFile = try ConfigMerge.loadUserFile()
        let mergedShared = try ConfigMerge.mergeShared(cli: options, file: userFile)
        let request: PipelineRequest
        switch mode {
        case .file:
            request = .file(path: path)
        case .directory:
            let mergedDir = try ConfigMerge.mergeDirectory(cli: try DirectoryInputOptions.parse([]), file: userFile)
            request = .directory(path: path, options: mergedDir)
        case .voiceMemos:
            preconditionFailure("Root alias cannot resolve to Voice Memos")
        }
        try await PipelineRunner(request: request, options: mergedShared).run()
    }

    private func printSourceHelp(_ args: [String]) throws {
        guard args.count == 1 else {
            throw TranscribeError(
                message: "Use `transcribe file --help`, `transcribe dir --help`, `transcribe voice-memos --help`, `transcribe history --help`, or `transcribe config --help`.",
                exitCode: .invalidUsage
            )
        }
        switch args[0] {
        case "file":
            printHelp(FileSourceArguments.helpMessage())
        case "dir":
            printHelp(DirSourceArguments.helpMessage())
        case "voice-memos":
            printHelp(VoiceMemosSourceArguments.helpMessage())
        case "history":
            printHelp(HistoryArguments.helpMessage())
        case "config":
            printHelp(ConfigCommand.helpText())
        default:
            throw TranscribeError(message: "Unknown source command '\(args[0])'.", exitCode: .invalidUsage)
        }
    }

    private func parse<T: ParsableArguments>(_ type: T.Type, _ args: [String]) throws -> T {
        do {
            return try type.parse(args)
        } catch {
            throw TranscribeError(message: type.message(for: error), exitCode: .invalidUsage)
        }
    }

    private func isHelpRequest(_ args: [String]) -> Bool {
        args.count == 1 && (args[0] == "--help" || args[0] == "-h")
    }

    private func printHelp(_ text: String) {
        FileHandle.standardOutput.write((text + "\n").data(using: .utf8)!)
    }

    /// Friendly summary printed when the user runs `transcribe` with no
    /// arguments. Shorter than `--help`, points at the next steps.
    static func defaultBanner() -> String {
        """
        transcribe \(Transcribe.version) — on-device meeting transcription with optional speaker diarization.
        Runs WhisperKit (and optionally SpeakerKit diarization) on Apple Silicon.

        Usage: transcribe [<global-options>] <source> [<source-options>]

        Sources:
          file <audio-file>             Transcribe one audio file.
          dir [<dir-options>] <dir>     Transcribe a directory of sequential audio clips.
          voice-memos [<options>]       Import synced Apple Voice Memos.

        Other commands:
          history [--count <n>]         Show recent transcription/import history.
          config <subcommand>           View or edit JSON-backed user defaults (see `transcribe config --help`).

        Examples:
          transcribe file meeting.m4a
          transcribe dir ~/Recordings
          transcribe voice-memos --session-gap 10
          transcribe history --count 20

        For all global options, run:        transcribe --help
        For source-specific options, run:   transcribe <source> --help
        """
    }
}

struct SharedTranscriptionOptions: ParsableArguments {
    @Option(
        name: [.short, .long],
        help: ArgumentHelp(
            "Whisper model to use (default: \(TranscriptionDefaults.defaultModel); first run downloads ~1.5 GB to the model cache directory)"
        )
    )
    var model: String?

    @Option(
        name: [.short, .long],
        help: ArgumentHelp(
            "Language code such as \"en\". \(ConfigSemanticStrings.languageWhenUnset)"
        )
    )
    var language: String?

    @Option(
        name: [.short, .long],
        help: "Directory for output files (default: \(TranscriptionDefaults.outputDir)). ~ expands to your home directory (not /tmp)."
    )
    var outputDir: String?

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Output file basename prefix. \(ConfigSemanticStrings.outputPrefixWhenUnset)"
        )
    )
    var outputPrefix: String?

    @Option(
        name: [.short, .long],
        help: "Output formats, comma-separated (default: \(TranscriptionDefaults.format)): txt, json, srt, vtt, md, all"
    )
    var format: String?

    @Flag(help: "Write the primary transcript to stdout instead of a text file")
    var stdout: Bool = false

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Minimum speaker count hint for diarization. \(ConfigSemanticStrings.speakersMinWhenUnset)"
        )
    )
    var speakersMin: Int?

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Maximum speaker count hint for diarization. \(ConfigSemanticStrings.speakersMaxWhenUnset)"
        )
    )
    var speakersMax: Int?

    @Flag(name: .long, help: "Transcript only: skip speaker labels")
    var transcriptOnly: Bool = false

    @Flag(name: .long, help: "Add speaker labels for this run (overrides config; opposite of --transcript-only)")
    var withSpeakers: Bool = false

    @Option(name: .long, help: "How speaker segments are merged: subsegment or segment (default: \(TranscriptionDefaults.speakerMerge))")
    var speakerMerge: String?

    @Option(
        name: .long,
        help: "Directory used for downloaded model caches (default: \(TranscriptionDefaults.modelDir))"
    )
    var modelDir: String?

    @Flag(help: "Replace existing output files")
    var overwrite: Bool = false

    @Flag(name: .long, help: "Reprocess inputs even when processing history says they were already completed")
    var redo: Bool = false

    @Flag(name: .long, help: "Do not read or write processing history (fully non-idempotent)")
    var stateless: Bool = false

    @Flag(
        name: .long,
        help: "Mark planned inputs as already imported without transcribing them. Future runs skip them on source identity and content fingerprint alone, regardless of model, format, or other settings."
    )
    var markImported: Bool = false

    @Flag(
        name: [.customLong("dry-run"), .customLong("dryrun")],
        help: "Show what would be processed or skipped without loading models, writing outputs, or updating processing history"
    )
    var dryRun: Bool = false

    @Flag(name: .long, help: "Print progress, timing, and cache details to stderr")
    var verbose: Bool = false

    @Flag(name: .long, help: "Reduce stderr logging (overrides config verbose for this run)")
    var quiet: Bool = false

    @Option(
        name: .long,
        help: "Record timing for ETA hints from prior runs: on or off (default: \(TranscriptionDefaults.etaHintsEnabled ? "on" : "off"))"
    )
    var etaHints: OnOff?

    @Option(
        name: .long,
        help: "Progress on stderr: auto (TTY spinner when a terminal), plain (throttled lines for pipes/logs), or off"
    )
    var progressLog: ProgressLogMode?

    @Option(
        name: .long,
        help: "Whisper audio encoder compute units; default \(TranscriptionDefaults.audioEncoderCompute.rawValue)"
    )
    var audioEncoderCompute: ComputeUnitsOption?

    @Option(
        name: .long,
        help: "Whisper text decoder compute units; default \(TranscriptionDefaults.textDecoderCompute.rawValue)"
    )
    var textDecoderCompute: ComputeUnitsOption?

    @Option(
        name: .long,
        help: "SpeakerKit segmenter compute units; default \(TranscriptionDefaults.segmenterCompute.rawValue)"
    )
    var segmenterCompute: ComputeUnitsOption?

    @Option(
        name: .long,
        help: "SpeakerKit embedder compute units; default \(TranscriptionDefaults.embedderCompute.rawValue)"
    )
    var embedderCompute: ComputeUnitsOption?
}

struct DirectoryInputOptions: ParsableArguments {
    @Option(
        name: [.customLong("sort"), .customLong("input-sort")],
        help: """
            Order for directory input: recorded (embedded creation timestamp; default), name (natural-sort filename), \
            mtime (file modification time). Default: \(TranscriptionDefaults.dirSort.rawValue).
            """
    )
    var sort: InputSortOrder?

    @Option(
        name: .long,
        help: """
            Split a directory input into separate transcripts at gaps larger than N minutes between consecutive recordings \
            (0 disables; default: \(TranscriptionDefaults.dirSessionGapMinutes)).
            """
    )
    var sessionGap: Int?

    @Option(
        name: .long,
        help: """
            When embedded recording times are missing or untrusted: auto (default, may recover from filename prefixes), \
            filename (same as auto), embedded (metadata only; no filename recovery), or off.
            """
    )
    var inputTimeSource: InputTimeSource?

    @Option(
        name: .long,
        help: "Session output basename style: auto (derive shared prefixes when possible), clip (disable prefix derivation), or off (same as clip)."
    )
    var sessionNaming: SessionNamingMode?
}
