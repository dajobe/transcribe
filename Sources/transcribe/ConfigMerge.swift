import Foundation

// MARK: - Resolved options (concrete, post-merge)

enum ConfigModelSource: Equatable {
    case cli
    case userFile
    case builtin
}

struct ResolvedSharedOptions {
    let model: String
    /// Where the effective model string came from (for stderr labelling).
    let modelSource: ConfigModelSource
    let language: String?
    let format: String
    let outputDir: String
    let outputPrefix: String?
    let modelDir: String
    let speakerMerge: String
    let minSpeakers: Int?
    let maxSpeakers: Int?
    let audioEncoderCompute: ComputeUnitsOption
    let textDecoderCompute: ComputeUnitsOption
    let segmenterCompute: ComputeUnitsOption
    let embedderCompute: ComputeUnitsOption
    let speakersEnabled: Bool
    let verbose: Bool
    let progressLogMode: ProgressLogMode
    let timingStatsPreference: Bool

    let stdout: Bool
    let overwrite: Bool
    let redo: Bool
    let stateless: Bool
    let markImported: Bool
    let dryRun: Bool
    let maxAudioMB: Int

    var audioLoadLimits: AudioLoadLimits {
        AudioLoadLimits(maxAudioMB: maxAudioMB)
    }

    var resolvedFormats: [String] {
        parseOutputFormats(format)
    }

    var wantsTxt: Bool {
        resolvedFormats.contains("txt")
    }

    var timingStatsEnabled: Bool {
        if Self.envDisablesEtaHints() { return false }
        return timingStatsPreference
    }

    /// When true, `TRANSCRIBE_ETA_HINTS=0` or legacy `TRANSCRIBE_TIMING_STATS=0` forces timing/ETA off.
    private static func envDisablesEtaHints() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if env["TRANSCRIBE_ETA_HINTS"] == "0" { return true }
        // Legacy name (pre-eta-hints CLI); keep so existing shells and Automator jobs keep working.
        if env["TRANSCRIBE_TIMING_STATS"] == "0" { return true }
        return false
    }
}

struct ResolvedDirectoryOptions: Equatable {
    let sort: InputSortOrder
    let sessionGap: Int
    let inputTimeSource: InputTimeSource
    let sessionNaming: SessionNamingMode

    var filenameTimeRecovery: Bool { inputTimeSource.filenameRecoveryEnabled }
    var autoSessionBasename: Bool { sessionNaming.autoSessionBasenameEnabled }
}

struct ResolvedVoiceMemosOptions: Equatable {
    let recordingsDir: String
    let sessionGap: Int
}

// MARK: - Merge

enum ConfigMerge {
    static func loadUserFile() throws -> UserConfigFile {
        let url = try ConfigPaths.configFileURL()
        return try UserConfigFile.loadOrEmpty(from: url)
    }

    static func mergeShared(cli: SharedTranscriptionOptions, file: UserConfigFile) throws -> ResolvedSharedOptions {
        try cli.validateTriStatePairs()

        let (model, modelSource): (String, ConfigModelSource) = {
            if let m = cli.model { return (m, .cli) }
            if let m = file.model { return (m, .userFile) }
            return (TranscriptionDefaults.defaultModel, .builtin)
        }()

        let language = cli.language ?? file.language
        let outputPrefix = cli.outputPrefix ?? file.output?.prefix

        let format = cli.format ?? file.format ?? TranscriptionDefaults.format
        let outputDir = cli.outputDir ?? file.output?.dir ?? TranscriptionDefaults.outputDir
        let modelDir = cli.modelDir ?? file.cache?.modelDir ?? TranscriptionDefaults.modelDir
        let speakerMerge = cli.speakerMerge ?? file.speakers?.merge ?? TranscriptionDefaults.speakerMerge

        let minSpeakers = cli.speakersMin ?? file.speakers?.min
        let maxSpeakers = cli.speakersMax ?? file.speakers?.max

        let audioEncoderCompute = try mergeCompute(
            cli: cli.audioEncoderCompute,
            file: file.compute?.audioEncoder,
            def: TranscriptionDefaults.audioEncoderCompute
        )
        let textDecoderCompute = try mergeCompute(
            cli: cli.textDecoderCompute,
            file: file.compute?.textDecoder,
            def: TranscriptionDefaults.textDecoderCompute
        )
        let segmenterCompute = try mergeCompute(
            cli: cli.segmenterCompute,
            file: file.compute?.segmenter,
            def: TranscriptionDefaults.segmenterCompute
        )
        let embedderCompute = try mergeCompute(
            cli: cli.embedderCompute,
            file: file.compute?.embedder,
            def: TranscriptionDefaults.embedderCompute
        )

        let verboseTri = try cli.triVerbose()
        let speakersTri = try cli.triSpeakers()
        let etaHintsTri = cli.triEtaHints()

        let verbose = verboseTri.merged(file: file.logging?.verbose, default: TranscriptionDefaults.verbose)
        let speakersEnabled = speakersTri.merged(file: file.speakers?.enabled, default: TranscriptionDefaults.speakersEnabled)
        let timingStatsPreference = etaHintsTri.merged(file: file.logging?.etaHints, default: TranscriptionDefaults.etaHintsEnabled)

        let progressLogMode = try mergeProgressLog(cli: cli.progressLog, file: file.logging?.progressLog)

        let maxAudioMB = cli.maxAudioMB ?? file.input?.maxAudioMB ?? TranscriptionDefaults.maxAudioMB

        return ResolvedSharedOptions(
            model: model,
            modelSource: modelSource,
            language: language,
            format: format,
            outputDir: outputDir,
            outputPrefix: outputPrefix,
            modelDir: modelDir,
            speakerMerge: speakerMerge,
            minSpeakers: minSpeakers,
            maxSpeakers: maxSpeakers,
            audioEncoderCompute: audioEncoderCompute,
            textDecoderCompute: textDecoderCompute,
            segmenterCompute: segmenterCompute,
            embedderCompute: embedderCompute,
            speakersEnabled: speakersEnabled,
            verbose: verbose,
            progressLogMode: progressLogMode,
            timingStatsPreference: timingStatsPreference,
            stdout: cli.stdout,
            overwrite: cli.overwrite,
            redo: cli.redo,
            stateless: cli.stateless,
            markImported: cli.markImported,
            dryRun: cli.dryRun,
            maxAudioMB: maxAudioMB
        )
    }

    private static func mergeProgressLog(cli: ProgressLogMode?, file: String?) throws -> ProgressLogMode {
        if let cli { return cli }
        if let file, !file.isEmpty {
            guard let mode = ProgressLogMode(rawValue: file) else {
                throw TranscribeError(
                    message: "Invalid logging.progressLog '\(file)' (expected auto, plain, or off).",
                    exitCode: .invalidUsage
                )
            }
            return mode
        }
        return TranscriptionDefaults.progressLogMode
    }

    private static func mergeCompute(
        cli: ComputeUnitsOption?,
        file: String?,
        def: ComputeUnitsOption
    ) throws -> ComputeUnitsOption {
        if let cli { return cli }
        if let file, !file.isEmpty {
            guard let v = ComputeUnitsOption(rawValue: file) else {
                throw TranscribeError(
                    message: "Invalid compute units value '\(file)'.",
                    exitCode: .invalidUsage
                )
            }
            return v
        }
        return def
    }

    private static func mergeInputTimeSource(cli: InputTimeSource?, file: String?) throws -> InputTimeSource {
        if let cli { return cli }
        if let file, !file.isEmpty {
            guard let v = InputTimeSource(rawValue: file) else {
                throw TranscribeError(
                    message: "Invalid dir.inputTimeSource '\(file)' (expected auto, embedded, filename, or off).",
                    exitCode: .invalidUsage
                )
            }
            return v
        }
        return TranscriptionDefaults.dirInputTimeSource
    }

    private static func mergeSessionNaming(cli: SessionNamingMode?, file: String?) throws -> SessionNamingMode {
        if let cli { return cli }
        if let file, !file.isEmpty {
            guard let v = SessionNamingMode(rawValue: file) else {
                throw TranscribeError(
                    message: "Invalid dir.sessionNaming '\(file)' (expected auto, clip, or off).",
                    exitCode: .invalidUsage
                )
            }
            return v
        }
        return TranscriptionDefaults.dirSessionNaming
    }

    static func mergeDirectory(cli: DirectoryInputOptions, file: UserConfigFile) throws -> ResolvedDirectoryOptions {
        let sort: InputSortOrder
        if let s = cli.sort {
            sort = s
        } else if let raw = file.dir?.sort, !raw.isEmpty {
            guard let parsed = InputSortOrder(rawValue: raw) else {
                throw TranscribeError(
                    message: "Invalid dir.sort value '\(raw)'.",
                    exitCode: .invalidUsage
                )
            }
            sort = parsed
        } else {
            sort = TranscriptionDefaults.dirSort
        }

        let sessionGap: Int = {
            if let g = cli.sessionGap { return g }
            if let g = file.dir?.sessionGap { return g }
            return TranscriptionDefaults.dirSessionGapMinutes
        }()

        let inputTime = try mergeInputTimeSource(cli: cli.inputTimeSource, file: file.dir?.inputTimeSource)
        let sessionNaming = try mergeSessionNaming(cli: cli.sessionNaming, file: file.dir?.sessionNaming)

        return ResolvedDirectoryOptions(
            sort: sort,
            sessionGap: sessionGap,
            inputTimeSource: inputTime,
            sessionNaming: sessionNaming
        )
    }

    static func mergeVoiceMemos(cli: VoiceMemosSourceArguments, file: UserConfigFile) -> ResolvedVoiceMemosOptions {
        let recordingsDir = cli.recordingsDir ?? file.voiceMemos?.recordingsDir ?? TranscriptionDefaults.voiceMemosRecordingsDir
        let sessionGap = cli.sessionGap ?? file.voiceMemos?.sessionGap ?? TranscriptionDefaults.voiceMemosSessionGapMinutes
        return ResolvedVoiceMemosOptions(recordingsDir: recordingsDir, sessionGap: sessionGap)
    }
}

extension SharedTranscriptionOptions {
    func validateTriStatePairs() throws {
        _ = try triVerbose()
        _ = try triSpeakers()
        _ = triEtaHints()
    }

    func triVerbose() throws -> TriState<Bool> {
        try TriState.from(enable: verbose, disable: quiet, enableLabel: "--verbose", disableLabel: "--quiet")
    }

    func triSpeakers() throws -> TriState<Bool> {
        try TriState.from(
            enable: withSpeakers,
            disable: transcriptOnly,
            enableLabel: "--with-speakers",
            disableLabel: "--transcript-only"
        )
    }

    func triEtaHints() -> TriState<Bool> {
        if let etaHints {
            return .value(etaHints == .on)
        }
        return .omitted
    }
}
