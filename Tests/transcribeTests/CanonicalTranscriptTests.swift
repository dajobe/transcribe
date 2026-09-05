import Foundation
import XCTest
@testable import transcribe

final class CanonicalTranscriptTests: XCTestCase {
    private func output() -> TranscriptionOutput {
        TranscriptionOutput(
            segments: [
                TranscriptSegment(
                    speaker: "SPEAKER_0", start: 0, end: 1.5, text: "Hello",
                    words: [WordSegment(word: "Hello", start: 0, end: 1.5)]
                ),
            ],
            language: "en",
            durationSeconds: 1.5,
            diarizationEnabled: true,
            speakersDetected: 1,
            speakerEmbeddings: ["SPEAKER_0": [0.25, 0.75]]
        )
    }

    private func document(
        schemaVersion: Int = CanonicalTranscript.currentSchemaVersion,
        output: TranscriptionOutput? = nil,
        matches: [String: SpeakerMatch] = [:]
    ) -> CanonicalTranscript {
        let sourceHashes = [String(repeating: "a", count: 64)]
        return CanonicalTranscript(
            schemaVersion: schemaVersion,
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            evidenceID: CanonicalTranscript.evidenceID(forSourceHashes: sourceHashes),
            sourceHashes: sourceHashes,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            model: "whisper-test",
            transcribeVersion: "2.5.3",
            audioPath: "/audio/meeting.m4a",
            audioFiles: ["part-1.m4a", "part-2.m4a"],
            basename: "meeting",
            sourceMetadata: OutputSourceMetadata(
                source: "voice_memos", recordedAt: "2026-01-02T03:04:05Z",
                recordingTitle: "Standup", voiceMemosUniqueID: "memo-id",
                voiceMemosPath: "/memo/path"
            ),
            output: output ?? self.output(),
            speakerMatches: matches
        )
    }

    func testRoundTripPreservesMetadataAndEmbeddings() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("document.json")
        let expected = document()

        XCTAssertEqual(try CanonicalTranscriptStore.save(expected, to: url), url)
        XCTAssertEqual(try CanonicalTranscriptStore.load(from: url), expected)
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
    }

    func testRejectsUnsupportedSchemaAndInvalidData() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try CanonicalTranscriptStore.save(document(schemaVersion: 99), to: url))

        var invalid = output()
        invalid.speakerEmbeddings = ["unsafe": [Float.nan]]
        XCTAssertThrowsError(try CanonicalTranscriptStore.save(document(output: invalid), to: url))
    }

    func testStampedEmbeddingModelIDMatchesTheLoadedSDKEmbedder() throws {
        // Saved documents and speaker profiles already carry this exact string;
        // changing it silently orphans their embeddings.
        XCTAssertEqual(
            CanonicalTranscript.speakerEmbeddingModelID,
            "argmax-speakerkit-1.1.0/pyannote-v3/speaker_embedder/W8A16"
        )
        XCTAssertEqual(speakerKitEmbeddingModelID(), CanonicalTranscript.speakerEmbeddingModelID)
        XCTAssertNoThrow(try verifySpeakerEmbeddingModelID())
    }

    func testRejectsAnEmbedderIdentityThatNoLongerMatchesSavedEmbeddings() throws {
        let changed = CanonicalTranscript.makeSpeakerEmbeddingModelID(
            embedderName: "speaker_embedder", embedderVersion: "pyannote-v4", embedderVariant: "W8A16"
        )
        XCTAssertNotEqual(changed, CanonicalTranscript.speakerEmbeddingModelID)
        XCTAssertThrowsError(try verifySpeakerEmbeddingModelID(changed)) { error in
            XCTAssertEqual((error as? TranscribeError)?.exitCode, .modelFailure)
        }
    }

    func testRejectsTimingThatWouldOverflowExports() throws {
        var invalid = output()
        invalid.segments = [TranscriptSegment(speaker: "SPEAKER_0", start: 0, end: Double.greatestFiniteMagnitude, text: "Hello", words: nil)]
        XCTAssertThrowsError(try CanonicalTranscriptStore.validate(document(output: invalid)))
    }

    func testRejectsControlCharactersInSavedIdentities() throws {
        for (id, name) in [("a", "A\nB"), ("a\u{001B}", "Alice"), ("  ", "Alice")] {
            let match = SpeakerMatch(profileID: id, name: name, distance: 0, margin: nil, confirmedExampleCount: 1, status: .confirmed)
            XCTAssertThrowsError(try CanonicalTranscriptStore.validate(document(matches: ["SPEAKER_0": match])))
        }
    }

    func testRenderedOutputAppliesOnlyAutomaticAndConfirmedNames() {
        var output = self.output()
        output.segments += [
            TranscriptSegment(speaker: "SPEAKER_1", start: 2, end: 3, text: "There", words: nil),
            TranscriptSegment(speaker: "SPEAKER_2", start: 3, end: 4, text: "Again", words: nil),
        ]
        output.speakerEmbeddings["SPEAKER_1"] = [0.5, 0.5]
        output.speakerEmbeddings["SPEAKER_2"] = [0.75, 0.25]
        let matches = [
            "SPEAKER_0": SpeakerMatch(profileID: "a", name: "Suggested", distance: 0.2, margin: nil, confirmedExampleCount: 1, status: .suggested),
            "SPEAKER_1": SpeakerMatch(profileID: "b", name: "Automatic", distance: 0.1, margin: 0.2, confirmedExampleCount: 2, status: .automatic),
            "SPEAKER_2": SpeakerMatch(profileID: "c", name: "Confirmed", distance: 0, margin: nil, confirmedExampleCount: 1, status: .confirmed),
        ]
        let canonical = document(output: output, matches: matches)

        XCTAssertEqual(canonical.renderedOutput().segments.map(\.speaker), ["SPEAKER_0", "Automatic", "Confirmed"])
        XCTAssertEqual(canonical.output.segments.map(\.speaker), ["SPEAKER_0", "SPEAKER_1", "SPEAKER_2"])
    }

    func testStandardJSONDoesNotLeakSpeakerEmbeddings() throws {
        let data = try renderJSON(
            output: output(), audioFile: "/audio/meeting.m4a", model: "test", version: "1"
        )
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("speakerEmbeddings"))
        XCTAssertFalse(text.contains("0.75"))
    }

    func testStatelessPreparationDoesNotReadProfiles() throws {
        var matcherCalled = false
        let result = try prepareCanonicalTranscript(
            stateless: true,
            model: "test",
            audioPath: "/audio/test.wav",
            audioFiles: nil,
            basename: "test",
            sourceMetadata: nil,
            output: output(),
            sourceHashes: [],
            matcher: { _, _, _, _ in matcherCalled = true; return [:] }
        )
        XCTAssertNil(result)
        XCTAssertFalse(matcherCalled)
    }
}
