import ArgumentParser
import Foundation
import SpeakerKit
import WhisperKit
#if canImport(Darwin)
import Darwin
#endif

@main
struct Transcribe: AsyncParsableCommand {
    // When bumping this, run `make tag` (or `make release`) immediately
    // afterwards so the matching `vX.Y.Z` annotated tag lands with the
    // version-bump commit. See README "Releasing" and AGENTS.md.
    static let version = "1.7.0"

    /// Default Whisper model when `--model` is not supplied.
    /// `openai_whisper-large-v3_turbo` is the strongest model that runs at
    /// usable speed on Apple Silicon with the Neural Engine; the previously
    /// auto-selected `openai_whisper-base` produced poor results on real-world
    /// noisy or far-field audio (meetings, conferences, voice notes).
    /// Override with `--model <name>`.
    static let defaultModel = "openai_whisper-large-v3_turbo"

    static var configuration = CommandConfiguration(
        abstract: "On-device meeting transcription with optional speaker diarization.",
        discussion: """
            Transcribes an audio file using WhisperKit and optionally adds speaker \
            labels using SpeakerKit. All processing runs on-device on Apple Silicon. \
            Output formats: txt, json, srt, vtt, md (use --format to select).
            """,
        version: version
    )

    @Argument(help: "Path to an audio file, or a directory of audio clips to be concatenated and transcribed as one recording (top-level only, natural-sorted by filename)")
    var audioFile: String

    @Option(
        name: [.short, .long],
        help: ArgumentHelp(
            "Whisper model to use (default: \(Self.defaultModel); first run downloads ~1.5 GB to the model cache directory)"
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

    @Option(
        name: .long,
        help: "Order for directory input: recorded (embedded creation timestamp; default), name (natural-sort filename), mtime (file modification time)"
    )
    var inputSort: InputSortOrder = .recorded

    @Option(
        name: .long,
        help: "Split a directory input into separate transcripts at gaps larger than N minutes between consecutive recordings (0 disables; default: 10)"
    )
    var sessionGap: Int = 10

    @Flag(
        name: .long,
        help: "Disable filename time-prefix recovery; when the embedded recorded-date trust check fails, fall back to filename sort with session splitting disabled (1.5.0 behaviour)"
    )
    var noFilenameTimeRecovery: Bool = false

    @Flag(
        name: .long,
        help: "Disable common-prefix session basename derivation; always use \"<directory> - Recording N\" for multi-session output filenames (1.5.0 behaviour)"
    )
    var noAutoSessionBasename: Bool = false

    @Option(name: .long, help: "Directory used for downloaded model caches")
    var modelDir: String = "~/.cache/transcribe"

    @Flag(help: "Replace existing output files")
    var overwrite: Bool = false

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

    /// Resolved list of output formats (txt, json, srt, vtt, md).
    var resolvedFormats: [String] {
        parseOutputFormats(format)
    }

    /// True if txt is among requested output formats.
    var wantsTxt: Bool {
        resolvedFormats.contains("txt")
    }

    /// Timing history for ETA (unless `--no-timing-stats` or `TRANSCRIBE_TIMING_STATS=0`).
    private var timingStatsEnabled: Bool {
        if noTimingStats { return false }
        if ProcessInfo.processInfo.environment["TRANSCRIBE_TIMING_STATS"] == "0" { return false }
        return true
    }

    func run() async throws {
        do {
            try validateUsage()
            try await runPipeline()
        } catch let e as TranscribeError {
            FileHandle.standardError.write((e.message + "\n").data(using: .utf8)!)
            Darwin.exit(e.exitCode.rawValue)
        } catch let e as WhisperError {
            FileHandle.standardError.write((e.localizedDescription + "\n").data(using: .utf8)!)
            Darwin.exit(ExitCode.modelFailure.rawValue)
        } catch {
            FileHandle.standardError.write((error.localizedDescription + "\n").data(using: .utf8)!)
            Darwin.exit(ExitCode.runtimeFailure.rawValue)
        }
    }

    /// Resolves the whisper model name: uses explicit value if provided,
    /// otherwise picks `Self.defaultModel`. Always announces the chosen model
    /// on stderr (even outside verbose mode) so users see what the run is
    /// actually using — first-run downloads can be ~1.5 GB.
    private func resolveModel(explicit: String?, logger: VerboseLogger) async throws -> String {
        let chosen = explicit ?? Self.defaultModel
        let label = (explicit == nil) ? "Auto-selected model" : "Using model"
        FileHandle.standardError.write("\(label): \(chosen)\n".data(using: .utf8)!)
        return chosen
    }

    /// Validates options and combinations; invalid usage throws with exit code 2.
    private func validateUsage() throws {
        let formats = resolvedFormats
        if formats.isEmpty {
            throw TranscribeError(
                message: "--format must include at least one of: txt, json, srt, vtt, md, all.",
                exitCode: .invalidUsage
            )
        }
        for f in formats {
            if !validOutputFormats.contains(f) {
                throw TranscribeError(
                    message: "Unsupported format '\(f)'. Supported: txt, json, srt, vtt, md, all.",
                    exitCode: .invalidUsage
                )
            }
        }

        let strategy = speakerStrategy.lowercased()
        if strategy != "subsegment" && strategy != "segment" {
            throw TranscribeError(
                message: "--speaker-strategy must be 'subsegment' or 'segment'.",
                exitCode: .invalidUsage
            )
        }

        if stdout && !wantsTxt {
            throw TranscribeError(
                message: "--stdout is only valid when txt is requested (e.g. --format txt,json or --format all).",
                exitCode: .invalidUsage
            )
        }

        if noDiarize && (minSpeakers != nil || maxSpeakers != nil) {
            throw TranscribeError(
                message: "--min-speakers and --max-speakers are only valid when diarization is enabled.",
                exitCode: .invalidUsage
            )
        }

        if let min = minSpeakers, min <= 0 {
            throw TranscribeError(
                message: "--min-speakers must be greater than 0.",
                exitCode: .invalidUsage
            )
        }

        if let max = maxSpeakers, max <= 0 {
            throw TranscribeError(
                message: "--max-speakers must be greater than 0.",
                exitCode: .invalidUsage
            )
        }

        if let min = minSpeakers, let max = maxSpeakers, min > max {
            throw TranscribeError(
                message: "--min-speakers (\(min)) must be less than or equal to --max-speakers (\(max)).",
                exitCode: .invalidUsage
            )
        }

        if sessionGap < 0 {
            throw TranscribeError(
                message: "--session-gap must be >= 0 (use 0 to disable session splitting).",
                exitCode: .invalidUsage
            )
        }
    }

    private func runPipeline() async throws {
        let startDate = Date()
        let logger = VerboseLogger(verbose: verbose, startDate: startDate)
        let computeOptions = RuntimeComputeOptions.resolve(
            audioEncoder: audioEncoderCompute,
            textDecoder: textDecoderCompute,
            segmenter: segmenterCompute,
            embedder: embedderCompute
        )

        let sessionGapSeconds = Double(sessionGap) * 60.0
        let resolvedInput = try await InputResolver.resolve(
            audioFile,
            sort: inputSort,
            sessionGapSeconds: sessionGapSeconds,
            filenameTimeRecovery: !noFilenameTimeRecovery,
            logger: logger
        )
        if case .directory(_, let sessions) = resolvedInput {
            let totalClips = sessions.reduce(0) { $0 + $1.files.count }
            logger.log(
                "Input is a directory: \(totalClips) audio file\(totalClips == 1 ? "" : "s"), "
                + "\(sessions.count) session\(sessions.count == 1 ? "" : "s") "
                + "(sort=\(inputSort.rawValue), session-gap=\(sessionGap)m)"
            )
        }

        let resolvedModel = try await resolveModel(explicit: model, logger: logger)

        let historicalRatio: Double? = {
            guard timingStatsEnabled else { return nil }
            guard let recs = try? TimingStore.loadRecent(model: resolvedModel, diarizationEnabled: !noDiarize) else {
                return nil
            }
            return TimingStore.medianWallSecondsPerAudioSecond(records: recs)
        }()

        let sessions = InputResolver.sessions(for: resolvedInput)
        let basenames = InputResolver.sessionBasenames(
            for: resolvedInput,
            prefixOverride: outputPrefix,
            autoSessionBasename: !noAutoSessionBasename
        )
        for basename in basenames {
            try checkOverwrite(
                outputDir: outputDir,
                basename: basename,
                formats: resolvedFormats,
                writeTxtFile: wantsTxt && !stdout,
                overwrite: overwrite
            )
        }

        let liveProgressMode: LiveProgressRenderMode? = {
            if debugProgressLog { return .lineLog(minInterval: 1.0) }
            if isStderrTTY() { return .tty }
            return nil
        }()

        let strategy = SpeakerInfoStrategy(from: speakerStrategy) ?? .subsegment

        let (models, whisperInitMs, speakerInitMs) = try await loadModels(
            model: resolvedModel,
            modelDir: modelDir,
            diarize: !noDiarize,
            computeOptions: computeOptions,
            verbose: verbose,
            logger: logger
        )

        let resolvedDir = resolvedOutputDir(outputDir)

        for (idx, session) in sessions.enumerated() {
            let sessionStartDate = Date()
            let basename = basenames[idx]
            if sessions.count > 1 {
                logger.log("--- Session \(idx + 1)/\(sessions.count): \(basename) (\(session.files.count) clip\(session.files.count == 1 ? "" : "s")) ---")
            }

            let (preparedAudio, loadMs): (PreparedAudio, Int64)
            switch resolvedInput {
            case .file:
                (preparedAudio, loadMs) = try WallClock.measureMs {
                    try loadPreparedAudio(audioPath: session.files[0], logger: logger)
                }
            case .directory:
                (preparedAudio, loadMs) = try WallClock.measureMs {
                    try loadPreparedAudio(fromFiles: session.files, logger: logger)
                }
            }

            let (sessionOutput, sessionPhases) = try await runSession(
                preparedAudio: preparedAudio,
                audioLoadMs: loadMs,
                models: models,
                language: language,
                minSpeakers: minSpeakers,
                maxSpeakers: maxSpeakers,
                speakerStrategy: strategy,
                wordTimestamps: false,
                liveProgressMode: liveProgressMode,
                pipelineStartDate: startDate,
                historicalWallSecondsPerAudioSecond: historicalRatio,
                logger: logger
            )

            var out = sessionOutput
            out.speakerStrategy = speakerStrategy
            for warning in out.warnings {
                emitWarning(warning)
            }

            let audioFilesForOutput: [String]? = {
                if case .directory = resolvedInput {
                    return session.files.map { ($0 as NSString).lastPathComponent }
                }
                return nil
            }()
            let audioPathForOutput: String = {
                if case .directory(let dirPath, _) = resolvedInput { return dirPath }
                return session.files[0]
            }()

            let outputFiles = resolvedFormats.filter { fmt in fmt != "txt" || !stdout }.map { fmt in "\(basename).\(fmt)" }.joined(separator: ", ")
            logger.log("Writing outputs to \(resolvedDir): \(outputFiles)")

            let (_, writeMs) = try WallClock.measureMs {
                try writeOutputs(
                    output: out,
                    audioPath: audioPathForOutput,
                    audioFiles: audioFilesForOutput,
                    outputDir: outputDir,
                    basename: basename,
                    formats: resolvedFormats,
                    writeTxtToStdout: wantsTxt && stdout,
                    overwrite: overwrite,
                    model: resolvedModel,
                    version: Self.version
                )
            }

            if timingStatsEnabled {
                let fileBytes: Int64 = session.files.reduce(into: Int64(0)) { total, p in
                    let n = (try? FileManager.default.attributesOfItem(atPath: p)[.size] as? NSNumber)?.int64Value ?? 0
                    total += n
                }
                // Init costs are charged to the first session only — subsequent
                // sessions reuse the same Whisper/SpeakerKit instances.
                var phasesForRecord = sessionPhases
                if idx == 0 {
                    phasesForRecord.whisperInitMs = whisperInitMs
                    phasesForRecord.speakerInitMs = speakerInitMs
                }
                let endedAt = Date()
                let timingStartDate = (idx == 0) ? startDate : sessionStartDate
                let totalMs = Int64(endedAt.timeIntervalSince(timingStartDate) * 1000.0)
                let record = RunTimingRecord(
                    endedAt: endedAt,
                    transcribeVersion: Self.version,
                    model: resolvedModel,
                    diarizationEnabled: out.diarizationEnabled,
                    inputBasename: basename,
                    fileBytes: fileBytes,
                    audioDurationS: out.durationSeconds,
                    segmentCount: out.segments.count,
                    speakersDetected: out.speakersDetected,
                    phases: phasesForRecord,
                    writeOutputsMs: writeMs,
                    totalMs: totalMs
                )
                try? TimingStore.append(record)
            }
        }

        let endedAt = Date()
        let totalSec = Int(endedAt.timeIntervalSince(startDate))
        logger.log("Done. Total: \(totalSec / 60)m \(totalSec % 60)s")
    }
}
