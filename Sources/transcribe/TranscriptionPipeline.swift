import Foundation
import SpeakerKit
import WhisperKit

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
    logger?.log("Loading audio: \((audioPath as NSString).lastPathComponent)")
    let audioArray = try AudioLoader.loadAudio(fromPath: audioPath)
    let durationSeconds = Double(audioArray.count) / Double(WhisperKit.sampleRate)
    logger?.log("Audio loaded (\(String(format: "%.1f", durationSeconds))s, 16kHz mono)")

    let expandedModelDir = (modelDir as NSString).expandingTildeInPath
    let config = WhisperKitConfig(
        model: model,
        modelFolder: expandedModelDir,
        verbose: verbose,
        load: true,
        download: true
    )

    logger?.log("Using model cache: \(expandedModelDir)")
    logger?.log("Starting transcription...")
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

    var decodeOptions = DecodingOptions(
        wordTimestamps: wordTimestamps,
        chunkingStrategy: .vad
    )
    if let lang = language, !lang.isEmpty {
        decodeOptions.language = lang
    }

    let results = try await whisperKit.transcribe(
        audioArray: audioArray,
        decodeOptions: decodeOptions
    )

    let segments = segmentsFromTranscriptionResults(results)
    let detectedLanguage = results.first?.language
    logger?.log("Transcription complete (\(segments.count) segments)")
    return TranscriptionOutput(
        segments: segments,
        language: detectedLanguage,
        durationSeconds: durationSeconds,
        diarizationEnabled: false
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
    logger?.log("Loading audio: \((audioPath as NSString).lastPathComponent)")
    let audioArray = try AudioLoader.loadAudio(fromPath: audioPath)
    let durationSeconds = Double(audioArray.count) / Double(WhisperKit.sampleRate)
    logger?.log("Audio loaded (\(String(format: "%.1f", durationSeconds))s, 16kHz mono)")

    if durationSeconds < minDiarizationDurationSeconds {
        logger?.log("Audio too short (\(String(format: "%.1f", durationSeconds))s), skipping diarization")
        var out = try await runTranscriptionOnly(
            audioPath: audioPath,
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

    let expandedModelDir = (modelDir as NSString).expandingTildeInPath
    let whisperConfig = WhisperKitConfig(
        model: model,
        modelFolder: expandedModelDir,
        verbose: verbose,
        load: true,
        download: true
    )

    let speakerConfig = PyannoteConfig(
        downloadBase: URL(fileURLWithPath: expandedModelDir),
        modelFolder: nil,
        download: true,
        verbose: verbose
    )

    logger?.log("Using model cache: \(expandedModelDir)")
    logger?.log("Starting transcription...")
    logger?.log("Starting diarization...")
    let whisperKit = try await WhisperKit(whisperConfig)
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

    let numberOfSpeakers: Int?
    if let min = minSpeakers, let max = maxSpeakers, min == max {
        numberOfSpeakers = min
    } else {
        numberOfSpeakers = maxSpeakers ?? minSpeakers
    }
    let diarizationOptions = PyannoteDiarizationOptions(numberOfSpeakers: numberOfSpeakers)

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
    var segments = segmentsFromSpeakerSegments(merged)

    if segments.isEmpty || diarizationResult.speakerCount == 0 {
        logger?.log("No speakers detected, using transcript-only")
        segments = segmentsFromTranscriptionResults(results)
    }

    var warnings: [String] = []
    let speakersDetected = diarizationResult.speakerCount
    if speakersDetected == 0 || segments.isEmpty {
        warnings.append("Diarization returned no speakers; segment labels omitted.")
    } else if let min = minSpeakers, speakersDetected < min {
        warnings.append("Diarization detected \(speakersDetected) speaker(s), fewer than --min-speakers (\(min)).")
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
