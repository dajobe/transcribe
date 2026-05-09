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

struct VoiceMemosSourceArguments: ParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "voice-memos",
        abstract: "Import synced Apple Voice Memos directly from the local database and audio files.",
        usage: "transcribe [<global-options>] voice-memos [<voice-memos-options>]",
        discussion: "Run `transcribe --help` to see global model, output, diarization, idempotency, timing, and compute options."
    )

    @Option(name: .long, help: "Voice Memos recordings directory containing CloudRecordings.db.")
    var recordingsDir: String = VoiceMemosImport.defaultRecordingsDirectory

    @Option(
        name: .long,
        help: "Split Voice Memos into separate transcripts at gaps larger than N minutes between recordings (0 disables; default: 10)"
    )
    var sessionGap: Int = 10
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
        case "file":
            try await runFile(args)
        case "dir":
            try await runDirectory(args)
        case "voice-memos":
            try await runVoiceMemos(args)
        default:
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
        try await PipelineRunner(
            request: .file(path: source.audioFile),
            options: options
        ).run()
    }

    private func runDirectory(_ args: [String]) async throws {
        if isHelpRequest(args) {
            printHelp(DirSourceArguments.helpMessage())
            return
        }
        let source = try parse(DirSourceArguments.self, args)
        try SourcePlanner.validateDirectoryPath(source.directory)
        try await PipelineRunner(
            request: .directory(path: source.directory, options: source.options),
            options: options
        ).run()
    }

    private func runVoiceMemos(_ args: [String]) async throws {
        if isHelpRequest(args) {
            printHelp(VoiceMemosSourceArguments.helpMessage())
            return
        }
        let source = try parse(VoiceMemosSourceArguments.self, args)
        try await PipelineRunner(
            request: .voiceMemos(recordingsDir: source.recordingsDir, sessionGap: source.sessionGap),
            options: options
        ).run()
    }

    private func runRootAlias(path: String, remaining: [String]) async throws {
        guard remaining.isEmpty else {
            throw TranscribeError(
                message: "Unexpected argument(s) after root path alias: \(remaining.joined(separator: " ")). Put global options before the path, or use `transcribe dir` for directory-specific options.",
                exitCode: .invalidUsage
            )
        }

        let mode = try SourcePlanner.modeForAliasPath(path)
        let request: PipelineRequest
        switch mode {
        case .file:
            request = .file(path: path)
        case .directory:
            request = .directory(path: path, options: try DirectoryInputOptions.parse([]))
        case .voiceMemos:
            preconditionFailure("Root alias cannot resolve to Voice Memos")
        }
        try await PipelineRunner(request: request, options: options).run()
    }

    private func printSourceHelp(_ args: [String]) throws {
        guard args.count == 1 else {
            throw TranscribeError(
                message: "Use `transcribe file --help`, `transcribe dir --help`, or `transcribe voice-memos --help`.",
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

        Examples:
          transcribe file meeting.m4a
          transcribe dir ~/Recordings
          transcribe voice-memos --session-gap 10

        For all global options, run:        transcribe --help
        For source-specific options, run:   transcribe <source> --help
        """
    }
}

struct SharedTranscriptionOptions: ParsableArguments {
    @Option(
        name: [.short, .long],
        help: ArgumentHelp(
            "Whisper model to use (default: \(Transcribe.defaultModel); first run downloads ~1.5 GB to the model cache directory)"
        )
    )
    var model: String?

    @Option(name: [.short, .long], help: "Language code such as \"en\"; default is auto-detect")
    var language: String?

    @Option(
        name: [.short, .long],
        help: "Directory for output files. ~ expands to your home directory (not /tmp)."
    )
    var outputDir: String = "."

    @Option(name: .long, help: "Output file prefix (default: input filename without extension)")
    var outputPrefix: String?

    @Option(name: [.short, .long], help: "Output formats, comma-separated: txt, json, srt, vtt, md, all")
    var format: String = "txt,json"

    @Flag(help: "Write the primary transcript to stdout instead of a text file")
    var stdout: Bool = false

    @Option(name: .long, help: "Minimum number of speakers for diarization")
    var minSpeakers: Int?

    @Option(name: .long, help: "Maximum number of speakers for diarization")
    var maxSpeakers: Int?

    @Flag(name: .long, help: "Disable diarization and produce transcript-only output")
    var noDiarize: Bool = false

    @Option(name: .long, help: "Speaker merge strategy: subsegment or segment")
    var speakerStrategy: String = "subsegment"

    @Option(name: .long, help: "Directory used for downloaded model caches")
    var modelDir: String = "~/.cache/transcribe"

    @Flag(help: "Replace existing output files")
    var overwrite: Bool = false

    @Flag(name: .long, help: "Reprocess inputs even when processing history says they were already completed")
    var redo: Bool = false

    @Flag(name: .long, help: "Do not use or write idempotent processing history")
    var noProcessingState: Bool = false

    @Flag(
        name: .long,
        help: "Mark planned inputs as already imported without transcribing them. Future runs skip them on source identity and content fingerprint alone, regardless of model, format, or other settings."
    )
    var markImported: Bool = false

    @Flag(name: .long, help: "Show what would be processed or skipped without loading models, writing outputs, or updating processing history")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Print progress, timing, and cache details to stderr")
    var verbose: Bool = false

    @Flag(name: .long, help: "Do not record timing statistics or use prior runs for ETA hints")
    var noTimingStats: Bool = false

    @Flag(
        name: .long,
        help: "Log progress/ETA as plain stderr lines (throttled to ~1/s) for testing without a TTY; use with a pipe or file"
    )
    var debugProgressLog: Bool = false

    @Option(
        name: .long,
        help: "Whisper audio encoder compute units; auto selects the recommended backend mix"
    )
    var audioEncoderCompute: ComputeUnitsOption = .auto

    @Option(
        name: .long,
        help: "Whisper text decoder compute units; auto selects the recommended backend mix"
    )
    var textDecoderCompute: ComputeUnitsOption = .auto

    @Option(
        name: .long,
        help: "SpeakerKit segmenter compute units; auto selects the recommended backend mix"
    )
    var segmenterCompute: ComputeUnitsOption = .auto

    @Option(
        name: .long,
        help: "SpeakerKit embedder compute units; auto selects the recommended backend mix"
    )
    var embedderCompute: ComputeUnitsOption = .auto

    var resolvedFormats: [String] {
        parseOutputFormats(format)
    }

    var wantsTxt: Bool {
        resolvedFormats.contains("txt")
    }

    var timingStatsEnabled: Bool {
        if noTimingStats { return false }
        if ProcessInfo.processInfo.environment["TRANSCRIBE_TIMING_STATS"] == "0" { return false }
        return true
    }
}

struct DirectoryInputOptions: ParsableArguments {
    @Option(
        name: [.customLong("sort"), .customLong("input-sort")],
        help: "Order for directory input: recorded (embedded creation timestamp; default), name (natural-sort filename), mtime (file modification time)"
    )
    var sort: InputSortOrder = .recorded

    @Option(
        name: .long,
        help: "Split a directory input into separate transcripts at gaps larger than N minutes between consecutive recordings (0 disables; default: 10)"
    )
    var sessionGap: Int = 10

    @Flag(name: .long, inversion: .prefixedNo, help: "Recover recording times from filename prefixes when embedded recorded dates are missing or untrusted")
    var filenameTimeRecovery: Bool = true

    @Flag(name: .long, inversion: .prefixedNo, help: "Derive session output basenames from common filename prefixes")
    var autoSessionBasename: Bool = true
}
