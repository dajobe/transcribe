import Foundation
import XCTest
@testable import transcribe

final class OutputWriterTests: XCTestCase {
    func testRenderTxtWithoutSpeakerStillShowsTimeRanges() {
        let output = TranscriptionOutput(
            segments: [
                TranscriptSegment(speaker: nil, start: 0, end: 12, text: "Hello there.", words: nil),
                TranscriptSegment(speaker: nil, start: 12, end: 18, text: "General Kenobi.", words: nil),
            ],
            language: "en",
            durationSeconds: 18,
            diarizationEnabled: false
        )

        let text = renderTxt(output: output)

        XCTAssertEqual(
            text,
            """
            [00:00:00 - 00:00:18]
            Hello there. General Kenobi.
            """
        )
    }

    func testRenderJSONPreservesWarningsAndWords() throws {
        let output = TranscriptionOutput(
            segments: [
                TranscriptSegment(
                    speaker: nil,
                    start: 0,
                    end: 1.25,
                    text: "Hello",
                    words: [WordSegment(word: "Hello", start: 0, end: 1.25)]
                )
            ],
            language: "en",
            durationSeconds: 1.25,
            diarizationEnabled: false,
            speakersDetected: nil,
            speakerStrategy: "subsegment",
            warnings: ["No speech detected; output contains no segments."]
        )

        let data = try renderJSON(
            output: output,
            audioFile: "/tmp/sample.wav",
            model: "large-v3",
            version: Transcribe.version
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let metadata = try XCTUnwrap(json["metadata"] as? [String: Any])
        let warnings = try XCTUnwrap(json["warnings"] as? [String])
        let segments = try XCTUnwrap(json["segments"] as? [[String: Any]])
        let firstSegment = try XCTUnwrap(segments.first)
        let words = try XCTUnwrap(firstSegment["words"] as? [[String: Any]])

        XCTAssertEqual(metadata["audio_file"] as? String, "sample.wav")
        XCTAssertEqual(metadata["language"] as? String, "en")
        XCTAssertEqual(warnings, ["No speech detected; output contains no segments."])
        XCTAssertEqual(firstSegment["speaker"] as? NSNull, nil)
        XCTAssertEqual(words.count, 1)
    }

    func testCheckOverwriteFailsOnPathTraversal() throws {
        XCTAssertThrowsError(
            try checkOverwrite(
                outputDir: "/tmp",
                basename: "../../etc/passwd",
                formats: ["txt"],
                writeTxtFile: true,
                overwrite: true
            )
        ) { error in
            guard let transcribeError = error as? TranscribeError else {
                return XCTFail("Unexpected error type: \(error)")
            }
            XCTAssertEqual(transcribeError.exitCode, .invalidUsage)
        }
    }

    func testCheckOverwriteFailsWhenOutputExists() throws {
        let tempDir = try makeTemporaryDirectory()
        let existingFile = tempDir.appendingPathComponent("meeting.json")
        try Data("{}".utf8).write(to: existingFile)

        XCTAssertThrowsError(
            try checkOverwrite(
                outputDir: tempDir.path,
                basename: "meeting",
                formats: ["json"],
                writeTxtFile: false,
                overwrite: false
            )
        ) { error in
            guard let transcribeError = error as? TranscribeError else {
                return XCTFail("Unexpected error type: \(error)")
            }
            XCTAssertEqual(transcribeError.exitCode, .outputWrite)
        }
    }

    func testWriteAtomicallyReplacesExistingFileContents() throws {
        let tempDir = try makeTemporaryDirectory()
        let fileURL = tempDir.appendingPathComponent("meeting.txt")
        try Data("old".utf8).write(to: fileURL)

        try writeAtomically(content: Data("new".utf8), to: fileURL.path)

        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertEqual(contents, "new")
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
