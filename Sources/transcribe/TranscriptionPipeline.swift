import Foundation
import SpeakerKit
import WhisperKit

struct PreparedAudio {
    let samples: [Float]
    let durationSeconds: Double
}

/// Converts WhisperKit [TranscriptionResult] to our [TranscriptSegment].
func segmentsFromTranscriptionResults(_ results: [TranscriptionResult]) -> [TranscriptSegment] {
    results.flatMap { result in
        result.segments.map { seg in
            let words: [WordSegment]? = seg.words.map { wt in
                wt.map { WordSegment(word: $0.word, start: Double($0.start), end: Double($0.end)) }
            }
            return TranscriptSegment(
                speaker: nil,
                start: Double(seg.start),
                end: Double(seg.end),
                text: seg.text,
                words: words
            )
        }
    }
}

func loadPreparedAudio(audioPath: String, logger: VerboseLogger? = nil) throws -> PreparedAudio {
    logger?.log("Loading audio: \((audioPath as NSString).lastPathComponent)")
    let audioArray = try AudioLoader.loadAudio(fromPath: audioPath)
    let durationSeconds = Double(audioArray.count) / Double(WhisperKit.sampleRate)
    logger?.log("Audio loaded (\(String(format: "%.1f", durationSeconds))s, 16kHz mono)")
    return PreparedAudio(samples: audioArray, durationSeconds: durationSeconds)
}

func initializeWhisperKit(
    model: String,
    modelDir: String,
    computeOptions: RuntimeComputeOptions,
    verbose: Bool,
    logger: VerboseLogger? = nil
) async throws -> WhisperKit {
    let expandedModelDir = (modelDir as NSString).expandingTildeInPath
    let modelDirURL = URL(fileURLWithPath: expandedModelDir)
    func makeConfig(_ selectedCompute: ModelComputeOptions) -> WhisperKitConfig {
        WhisperKitConfig(
            model: model,
            downloadBase: modelDirURL,
            computeOptions: selectedCompute,
            verbose: verbose,
            load: true,
            download: true
        )
    }

    logger?.log("Using model cache: \(expandedModelDir)")
    let preferredConfig = makeConfig(computeOptions.whisperPreferred)
    do {
        let whisperKit = try await WhisperKit(preferredConfig)
        logger?.log("Selected WhisperKit compute: \(RuntimeComputeOptions.whisperSummary(computeOptions.whisperPreferred))")
        return whisperKit
    } catch {
        if let fallback = computeOptions.whisperFallback {
            logger?.log("WhisperKit could not use preferred GPU/Metal compute (\(error.localizedDescription)); falling back.")
            do {
                let whisperKit = try await WhisperKit(makeConfig(fallback))
                logger?.log("Selected WhisperKit compute: \(RuntimeComputeOptions.whisperSummary(fallback))")
                return whisperKit
            } catch {
                throw TranscribeError(
                    message: "Model initialization failed after GPU/Metal fallback: \(error.localizedDescription)",
                    exitCode: .modelFailure
                )
            }
        }

        logger?.log("Model load failed, retrying once...")
        do {
            let whisperKit = try await WhisperKit(preferredConfig)
            logger?.log("Selected WhisperKit compute: \(RuntimeComputeOptions.whisperSummary(computeOptions.whisperPreferred))")
            return whisperKit
        } catch {
            throw TranscribeError(
                message: "Model initialization failed after retry: \(error.localizedDescription)",
                exitCode: .modelFailure
            )
        }
    }
}

func initializeSpeakerKit(
    modelDir: String,
    computeOptions: RuntimeComputeOptions,
    verbose: Bool,
    logger: VerboseLogger? = nil
) async throws -> SpeakerKit {
    let expandedModelDir = (modelDir as NSString).expandingTildeInPath
    let speakerConfig = PyannoteConfig(
        downloadBase: URL(fileURLWithPath: expandedModelDir),
        modelFolder: nil,
        download: true,
        verbose: verbose
    )

    func loadSpeakerKit(using selectedCompute: RuntimeComputeOptions.SpeakerComputeOptions) async throws -> SpeakerKit {
        let speakerManager = SpeakerKitModelManager(
            config: speakerConfig,
            segmenterModelInfo: .segmenter(computeUnits: selectedCompute.segmenter),
            embedderModelInfo: .embedder(computeUnits: selectedCompute.embedder)
        )
        if speakerConfig.download {
            try await speakerManager.downloadModels()
        }
        try await speakerManager.loadModels()
        guard let models = speakerManager.models as? PyannoteModels else {
            throw SpeakerKitError.modelUnavailable("Failed to load SpeakerKit models")
        }
        return try SpeakerKit(models: models)
    }

    do {
        let speakerKit = try await loadSpeakerKit(using: computeOptions.speakerPreferred)
        logger?.log("Selected SpeakerKit compute: \(computeOptions.speakerPreferred.summary)")
        return speakerKit
    } catch {
        if let fallback = computeOptions.speakerFallback {
            logger?.log("SpeakerKit could not use preferred GPU/Metal compute (\(error.localizedDescription)); falling back.")
            do {
                let speakerKit = try await loadSpeakerKit(using: fallback)
                logger?.log("Selected SpeakerKit compute: \(fallback.summary)")
                return speakerKit
            } catch {
                throw TranscribeError(
                    message: "SpeakerKit initialization failed after GPU/Metal fallback: \(error.localizedDescription). Use --no-diarize for transcript-only.",
                    exitCode: .modelFailure
                )
            }
        }

        logger?.log("SpeakerKit load failed, retrying once...")
        do {
            let speakerKit = try await loadSpeakerKit(using: computeOptions.speakerPreferred)
            logger?.log("Selected SpeakerKit compute: \(computeOptions.speakerPreferred.summary)")
            return speakerKit
        } catch {
            throw TranscribeError(
                message: "SpeakerKit initialization failed: \(error.localizedDescription). Use --no-diarize for transcript-only.",
                exitCode: .modelFailure
            )
        }
    }
}

func buildTranscriptionOutput(
    from results: [TranscriptionResult],
    durationSeconds: Double,
    diarizationEnabled: Bool
) -> TranscriptionOutput {
    let segments = segmentsFromTranscriptionResults(results)
    var warnings: [String] = []
    if segments.isEmpty {
        warnings.append("No speech detected; output contains no segments.")
    }

    return TranscriptionOutput(
        segments: segments,
        language: results.first?.language,
        durationSeconds: durationSeconds,
        diarizationEnabled: diarizationEnabled,
        warnings: warnings
    )
}

func runTranscriptionOnly(
    audioArray: [Float],
    durationSeconds: Double,
    model: String,
    modelDir: String,
    language: String?,
    computeOptions: RuntimeComputeOptions,
    verbose: Bool,
    wordTimestamps: Bool = false,
    liveProgressMode: LiveProgressRenderMode? = nil,
    pipelineStartDate: Date,
    historicalWallSecondsPerAudioSecond: Double?,
    logger: VerboseLogger? = nil
) async throws -> (TranscriptionOutput, PhaseTimings) {
    var phases = PhaseTimings()
    let (whisperKit, wMs) = try await WallClock.measureMs {
        try await initializeWhisperKit(
            model: model,
            modelDir: modelDir,
            computeOptions: computeOptions,
            verbose: verbose,
            logger: logger
        )
    }
    phases.whisperInitMs = wMs

    var decodeOptions = DecodingOptions(
        wordTimestamps: wordTimestamps,
        chunkingStrategy: .vad
    )
    if let lang = language, !lang.isEmpty {
        decodeOptions.language = lang
    }

    let liveDisplay: LiveProgressDisplay? = {
        guard let mode = liveProgressMode else { return nil }
        return LiveProgressDisplay(
            startDate: pipelineStartDate,
            stderr: .standardError,
            showDiarizationLine: false,
            audioDurationSeconds: durationSeconds,
            historicalWallSecondsPerAudioSecond: historicalWallSecondsPerAudioSecond,
            renderMode: mode
        )
    }()

    if liveDisplay == nil {
        logger?.log("Starting transcription...")
    }
    let results: [TranscriptionResult]
    if let display = liveDisplay {
        let (res, tMs) = try await WallClock.measureMs { () async throws -> [TranscriptionResult] in
            try await whisperKit.transcribe(
                audioArray: audioArray,
                decodeOptions: decodeOptions
            ) { progress in
                display.updateTranscription(progress: progress)
                return nil
            }
        }
        phases.transcribeOnlyMs = tMs
        phases.decodingWindows = display.finish()
        results = res
    } else {
        let (res, tMs) = try await WallClock.measureMs { () async throws -> [TranscriptionResult] in
            try await whisperKit.transcribe(
                audioArray: audioArray,
                decodeOptions: decodeOptions
            )
        }
        phases.transcribeOnlyMs = tMs
        results = res
    }

    let output = buildTranscriptionOutput(
        from: results,
        durationSeconds: durationSeconds,
        diarizationEnabled: false
    )
    logger?.log("Transcription complete (\(output.segments.count) output segments)")
    return (output, phases)
}

/// Runs transcription-only path: load audio, init WhisperKit, transcribe, return segments.
/// - Parameter wordTimestamps: Enable word-level timestamps (required for diarization merge later).
func runTranscriptionOnly(
    audioPath: String,
    model: String,
    modelDir: String,
    language: String?,
    computeOptions: RuntimeComputeOptions,
    verbose: Bool,
    wordTimestamps: Bool = false,
    liveProgressMode: LiveProgressRenderMode? = nil,
    pipelineStartDate: Date,
    historicalWallSecondsPerAudioSecond: Double?,
    logger: VerboseLogger? = nil
) async throws -> (TranscriptionOutput, PhaseTimings) {
    let (preparedAudio, loadMs) = try WallClock.measureMs { try loadPreparedAudio(audioPath: audioPath, logger: logger) }
    let (output, inner) = try await runTranscriptionOnly(
        audioArray: preparedAudio.samples,
        durationSeconds: preparedAudio.durationSeconds,
        model: model,
        modelDir: modelDir,
        language: language,
        computeOptions: computeOptions,
        verbose: verbose,
        wordTimestamps: wordTimestamps,
        liveProgressMode: liveProgressMode,
        pipelineStartDate: pipelineStartDate,
        historicalWallSecondsPerAudioSecond: historicalWallSecondsPerAudioSecond,
        logger: logger
    )
    var phases = inner
    phases.audioLoadMs = loadMs
    return (output, phases)
}

/// Result of transcription (and optionally diarization).
struct TranscriptionOutput {
    var segments: [TranscriptSegment]
    var language: String?
    var durationSeconds: Double
    var diarizationEnabled: Bool = false
    var speakersDetected: Int? = nil
    var speakerStrategy: String = "subsegment"
    var warnings: [String] = []
}

/// Format SpeakerInfo as "SPEAKER_0", "SPEAKER_1", or nil.
func formatSpeakerLabel(_ info: SpeakerInfo) -> String? {
    if let id = info.speakerId {
        return "SPEAKER_\(id)"
    }
    return nil
}

/// Convert merged [[SpeakerSegment]] to [TranscriptSegment].
func segmentsFromSpeakerSegments(_ segmentsPerResult: [[SpeakerSegment]]) -> [TranscriptSegment] {
    segmentsPerResult.flatMap { segments in
        segments.map { seg in
            let words: [WordSegment]? = seg.speakerWords.isEmpty ? nil : seg.speakerWords.map { w in
                WordSegment(word: w.wordTiming.word, start: Double(w.wordTiming.start), end: Double(w.wordTiming.end))
            }
            return TranscriptSegment(
                speaker: formatSpeakerLabel(seg.speaker),
                start: Double(seg.startTime),
                end: Double(seg.endTime),
                text: seg.text,
                words: words
            )
        }
    }
}

/// Minimum audio duration (seconds) to attempt diarization. Shorter audio skips diarization with a warning.
let minDiarizationDurationSeconds: Double = 5.0

/// Runs transcription with diarization: load audio, run Whisper and SpeakerKit concurrently, merge, return output.
/// Falls back to transcription-only if audio is too short or diarization returns no speakers.
func runTranscriptionWithDiarization(
    audioPath: String,
    model: String,
    modelDir: String,
    language: String?,
    minSpeakers: Int?,
    maxSpeakers: Int?,
    speakerStrategy: SpeakerInfoStrategy,
    computeOptions: RuntimeComputeOptions,
    verbose: Bool,
    liveProgressMode: LiveProgressRenderMode? = nil,
    pipelineStartDate: Date,
    historicalWallSecondsPerAudioSecond: Double?,
    logger: VerboseLogger? = nil
) async throws -> (TranscriptionOutput, PhaseTimings) {
    let (preparedAudio, loadMs) = try WallClock.measureMs { try loadPreparedAudio(audioPath: audioPath, logger: logger) }
    let audioArray = preparedAudio.samples
    let durationSeconds = preparedAudio.durationSeconds

    if durationSeconds < minDiarizationDurationSeconds {
        let (shortOutput, inner) = try await runTranscriptionOnly(
            audioArray: audioArray,
            durationSeconds: durationSeconds,
            model: model,
            modelDir: modelDir,
            language: language,
            computeOptions: computeOptions,
            verbose: verbose,
            wordTimestamps: false,
            liveProgressMode: liveProgressMode,
            pipelineStartDate: pipelineStartDate,
            historicalWallSecondsPerAudioSecond: historicalWallSecondsPerAudioSecond,
            logger: logger
        )
        var out = shortOutput
        var phases = inner
        phases.audioLoadMs = loadMs
        out.warnings.append("Audio shorter than \(Int(minDiarizationDurationSeconds))s; diarization skipped.")
        return (out, phases)
    }

    var phases = PhaseTimings()
    phases.audioLoadMs = loadMs

    let (whisperKit, wMs) = try await WallClock.measureMs {
        try await initializeWhisperKit(
            model: model,
            modelDir: modelDir,
            computeOptions: computeOptions,
            verbose: verbose,
            logger: logger
        )
    }
    phases.whisperInitMs = wMs

    let (speakerKit, sMs) = try await WallClock.measureMs {
        try await initializeSpeakerKit(
            modelDir: modelDir,
            computeOptions: computeOptions,
            verbose: verbose,
            logger: logger
        )
    }
    phases.speakerInitMs = sMs

    let decodeOptions: DecodingOptions = {
        var opts = DecodingOptions(
            wordTimestamps: true,
            chunkingStrategy: .vad
        )
        if let lang = language, !lang.isEmpty {
            opts.language = lang
        }
        return opts
    }()

    let numberOfSpeakers: Int? = {
        guard let min = minSpeakers, let max = maxSpeakers, min == max else {
            return nil
        }
        return min
    }()
    let diarizationOptions = PyannoteDiarizationOptions(numberOfSpeakers: numberOfSpeakers)

    let liveDisplay: LiveProgressDisplay? = {
        guard let mode = liveProgressMode else { return nil }
        return LiveProgressDisplay(
            startDate: pipelineStartDate,
            stderr: .standardError,
            showDiarizationLine: true,
            audioDurationSeconds: durationSeconds,
            historicalWallSecondsPerAudioSecond: historicalWallSecondsPerAudioSecond,
            renderMode: mode
        )
    }()

    if liveDisplay == nil {
        logger?.log("Starting transcription...")
        logger?.log("Starting diarization...")
    }

    let results: [TranscriptionResult]
    let diarizationResult: DiarizationResult
    if let display = liveDisplay {
        let (pair, pMs) = try await WallClock.measureMs { () async throws -> ([TranscriptionResult], DiarizationResult) in
            async let transTask: [TranscriptionResult] = whisperKit.transcribe(
                audioArray: audioArray,
                decodeOptions: decodeOptions
            ) { progress in
                display.updateTranscription(progress: progress)
                return nil
            }
            async let diarTask: DiarizationResult = speakerKit.diarize(
                audioArray: audioArray,
                options: diarizationOptions
            ) { progress in
                let frac = progress.fractionCompleted
                let count = progress.completedUnitCount
                display.updateDiarization(fractionCompleted: frac, completedUnitCount: count)
            }
            let r = try await transTask
            let d = try await diarTask
            return (r, d)
        }
        phases.parallelMs = pMs
        phases.decodingWindows = display.finish()
        results = pair.0
        diarizationResult = pair.1
    } else {
        let (pair, pMs) = try await WallClock.measureMs { () async throws -> ([TranscriptionResult], DiarizationResult) in
            async let transTask: [TranscriptionResult] = whisperKit.transcribe(
                audioArray: audioArray,
                decodeOptions: decodeOptions
            )
            async let diarTask: DiarizationResult = speakerKit.diarize(
                audioArray: audioArray,
                options: diarizationOptions
            )
            let r = try await transTask
            let d = try await diarTask
            return (r, d)
        }
        phases.parallelMs = pMs
        results = pair.0
        diarizationResult = pair.1
    }

    let whisperSegmentCount = results.flatMap(\.segments).count
    logger?.log("Transcription complete (\(whisperSegmentCount) WhisperKit segments)")
    logger?.log("Diarization complete (\(diarizationResult.speakerCount) speakers detected)")
    logger?.log("Merging speaker labels with strategy=\(speakerStrategy == .segment ? "segment" : "subsegment")")
    let (mergeResult, mergeMs) = WallClock.measureMs {
        let merged = diarizationResult.addSpeakerInfo(to: results, strategy: speakerStrategy)
        let transcriptOnlySegments = segmentsFromTranscriptionResults(results)
        var segments = segmentsFromSpeakerSegments(merged)
        var usedTranscriptOnlyFallback = false
        if segments.isEmpty || diarizationResult.speakerCount == 0 {
            usedTranscriptOnlyFallback = true
            segments = transcriptOnlySegments
        }
        return (segments, transcriptOnlySegments, usedTranscriptOnlyFallback)
    }
    phases.mergeMs = mergeMs
    let (segments, transcriptOnlySegments, usedTranscriptOnlyFallback) = mergeResult
    if usedTranscriptOnlyFallback {
        logger?.log("No speakers detected, using transcript-only")
    }
    logger?.log("Merged to \(segments.count) output segments")

    var warnings: [String] = []
    let speakersDetected = diarizationResult.speakerCount
    if transcriptOnlySegments.isEmpty {
        warnings.append("No speech detected; output contains no segments.")
    } else if speakersDetected == 0 || segments.isEmpty {
        warnings.append("Diarization returned no speakers; segment labels omitted.")
    } else {
        if let min = minSpeakers, speakersDetected < min {
            warnings.append("Diarization detected \(speakersDetected) speaker(s), fewer than --min-speakers (\(min)).")
        }
        if let max = maxSpeakers, speakersDetected > max {
            warnings.append("Diarization detected \(speakersDetected) speaker(s), more than --max-speakers (\(max)).")
        }
    }

    let output = TranscriptionOutput(
        segments: segments,
        language: results.first?.language,
        durationSeconds: durationSeconds,
        diarizationEnabled: true,
        speakersDetected: speakersDetected > 0 ? speakersDetected : nil,
        speakerStrategy: speakerStrategy == .segment ? "segment" : "subsegment",
        warnings: warnings
    )
    return (output, phases)
}
