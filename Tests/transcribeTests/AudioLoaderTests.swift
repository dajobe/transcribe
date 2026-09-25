import Foundation
import XCTest
@testable import transcribe

final class AudioLoaderTests: XCTestCase {
    func testUncompressedByteCountUsesFloatSize() {
        XCTAssertEqual(AudioLoader.uncompressedByteCount(forSampleCount: 1000), 4000)
    }

    func testAudioLoadLimitsDefaultMatchesTranscriptionDefaults() {
        XCTAssertEqual(AudioLoadLimits.default.maxAudioMB, TranscriptionDefaults.maxAudioMB)
    }

    func testMaxUncompressedBytesDisabledWhenZero() {
        let limits = AudioLoadLimits(maxAudioMB: 0)
        XCTAssertNil(limits.maxUncompressedBytes)
    }

    func testMaxUncompressedBytesScalesMegabytes() {
        let limits = AudioLoadLimits(maxAudioMB: 2)
        XCTAssertEqual(limits.maxUncompressedBytes, 2 * 1024 * 1024)
    }

    func testValidateAudioContainerAcceptsGeneratedFormats() throws {
        for ext in AudioLoader.audioFormatExtensions {
            let url = try generatedAudioFixtureURL(ext)
            XCTAssertNoThrow(
                try AudioLoader.validateAudioContainer(fromPath: url.path),
                "Expected generated .\(ext) fixture to pass container preflight"
            )
        }
    }

    /// The preflight duration seeds ETA hints before decoding, so it must
    /// match the real length closely for a plain container.
    func testValidateAudioContainerReportsEstimatedDuration() throws {
        let url = try generatedAudioFixtureURL("wav")
        let duration = try XCTUnwrap(AudioLoader.validateAudioContainer(fromPath: url.path))
        XCTAssertEqual(duration, 4.0, accuracy: 0.05)

        let session = AudioSession(files: [url.path, url.path], recordedAt: nil)
        let durations = try preflightAudioDecoding(for: [session])
        XCTAssertEqual(try XCTUnwrap(estimatedSessionDuration(session, durations: durations)), 8.0, accuracy: 0.1)
        XCTAssertNil(estimatedSessionDuration(AudioSession(files: ["/missing.wav"], recordedAt: nil), durations: durations))
    }

    func testDirectoryCandidateExtensionsComeFromAudioFormatExtensions() {
        XCTAssertEqual(AudioLoader.candidateExtensions, Set(AudioLoader.audioFormatExtensions))
        XCTAssertEqual(
            AudioLoader.candidateExtensionsDescription,
            AudioLoader.audioFormatExtensions.joined(separator: ", ")
        )
    }

    func testValidateAudioContainerRejectsNonAudio() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }

        let file = dir.appendingPathComponent("not-audio.m4a")
        try Data("not an audio container".utf8).write(to: file)

        XCTAssertThrowsError(try AudioLoader.validateAudioContainer(fromPath: file.path)) { error in
            guard let transcribeError = error as? TranscribeError else {
                return XCTFail("Unexpected error type: \(error)")
            }
            XCTAssertEqual(transcribeError.exitCode, .inputFile)
            XCTAssertTrue(transcribeError.message.contains("Failed to inspect audio container"))
        }
    }

    private func generatedAudioFixtureURL(_ ext: String) throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(
                forResource: "smoke",
                withExtension: ext
            ),
            "Missing generated audio fixture: smoke.\(ext)"
        )
    }
}
