import Foundation
import XCTest
@testable import transcribe

final class TranscriptionPipelineTests: XCTestCase {
    func testPreflightAudioDecodingFailsBadAudioBeforeModelInit() throws {
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
