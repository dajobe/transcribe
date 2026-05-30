import Foundation
import WhisperKit
import XCTest
@testable import transcribe

final class TranscriptionPipelineTests: XCTestCase {
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

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
