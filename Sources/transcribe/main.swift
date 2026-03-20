import ArgumentParser
import Foundation
import SpeakerKit
import WhisperKit
#if canImport(Darwin)
import Darwin
#endif

@main
struct Transcribe: AsyncParsableCommand {
    static let version = "1.1.0"

    static var configuration = CommandConfiguration(
        abstract: "On-device meeting transcription with optional speaker diarization.",
        discussion: """
            Transcribes an audio file using WhisperKit and optionally adds speaker \
            labels using SpeakerKit. All processing runs on-device on Apple Silicon. \
            Output formats: txt, json, srt, vtt (use --format to select).
            """,
        version: version
    )

    @Argument(help: "Path to the input audio file")
    var audioFile: String

    @Option(name: [.short, .long], help: "Whisper model to use (default: auto-select for device)")
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

    @Option(name: [.short, .long], help: "Output formats, comma-separated: txt, json, srt, vtt, all")
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

    /// Resolved list of output formats (txt, json, srt, vtt).
    var resolvedFormats: [String] {
        let f = format.lowercased().trimmingCharacters(in: .whitespaces)
        if f == "all" {
            return ["txt", "json", "srt", "vtt"]
        }
        return f.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
    /// otherwise asks WhisperKit for the recommended model for this device.
    private func resolveModel(explicit: String?, logger: VerboseLogger) async throws -> String {
        if let explicit {
            logger.log("Using model: \(explicit)")
            return explicit
        }
        let recommended = WhisperKit.recommendedModels()
        let modelName = recommended.default
        logger.log("Auto-selected model: \(modelName)")
        return modelName
    }

    /// Validates options and combinations; invalid usage throws with exit code 2.
    private func validateUsage() throws {
        let formats = resolvedFormats
        let validFormats = Set(["txt", "json", "srt", "vtt"])
        for f in formats {
            if !validFormats.contains(f) {
                throw TranscribeError(
                    message: "Unsupported format '\(f)'. Supported: txt, json, srt, vtt, all.",
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

        if let min = minSpeakers, let max = maxSpeakers, min > max {
            throw TranscribeError(
                message: "--min-speakers (\(min)) must be less than or equal to --max-speakers (\(max)).",
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

        let resolvedModel = try await resolveModel(explicit: model, logger: logger)

        let historicalRatio: Double? = {
            guard timingStatsEnabled else { return nil }
            guard let recs = try? TimingStore.loadRecent(model: resolvedModel, diarizationEnabled: !noDiarize) else {
                return nil
            }
            return TimingStore.medianWallSecondsPerAudioSecond(records: recs)
        }()

        let basename = outputPrefix ?? outputBasename(audioPath: audioFile)
        try checkOverwrite(
            outputDir: outputDir,
            basename: basename,
            formats: resolvedFormats,
            writeTxtFile: wantsTxt && !stdout,
            overwrite: overwrite
        )

        let liveProgressMode: LiveProgressRenderMode? = {
            if debugProgressLog { return .lineLog(minInterval: 1.0) }
            if isStderrTTY() { return .tty }
            return nil
        }()
        let output: TranscriptionOutput
        var phases: PhaseTimings
        if noDiarize {
            let (out, ph) = try await runTranscriptionOnly(
                audioPath: audioFile,
                model: resolvedModel,
                modelDir: modelDir,
                language: language,
                computeOptions: computeOptions,
                verbose: verbose,
                wordTimestamps: false,
                liveProgressMode: liveProgressMode,
                pipelineStartDate: startDate,
                historicalWallSecondsPerAudioSecond: historicalRatio,
                logger: logger
            )
            output = out
            phases = ph
        } else {
            let strategy = SpeakerInfoStrategy(from: speakerStrategy) ?? .subsegment
            let (out, ph) = try await runTranscriptionWithDiarization(
                audioPath: audioFile,
                model: resolvedModel,
                modelDir: modelDir,
                language: language,
                minSpeakers: minSpeakers,
                maxSpeakers: maxSpeakers,
                speakerStrategy: strategy,
                computeOptions: computeOptions,
                verbose: verbose,
                liveProgressMode: liveProgressMode,
                pipelineStartDate: startDate,
                historicalWallSecondsPerAudioSecond: historicalRatio,
                logger: logger
            )
            output = out
            phases = ph
        }

        var out = output
        out.speakerStrategy = speakerStrategy
        for warning in out.warnings {
            emitWarning(warning)
        }

        let outputFiles = resolvedFormats.filter { fmt in fmt != "txt" || !stdout }.map { fmt in "\(basename).\(fmt)" }.joined(separator: ", ")
        let resolvedDir = resolvedOutputDir(outputDir)
        logger.log("Writing outputs to \(resolvedDir): \(outputFiles)")

        let (_, writeMs) = try WallClock.measureMs {
            try writeOutputs(
                output: out,
                audioPath: audioFile,
                outputDir: outputDir,
                basename: basename,
                formats: resolvedFormats,
                writeTxtToStdout: wantsTxt && stdout,
                overwrite: overwrite,
                model: resolvedModel,
                version: Self.version
            )
        }

        let endedAt = Date()
        let totalMs = Int64(endedAt.timeIntervalSince(startDate) * 1000.0)

        if timingStatsEnabled {
            let expanded = (audioFile as NSString).expandingTildeInPath
            let fileBytes = (try? FileManager.default.attributesOfItem(atPath: expanded)[.size] as? NSNumber)?.int64Value ?? 0
            let record = RunTimingRecord(
                endedAt: endedAt,
                transcribeVersion: Self.version,
                model: resolvedModel,
                diarizationEnabled: out.diarizationEnabled,
                inputBasename: (audioFile as NSString).lastPathComponent,
                fileBytes: fileBytes,
                audioDurationS: out.durationSeconds,
                segmentCount: out.segments.count,
                speakersDetected: out.speakersDetected,
                phases: phases,
                writeOutputsMs: writeMs,
                totalMs: totalMs
            )
            try? TimingStore.append(record)
        }

        let totalSec = Int(endedAt.timeIntervalSince(startDate))
        logger.log("Done. Total: \(totalSec / 60)m \(totalSec % 60)s")
    }
}
