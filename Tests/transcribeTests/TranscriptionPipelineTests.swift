import Foundation
import WhisperKit
import XCTest
@testable import transcribe

final class TranscriptionPipelineTests: XCTestCase {
    func testWhisperModelCacheFolderRequiresAllModelBundles() throws {
        let modelDir = try makeTemporaryDirectory()
        let modelFolder = modelDir
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/cached-model")
        for bundle in ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"] {
            try FileManager.default.createDirectory(
                at: modelFolder.appendingPathComponent(bundle),
                withIntermediateDirectories: true
            )
        }

        let cachedFolder = try XCTUnwrap(whisperModelCacheFolder(model: "cached-model", modelDir: modelDir.path))
        XCTAssertEqual(cachedFolder.path, modelFolder.path)

        try FileManager.default.removeItem(at: modelFolder.appendingPathComponent("TextDecoder.mlmodelc"))
        XCTAssertNil(whisperModelCacheFolder(model: "cached-model", modelDir: modelDir.path))
    }

    func testWhisperModelCacheFolderReusesLegacyTurboDirectory() throws {
        let modelDir = try makeTemporaryDirectory()
        let modelFolder = modelDir
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930")
        for bundle in ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"] {
            try FileManager.default.createDirectory(
                at: modelFolder.appendingPathComponent(bundle),
                withIntermediateDirectories: true
            )
        }

        let cachedFolder = try XCTUnwrap(
            whisperModelCacheFolder(
                model: "openai_whisper-large-v3-v20240930_turbo",
                modelDir: modelDir.path
            )
        )
        XCTAssertEqual(cachedFolder.path, modelFolder.path)
    }

    func testApplyWhisperPhaseTimingsAggregatesResultTimings() throws {
        let resultA = TranscriptionResult(
            text: "a",
            segments: [],
            language: "en",
            timings: TranscriptionTimings(
                audioProcessing: 1.0,
                logmels: 2.0,
                encoding: 3.0,
                decodingLoop: 4.0,
                totalAudioProcessingRuns: 5,
                totalLogmelRuns: 6,
                totalEncodingRuns: 7,
                totalDecodingWindows: 8
            )
        )
        let resultB = TranscriptionResult(
            text: "b",
            segments: [],
            language: "en",
            timings: TranscriptionTimings(
                audioProcessing: 0.5,
                logmels: 1.0,
                encoding: 1.5,
                decodingLoop: 2.0,
                totalAudioProcessingRuns: 2,
                totalLogmelRuns: 3,
                totalEncodingRuns: 4,
                totalDecodingWindows: 5
            )
        )

        var phases = PhaseTimings()
        applyWhisperPhaseTimings(from: [resultA, resultB], firstProgressMs: 1234, to: &phases)

        XCTAssertEqual(phases.whisperAudioProcessingMs, 1500)
        XCTAssertEqual(phases.whisperLogmelsMs, 3000)
        XCTAssertEqual(phases.whisperEncodingMs, 4500)
        XCTAssertEqual(phases.whisperDecodingLoopMs, 6000)
        XCTAssertEqual(phases.whisperTotalAudioProcessingRuns, 7)
        XCTAssertEqual(phases.whisperTotalLogmelRuns, 9)
        XCTAssertEqual(phases.whisperTotalEncodingRuns, 11)
        XCTAssertEqual(phases.whisperTotalDecodingWindows, 13)
        XCTAssertEqual(phases.whisperFirstProgressMs, 1234)
        XCTAssertEqual(phases.decodingWindows, 13)
    }

    func testPreflightAudioDecodingFailsNonAudioBeforeModelInit() throws {
        let dir = try makeTemporaryDirectory()
        let badAudio = dir.appendingPathComponent("bad.m4a")
        try Data("not an audio container".utf8).write(to: badAudio)
        let sessions = [AudioSession(files: [badAudio.path], recordedAt: nil)]

        XCTAssertThrowsError(try preflightAudioDecoding(for: sessions)) { error in
            guard let transcribeError = error as? TranscribeError else {
                return XCTFail("Unexpected error type: \(error)")
            }
            XCTAssertEqual(transcribeError.exitCode, .inputFile)
        }
    }

    func testSpeakerEmbeddingsKeepsOnlyCentroidsLabellingSegments() throws {
        let segments = [
            TranscriptSegment(speaker: "SPEAKER_0", start: 0, end: 1, text: "a", words: nil),
            TranscriptSegment(speaker: "SPEAKER_2", start: 1, end: 2, text: "b", words: nil),
            TranscriptSegment(speaker: nil, start: 2, end: 3, text: "c", words: nil)
        ]
        let centroids: [Int: [Float]] = [0: [1, 0], 1: [0, 1], 2: [0.5, 0.5]]

        let embeddings = speakerEmbeddings(centroids: centroids, forSegments: segments)

        XCTAssertEqual(Set(embeddings.keys), ["SPEAKER_0", "SPEAKER_2"])
        XCTAssertEqual(embeddings["SPEAKER_0"], [1, 0])
        XCTAssertEqual(embeddings["SPEAKER_2"], [0.5, 0.5])
    }

    func testSpeakerEmbeddingsKeysMatchSegmentLabelFormat() throws {
        let segments = [TranscriptSegment(speaker: formatSpeakerLabel(.speakerId(7)), start: 0, end: 1, text: "a", words: nil)]

        let embeddings = speakerEmbeddings(centroids: [7: [1, 0]], forSegments: segments)

        XCTAssertEqual(Array(embeddings.keys), ["SPEAKER_7"])
        // Keys must satisfy the canonical store's local-speaker-ID form.
        for key in embeddings.keys {
            XCTAssertTrue(key.hasPrefix("SPEAKER_"))
            XCTAssertTrue(key.dropFirst("SPEAKER_".count).allSatisfy(\.isNumber))
        }
    }

    func testSpeakerEmbeddingsIsEmptyWithoutMatchingSegments() throws {
        XCTAssertTrue(speakerEmbeddings(centroids: [0: [1, 0]], forSegments: []).isEmpty)
        XCTAssertTrue(
            speakerEmbeddings(
                centroids: [:],
                forSegments: [TranscriptSegment(speaker: "SPEAKER_0", start: 0, end: 1, text: "a", words: nil)]
            ).isEmpty
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
