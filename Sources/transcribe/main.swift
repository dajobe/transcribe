import ArgumentParser
import Foundation
import SpeakerKit
import WhisperKit
#if canImport(Darwin)
import Darwin
#endif

@main
struct Transcribe: AsyncParsableCommand {
    static let version = "0.1.0"

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

    @Option(name: [.short, .long], help: "Directory for output files (default: current directory)")
    var outputDir: String = "."

    @Option(name: [.short, .long], help: "Output formats, comma-separated: txt, json, srt, vtt, all (default: txt,json)")
    var format: String = "txt,json"

    @Flag(help: "Write the primary transcript to stdout instead of a text file")
    var stdout: Bool = false

    @Option(name: .long, help: "Minimum number of speakers for diarization")
    var minSpeakers: Int?

    @Option(name: .long, help: "Maximum number of speakers for diarization")
    var maxSpeakers: Int?

    @Flag(name: .long, help: "Disable diarization and produce transcript-only output")
    var noDiarize: Bool = false

    @Option(name: .long, help: "Speaker merge strategy: subsegment or segment (default: subsegment)")
    var speakerStrategy: String = "subsegment"

    @Option(name: .long, help: "Directory used for downloaded model caches (default: ~/.cache/transcribe)")
    var modelDir: String = "~/.cache/transcribe"

    @Flag(help: "Replace existing output files")
    var overwrite: Bool = false

    @Flag(name: .long, help: "Print progress, timing, and cache details to stderr")
    var verbose: Bool = false

    @Option(
        name: .long,
        help: "Compute units for the Whisper audio encoder: auto, all, cpuOnly, cpuAndGPU, cpuAndNeuralEngine (default: auto uses the recommended backend mix)"
    )
    var audioEncoderCompute: ComputeUnitsOption = .auto

    @Option(
        name: .long,
        help: "Compute units for the Whisper text decoder: auto, all, cpuOnly, cpuAndGPU, cpuAndNeuralEngine (default: auto uses the recommended backend mix)"
    )
    var textDecoderCompute: ComputeUnitsOption = .auto

    @Option(
        name: .long,
        help: "Compute units for the SpeakerKit segmenter: auto, all, cpuOnly, cpuAndGPU, cpuAndNeuralEngine (default: auto uses the recommended backend mix)"
    )
    var segmenterCompute: ComputeUnitsOption = .auto

    @Option(
        name: .long,
        help: "Compute units for the SpeakerKit embedder: auto, all, cpuOnly, cpuAndGPU, cpuAndNeuralEngine (default: auto uses the recommended backend mix)"
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

        let basename = outputBasename(audioPath: audioFile)
        try checkOverwrite(
            outputDir: outputDir,
            basename: basename,
            formats: resolvedFormats,
            writeTxtFile: wantsTxt && !stdout,
            overwrite: overwrite
        )

        let isTTY = isStderrTTY()
        let output: TranscriptionOutput
        if noDiarize {
            output = try await runTranscriptionOnly(
                audioPath: audioFile,
                model: resolvedModel,
                modelDir: modelDir,
                language: language,
                computeOptions: computeOptions,
                verbose: verbose,
                wordTimestamps: false,
                isTTY: isTTY,
                logger: logger
            )
        } else {
            let strategy = SpeakerInfoStrategy(from: speakerStrategy) ?? .subsegment
            output = try await runTranscriptionWithDiarization(
                audioPath: audioFile,
                model: resolvedModel,
                modelDir: modelDir,
                language: language,
                minSpeakers: minSpeakers,
                maxSpeakers: maxSpeakers,
                speakerStrategy: strategy,
                computeOptions: computeOptions,
                verbose: verbose,
                isTTY: isTTY,
                logger: logger
            )
        }

        var out = output
        out.speakerStrategy = speakerStrategy
        for warning in out.warnings {
            emitWarning(warning)
        }

        let outputFiles = resolvedFormats.filter { fmt in fmt != "txt" || !stdout }.map { fmt in "\(basename).\(fmt)" }.joined(separator: ", ")
        logger.log("Writing outputs: \(outputFiles)")

        try writeOutputs(
            output: out,
            audioPath: audioFile,
            outputDir: outputDir,
            formats: resolvedFormats,
            writeTxtToStdout: wantsTxt && stdout,
            overwrite: overwrite,
            model: resolvedModel,
            version: Self.version
        )

        let totalSec = Int(Date().timeIntervalSince(startDate))
        logger.log("Done. Total: \(totalSec / 60)m \(totalSec % 60)s")
    }
}
