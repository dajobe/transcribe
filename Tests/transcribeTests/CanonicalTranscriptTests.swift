import Foundation
import XCTest
@testable import transcribe

final class CanonicalTranscriptTests: XCTestCase {
    private var state: URL!
    private var previousState: String?

    override func setUpWithError() throws {
        // The managed store is addressed through XDG_STATE_HOME, so every test
        // that saves without an explicit destination gets its own directory.
        previousState = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        state = FileManager.default.temporaryDirectory.appendingPathComponent("canonical-transcript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        setenv("XDG_STATE_HOME", state.path, 1)
    }

    override func tearDownWithError() throws {
        if let previousState { setenv("XDG_STATE_HOME", previousState, 1) }
        else { unsetenv("XDG_STATE_HOME") }
        try? FileManager.default.removeItem(at: state)
    }

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

    /// The fixture output plus a second diarized speaker carrying an embedding.
    private func twoSpeakerOutput() -> TranscriptionOutput {
        var output = self.output()
        output.segments.append(TranscriptSegment(speaker: "SPEAKER_1", start: 2, end: 3, text: "There", words: nil))
        output.speakerEmbeddings["SPEAKER_1"] = [0.5, 0.5]
        output.speakersDetected = 2
        return output
    }

    private func document(
        schemaVersion: Int = CanonicalTranscript.currentSchemaVersion,
        id: UUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
        hash: Character = "a",
        output: TranscriptionOutput? = nil,
        matches: [String: SpeakerMatch] = [:]
    ) -> CanonicalTranscript {
        let sourceHashes = [String(repeating: String(hash), count: 64)]
        return CanonicalTranscript(
            schemaVersion: schemaVersion,
            id: id,
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


    // MARK: - Managed store

    private func storedIDs() throws -> [UUID] {
        try CanonicalTranscriptStore.listing().compactMap(\.id)
    }

    private func execute(_ sql: String, _ bindings: [SQLValue] = []) throws {
        try StateStore.withDatabase { database in
            try database.inTransaction(.write) { try database.execute(sql, bindings) }
        }
    }

    private func updatedAt(_ id: UUID) throws -> String {
        try StateStore.withDatabase { database in
            try database.query(
                "SELECT updated_at FROM documents WHERE id = ?", [.text(id.uuidString.lowercased())]
            ) { $0.text(0) ?? "" }.first ?? ""
        }
    }

    /// Returns the fixture output with the first segment's text replaced, so
    /// two saves of the same evidence are distinguishable.
    private func output(saying text: String) -> TranscriptionOutput {
        var output = self.output()
        output.segments[0] = TranscriptSegment(speaker: "SPEAKER_0", start: 0, end: 1.5, text: text, words: nil)
        return output
    }

    func testManagedSaveReplacesTheStoredDocumentWithTheSameEvidenceID() throws {
        let first = try CanonicalTranscriptStore.saveManaged(document(output: output(saying: "First")))
        let second = try CanonicalTranscriptStore.saveManaged(
            document(id: UUID(), output: output(saying: "Second"))
        )

        XCTAssertEqual(try storedIDs(), [first])
        // The replacement keeps the stored ID rather than the fresh run's, so
        // the handle users already hold stays valid.
        XCTAssertEqual(second, first)
        let stored = try CanonicalTranscriptStore.load(id: second)
        XCTAssertEqual(stored.output.segments.map(\.text), ["Second"])
        XCTAssertEqual(stored.id, first)
        let database = try StatePaths.stateDatabaseURL()
        XCTAssertEqual(try XCTUnwrap(fileModeBits(atPath: database.path)) & 0o777, 0o600)
    }

    func testReplacementKeepsConfirmedMatchesForSpeakersTheNewRunStillHas() throws {
        let confirmed = SpeakerMatch(profileID: "a", name: "Alice", distance: 0.1, margin: nil, confirmedExampleCount: 2, status: .confirmed)
        let suggested = SpeakerMatch(profileID: "b", name: "Bob", distance: 0.4, margin: nil, confirmedExampleCount: 1, status: .suggested)
        _ = try CanonicalTranscriptStore.saveManaged(
            document(output: twoSpeakerOutput(), matches: ["SPEAKER_0": confirmed])
        )

        let id = try CanonicalTranscriptStore.saveManaged(
            document(id: UUID(), output: twoSpeakerOutput(), matches: ["SPEAKER_1": suggested])
        )

        let stored = try CanonicalTranscriptStore.load(id: id)
        XCTAssertEqual(stored.speakerMatches, ["SPEAKER_0": confirmed, "SPEAKER_1": suggested])
    }

    func testReplacementDropsConfirmedMatchesForSpeakersTheNewRunNoLongerHas() throws {
        let confirmed = SpeakerMatch(profileID: "a", name: "Alice", distance: 0.1, margin: nil, confirmedExampleCount: 2, status: .confirmed)
        _ = try CanonicalTranscriptStore.saveManaged(
            document(output: twoSpeakerOutput(), matches: ["SPEAKER_1": confirmed])
        )

        // The second run diarized only SPEAKER_0, so nothing carries the
        // SPEAKER_1 decision and validation would reject a dangling match.
        let id = try CanonicalTranscriptStore.saveManaged(document(id: UUID()))

        XCTAssertEqual(try storedIDs().count, 1)
        XCTAssertEqual(try CanonicalTranscriptStore.load(id: id).speakerMatches, [:])
    }

    func testSavesWithDifferentEvidenceIDsKeepSeparateDocuments() throws {
        let first = try CanonicalTranscriptStore.saveManaged(document())
        let second = try CanonicalTranscriptStore.saveManaged(document(id: UUID(), hash: "b"))

        XCTAssertNotEqual(second, first)
        XCTAssertEqual(try storedIDs().count, 2)
    }

    func testUnreadableStoredDocumentIsStillReplacedWithoutCarryForward() throws {
        let confirmed = SpeakerMatch(profileID: "a", name: "Alice", distance: 0.1, margin: nil, confirmedExampleCount: 2, status: .confirmed)
        let stored = try CanonicalTranscriptStore.saveManaged(
            document(output: output(saying: "First"), matches: ["SPEAKER_0": confirmed])
        )
        try execute(
            "UPDATE document_segments SET payload = ? WHERE document_id = ?",
            [.blob(Data("{ not json".utf8)), .text(stored.uuidString.lowercased())]
        )
        XCTAssertThrowsError(try CanonicalTranscriptStore.load(id: stored))

        let id = try CanonicalTranscriptStore.saveManaged(document(id: UUID(), output: output(saying: "Second")))

        XCTAssertEqual(id, stored)
        XCTAssertEqual(try storedIDs(), [stored])
        let replaced = try CanonicalTranscriptStore.load(id: id)
        XCTAssertEqual(replaced.output.segments.map(\.text), ["Second"])
        XCTAssertEqual(replaced.speakerMatches, [:], "a document that no longer loads carries nothing forward")
    }

    func testManagedReplacementCarriesForwardExportRecords() throws {
        var first = document()
        // Whole seconds: ISO 8601 storage drops sub-second precision.
        first.exports = [
            ExportRecord(path: "/notes/meeting.txt", format: "txt", sha256: String(repeating: "b", count: 64), exportedAt: Date(timeIntervalSince1970: 1_700_000_100)),
        ]
        _ = try CanonicalTranscriptStore.saveManaged(first)

        let id = try CanonicalTranscriptStore.saveManaged(document(id: UUID(), output: output(saying: "Second")))

        XCTAssertEqual(try CanonicalTranscriptStore.load(id: id).exports, first.exports, "a rerun of the same audio must not orphan recorded exports")
    }

    /// Records carry forward only when the incoming value is nil; an empty
    /// list is a statement ("no exports") and both survive storage distinct.
    func testManagedExportsKeepNilDistinctFromEmptyAcrossReplacement() throws {
        let record = ExportRecord(path: "/notes/meeting.txt", format: "txt", sha256: String(repeating: "b", count: 64), exportedAt: Date(timeIntervalSince1970: 1_700_000_100))

        let id = try CanonicalTranscriptStore.saveManaged(document())
        XCTAssertNil(try CanonicalTranscriptStore.load(id: id).exports, "never-recorded stays nil")

        var empty = document(id: UUID())
        empty.exports = []
        _ = try CanonicalTranscriptStore.saveManaged(empty)
        XCTAssertEqual(try CanonicalTranscriptStore.load(id: id).exports, [], "an empty list is stored as empty, not nil")

        _ = try CanonicalTranscriptStore.saveManaged(document(id: UUID()))
        XCTAssertEqual(try CanonicalTranscriptStore.load(id: id).exports, [], "nil incoming carries the empty list forward")

        var recorded = document(id: UUID())
        recorded.exports = [record]
        _ = try CanonicalTranscriptStore.saveManaged(recorded)
        var cleared = document(id: UUID())
        cleared.exports = []
        _ = try CanonicalTranscriptStore.saveManaged(cleared)
        XCTAssertEqual(try CanonicalTranscriptStore.load(id: id).exports, [], "a non-nil incoming value replaces the stored records")
    }

    func testManagedReplacementCarriesForwardDismissedSpeakersTheNewRunStillHas() throws {
        var first = document(output: twoSpeakerOutput())
        first.dismissedSpeakers = ["SPEAKER_0", "SPEAKER_1"]
        _ = try CanonicalTranscriptStore.saveManaged(first)

        // The second run diarized only SPEAKER_0, so only that dismissal can
        // carry; a dangling one would fail validation.
        let id = try CanonicalTranscriptStore.saveManaged(document(id: UUID()))

        XCTAssertEqual(try CanonicalTranscriptStore.load(id: id).dismissedSpeakers, ["SPEAKER_0"])
    }

    func testManagedMutationsBumpUpdatedAt() throws {
        let id = try CanonicalTranscriptStore.saveManaged(document())
        let key = id.uuidString.lowercased()
        let stale = "2001-01-01T00:00:00Z"
        try execute("UPDATE documents SET updated_at = ? WHERE id = ?", [.text(stale), .text(key)])

        var edited = try CanonicalTranscriptStore.load(id: id)
        edited.dismissedSpeakers = ["SPEAKER_0"]
        try CanonicalTranscriptStore.save(edited, to: .managed(id: id))
        XCTAssertNotEqual(try updatedAt(id), stale, "a speaker-state edit bumps updated_at")
        XCTAssertEqual(try CanonicalTranscriptStore.load(id: id).dismissedSpeakers, ["SPEAKER_0"])

        try execute("UPDATE documents SET updated_at = ? WHERE id = ?", [.text(stale), .text(key)])
        let record = ExportRecord(path: "/notes/meeting.txt", format: "txt", sha256: String(repeating: "c", count: 64), exportedAt: Date(timeIntervalSince1970: 1_700_000_200))
        try CanonicalTranscriptStore.mergeExports([record], into: .managed(id: id))
        XCTAssertNotEqual(try updatedAt(id), stale, "an export-record update bumps updated_at")
        XCTAssertEqual(try CanonicalTranscriptStore.load(id: id).exports, [record])
    }

    func testManagedEditOfAMissingDocumentFails() throws {
        let id = UUID()
        XCTAssertThrowsError(try CanonicalTranscriptStore.save(document(id: id), to: .managed(id: id))) {
            XCTAssertEqual($0 as? CanonicalTranscriptStore.StoreError, .notFound(id.uuidString.lowercased()))
        }
        XCTAssertThrowsError(try CanonicalTranscriptStore.load(id: id))
    }

    func testListingSummaryNeverReadTheSegmentPayload() throws {
        let id = try CanonicalTranscriptStore.saveManaged(document(output: twoSpeakerOutput()))
        // With the payload gone, anything that reads it fails; listing and
        // summaries must not notice.
        try execute("DELETE FROM document_segments WHERE document_id = ?", [.text(id.uuidString.lowercased())])

        XCTAssertEqual(try CanonicalTranscriptStore.listing().map(\.basename), ["meeting"])
        let summary = try CanonicalTranscriptStore.summary(id: id)
        XCTAssertEqual(summary.segmentCount, 2)
        XCTAssertEqual(summary.segmentSpeakers, ["SPEAKER_0", "SPEAKER_1"])
        XCTAssertEqual(Set(summary.speakerEmbeddings.keys), ["SPEAKER_0", "SPEAKER_1"])
        XCTAssertThrowsError(try CanonicalTranscriptStore.load(id: id))
    }

    /// Every optional populated and every scalar off its default, so a field
    /// the database forgets fails the equality below.
    private func exhaustiveDocument() -> CanonicalTranscript {
        var output = twoSpeakerOutput()
        output.segments.append(TranscriptSegment(speaker: nil, start: 3, end: 3.25, text: "(music)", words: []))
        output.language = "de"
        output.durationSeconds = 3.333333333333333
        output.speakerStrategy = "segment"
        output.warnings = ["first warning", "second / warning"]
        output.speakerEmbeddings["SPEAKER_0"] = [0.1, -0.2, 3.4028235e38]
        output.speakerEmbeddings["SPEAKER_1"] = [1.0e-7, 0.5, 0.25]
        let sourceHashes = [String(repeating: "a", count: 64), String(repeating: "b", count: 64)]
        let recording = VoiceMemoOutputRecording(
            title: "Standup", titleSource: .customLabel, titleForSorting: "standup",
            recordedAt: "2026-01-02T03:04:05Z", durationSeconds: 61.5, uniqueID: "memo-id",
            path: "/memo/path.m4a", folderID: 3, flags: 1, audioDigestHex: "ABCDEF",
            enhancements: VoiceMemoEnhancements(
                audioFutureFlags: 1, sharedFlags: 2, silenceRemoverEnabled: true,
                skipSilenceEnabled: false, studioMixEnabled: true, studioMixLevel: 0.5
            )
        )
        return CanonicalTranscript(
            id: UUID(uuidString: "aaaaaaaa-2222-3333-4444-555555555555")!,
            evidenceID: CanonicalTranscript.evidenceID(forSourceHashes: sourceHashes),
            sourceHashes: sourceHashes,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            model: "whisper-test",
            transcribeVersion: "2.7.0",
            audioPath: "/audio/meeting dir",
            audioFiles: ["part-1.m4a", "part-2.m4a"],
            basename: "meeting",
            sourceMetadata: OutputSourceMetadata(
                source: "voice_memos", recordedAt: "2026-01-02T03:04:05Z",
                recordingTitle: "Standup", voiceMemosUniqueID: "memo-id",
                voiceMemosPath: "/memo/path",
                voiceMemos: VoiceMemosOutputMetadata(sessionTitle: "Standup", recordingCount: 1, recordings: [recording])
            ),
            output: output,
            embeddingModelID: "model/with/slashes",
            speakerMatches: [
                "SPEAKER_0": SpeakerMatch(profileID: "p0", name: "Alice", distance: 0.125, margin: 0.3, confirmedExampleCount: 2, status: .automatic),
                "SPEAKER_1": SpeakerMatch(profileID: "p1", name: "Bob", distance: 0.25, margin: nil, confirmedExampleCount: 1, status: .suggested),
            ],
            dismissedSpeakers: ["SPEAKER_1"],
            exports: [
                ExportRecord(path: "/notes/z.txt", format: "txt", sha256: String(repeating: "1", count: 64), exportedAt: Date(timeIntervalSince1970: 1_700_000_300)),
                ExportRecord(path: "/notes/a.srt", format: "srt", sha256: String(repeating: "2", count: 64), exportedAt: Date(timeIntervalSince1970: 1_700_000_100)),
            ]
        )
    }

    func testManagedAndPortableRoundTripPreservesEveryField() throws {
        let original = exhaustiveDocument()
        // Guard the fixture itself: a populated field must differ from the
        // value a dropped column would decode as.
        XCTAssertNotNil(original.audioFiles)
        XCTAssertNotNil(original.sourceMetadata?.voiceMemos)
        XCTAssertNotNil(original.output.speakersDetected)
        XCTAssertNotEqual(original.output.speakerStrategy, TranscriptionOutput(segments: [], language: nil, durationSeconds: 0).speakerStrategy)

        let id = try CanonicalTranscriptStore.saveManaged(original)
        let managed = try CanonicalTranscriptStore.load(id: id)
        XCTAssertEqual(managed, original, "managed storage round-trips every field")

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("copy.transcript.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try CanonicalTranscriptStore.save(managed, to: url)
        let portable = try CanonicalTranscriptStore.load(from: url)
        XCTAssertEqual(portable, managed, "portable JSON of a managed document decodes identically")
        XCTAssertEqual(portable.createdAt, original.createdAt)
        XCTAssertEqual(portable.exports?.map(\.exportedAt), original.exports?.map(\.exportedAt))
    }

    func testStoredDatesAreWholeSecondsLikePortableJSON() throws {
        let base = document()
        let fractional = CanonicalTranscript(
            id: base.id, evidenceID: base.evidenceID, sourceHashes: base.sourceHashes,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000.75), model: base.model,
            transcribeVersion: base.transcribeVersion, audioPath: base.audioPath,
            basename: base.basename, output: base.output
        )
        let id = try CanonicalTranscriptStore.saveManaged(fractional)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("copy.transcript.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try CanonicalTranscriptStore.save(fractional, to: url)

        XCTAssertEqual(try CanonicalTranscriptStore.load(id: id).createdAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(try CanonicalTranscriptStore.load(id: id).createdAt, try CanonicalTranscriptStore.load(from: url).createdAt)
    }

    /// A document spans several tables. Materializing it inside one read
    /// transaction pins one snapshot, so a writer committing between the
    /// reader's queries cannot yield a document mixing two generations.
    func testMaterializationInsideAReadTransactionSeesOneGeneration() throws {
        let suggested = SpeakerMatch(profileID: "a", name: "Alice", distance: 0.2, margin: nil, confirmedExampleCount: 1, status: .suggested)
        let id = try CanonicalTranscriptStore.saveManaged(document(matches: ["SPEAKER_0": suggested]))
        let reader = try StateDatabase()
        defer { reader.close() }

        let seen = try reader.inTransaction(.read) { () -> CanonicalTranscript in
            // The first query fixes the snapshot, as materialize's first
            // query does.
            let before = try reader.query("SELECT count(*) FROM documents") { $0.int(0) ?? 0 }
            XCTAssertEqual(before, [1])

            // Another connection commits a new generation: different
            // matches, dismissals, and exports.
            var edited = try CanonicalTranscriptStore.load(id: id)
            edited.speakerMatches = [:]
            edited.dismissedSpeakers = ["SPEAKER_0"]
            edited.exports = []
            try CanonicalTranscriptStore.save(edited, to: .managed(id: id))

            return try CanonicalTranscriptStore.materialize(id: id, in: reader)
        }
        XCTAssertEqual(seen.speakerMatches, ["SPEAKER_0": suggested], "the snapshot predates the commit")
        XCTAssertNil(seen.dismissedSpeakers, "no table is read from the later generation")
        XCTAssertNil(seen.exports)

        let after = try reader.inTransaction(.read) { try CanonicalTranscriptStore.materialize(id: id, in: reader) }
        XCTAssertEqual(after.speakerMatches, [:])
        XCTAssertEqual(after.dismissedSpeakers, ["SPEAKER_0"])
        XCTAssertEqual(after.exports, [])
    }

    func testExplicitDestinationSaveDoesNotTouchTheManagedStore() throws {
        let managed = try CanonicalTranscriptStore.saveManaged(document(output: output(saying: "Managed")))
        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("copy.transcript.json")
        defer { try? FileManager.default.removeItem(at: external.deletingLastPathComponent()) }

        let written = try CanonicalTranscriptStore.save(document(output: output(saying: "Copy")), to: external)

        XCTAssertEqual(written, external)
        XCTAssertEqual(try storedIDs(), [managed])
        XCTAssertEqual(try CanonicalTranscriptStore.load(id: managed).output.segments.map(\.text), ["Managed"])
    }

    // MARK: - Portable fields

    func testExportRecordsRoundTripAndDecodeAsNilWhenAbsent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("document.json")
        var withRecords = document()
        withRecords.exports = [
            ExportRecord(path: "/notes/meeting.txt", format: "txt", sha256: String(repeating: "a", count: 64), exportedAt: Date(timeIntervalSince1970: 1_700_000_100)),
        ]
        _ = try CanonicalTranscriptStore.save(withRecords, to: url)
        XCTAssertEqual(try CanonicalTranscriptStore.load(from: url).exports, withRecords.exports)

        let plain = directory.appendingPathComponent("plain.json")
        _ = try CanonicalTranscriptStore.save(document(), to: plain)
        XCTAssertFalse(try String(contentsOf: plain).contains("\"exports\""), "absent records add no key")
        XCTAssertNil(try CanonicalTranscriptStore.load(from: plain).exports, "documents from before the feature decode with nil records")
    }

    func testDismissedSpeakersRoundTripAndStayAbsentWhenUnset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("document.json")
        var withDismissal = document()
        withDismissal.dismissedSpeakers = ["SPEAKER_0"]
        _ = try CanonicalTranscriptStore.save(withDismissal, to: url)
        XCTAssertEqual(try CanonicalTranscriptStore.load(from: url).dismissedSpeakers, ["SPEAKER_0"])

        let plain = directory.appendingPathComponent("plain.json")
        _ = try CanonicalTranscriptStore.save(document(), to: plain)
        XCTAssertFalse(try String(contentsOf: plain).contains("dismissedSpeakers"), "absent dismissals add no key")
        XCTAssertNil(try CanonicalTranscriptStore.load(from: plain).dismissedSpeakers)
    }

    func testValidationRejectsBadDismissedSpeakers() throws {
        for dismissed in [["SPEAKER_9"], ["SPEAKER_0", "SPEAKER_0"], [], ["evil"]] {
            var invalid = document()
            invalid.dismissedSpeakers = dismissed
            XCTAssertThrowsError(try CanonicalTranscriptStore.validate(invalid), "\(dismissed)")
        }
    }

    func testValidationRejectsBadExportRecords() throws {
        for record in [
            ExportRecord(path: "relative/meeting.txt", format: "txt", sha256: String(repeating: "a", count: 64), exportedAt: Date()),
            ExportRecord(path: "/notes/meeting.txt", format: "txt", sha256: "not-a-hash", exportedAt: Date()),
            ExportRecord(path: "/notes/meeting.doc", format: "doc", sha256: String(repeating: "a", count: 64), exportedAt: Date()),
            ExportRecord(path: "/etc/hosts", format: "txt", sha256: String(repeating: "a", count: 64), exportedAt: Date()),
            ExportRecord(path: "/notes/meeting.txt", format: "md", sha256: String(repeating: "a", count: 64), exportedAt: Date()),
        ] {
            var invalid = document()
            invalid.exports = [record]
            XCTAssertThrowsError(try CanonicalTranscriptStore.validate(invalid), record.path)
            XCTAssertThrowsError(try CanonicalTranscriptStore.saveManaged(invalid), "managed saves validate too: \(record.path)")
        }
        XCTAssertTrue(try storedIDs().isEmpty)
    }
}
