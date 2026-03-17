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
    verbose: Bool,
    logger: VerboseLogger? = nil
) async throws -> WhisperKit {
    let expandedModelDir = (modelDir as NSString).expandingTildeInPath
    let config = WhisperKitConfig(
        model: model,
        modelFolder: expandedModelDir,
        verbose: verbose,
        load: true,
        download: true
    )

    logger?.log("Using model cache: \(expandedModelDir)")
    let whisperKit: WhisperKit
    do {
        whisperKit = try await WhisperKit(config)
    } catch {
        logger?.log("Model load failed, retrying once...")
        do {
            whisperKit = try await WhisperKit(config)
        } catch {
            throw TranscribeError(
                message: "Model initialization failed after retry: \(error.localizedDescription)",
                exitCode: .modelFailure
            )
        }
    }

    return whisperKit
}

func initializeSpeakerKit(
    modelDir: String,
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

    let speakerKit: SpeakerKit
    do {
        speakerKit = try await SpeakerKit(speakerConfig)
    } catch {
        logger?.log("SpeakerKit load failed, retrying once...")
        do {
            speakerKit = try await SpeakerKit(speakerConfig)
        } catch {
            throw TranscribeError(
                message: "SpeakerKit initialization failed: \(error.localizedDescription). Use --no-diarize for transcript-only.",
                exitCode: .modelFailure
            )
        }
    }

    return speakerKit
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
    verbose: Bool,
    wordTimestamps: Bool = false,
    logger: VerboseLogger? = nil
) async throws -> TranscriptionOutput {
    let whisperKit = try await initializeWhisperKit(
        model: model,
        modelDir: modelDir,
        verbose: verbose,
        logger: logger
    )

    var decodeOptions = DecodingOptions(
        wordTimestamps: wordTimestamps,
        chunkingStrategy: .vad
    )
    if let lang = language, !lang.isEmpty {
        decodeOptions.language = lang
    }

    logger?.log("Starting transcription...")
    let results = try await whisperKit.transcribe(
        audioArray: audioArray,
        decodeOptions: decodeOptions
    )

    let output = buildTranscriptionOutput(
        from: results,
        durationSeconds: durationSeconds,
        diarizationEnabled: false
    )
    logger?.log("Transcription complete (\(output.segments.count) segments)")
    return output
}

/// Runs transcription-only path: load audio, init WhisperKit, transcribe, return segments.
/// - Parameter wordTimestamps: Enable word-level timestamps (required for diarization merge later).
func runTranscriptionOnly(
    audioPath: String,
    model: String,
    modelDir: String,
    language: String?,
    verbose: Bool,
    wordTimestamps: Bool = false,
    logger: VerboseLogger? = nil
) async throws -> TranscriptionOutput {
    let preparedAudio = try loadPreparedAudio(audioPath: audioPath, logger: logger)
    return try await runTranscriptionOnly(
        audioArray: preparedAudio.samples,
        durationSeconds: preparedAudio.durationSeconds,
        model: model,
        modelDir: modelDir,
        language: language,
        verbose: verbose,
        wordTimestamps: wordTimestamps,
        logger: logger
    )
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
    verbose: Bool,
    logger: VerboseLogger? = nil
) async throws -> TranscriptionOutput {
    let preparedAudio = try loadPreparedAudio(audioPath: audioPath, logger: logger)
    let audioArray = preparedAudio.samples
    let durationSeconds = preparedAudio.durationSeconds

    if durationSeconds < minDiarizationDurationSeconds {
        var out = try await runTranscriptionOnly(
            audioArray: audioArray,
            durationSeconds: durationSeconds,
            model: model,
            modelDir: modelDir,
            language: language,
            verbose: verbose,
            wordTimestamps: false,
            logger: logger
        )
        out.warnings.append("Audio shorter than \(Int(minDiarizationDurationSeconds))s; diarization skipped.")
        return out
    }

    let whisperKit = try await initializeWhisperKit(
        model: model,
        modelDir: modelDir,
        verbose: verbose,
        logger: logger
    )
    let speakerKit = try await initializeSpeakerKit(
        modelDir: modelDir,
        verbose: verbose,
        logger: logger
    )

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

    logger?.log("Starting transcription...")
    logger?.log("Starting diarization...")
    async let transcriptionTask: [TranscriptionResult] = whisperKit.transcribe(
        audioArray: audioArray,
        decodeOptions: decodeOptions
    )
    async let diarizationTask: DiarizationResult = speakerKit.diarize(
        audioArray: audioArray,
        options: diarizationOptions
    )

    let results = try await transcriptionTask
    let diarizationResult = try await diarizationTask

    logger?.log("Transcription complete (\(results.flatMap { $0.segments }.count) segments)")
    logger?.log("Diarization complete (\(diarizationResult.speakerCount) speakers detected)")
    logger?.log("Merging speaker labels with strategy=\(speakerStrategy == .segment ? "segment" : "subsegment")")
    let merged = diarizationResult.addSpeakerInfo(to: results, strategy: speakerStrategy)
    let transcriptOnlySegments = segmentsFromTranscriptionResults(results)
    var segments = segmentsFromSpeakerSegments(merged)

    if segments.isEmpty || diarizationResult.speakerCount == 0 {
        logger?.log("No speakers detected, using transcript-only")
        segments = transcriptOnlySegments
    }

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

    return TranscriptionOutput(
        segments: segments,
        language: results.first?.language,
        durationSeconds: durationSeconds,
        diarizationEnabled: true,
        speakersDetected: speakersDetected > 0 ? speakersDetected : nil,
        speakerStrategy: speakerStrategy == .segment ? "segment" : "subsegment",
        warnings: warnings
    )
}
