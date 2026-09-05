import Foundation
import XCTest
@testable import transcribe

final class SpeakerProfilesTests: XCTestCase {
    private var state: URL!
    private var previousState: String?

    override func setUpWithError() throws {
        previousState = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        state = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-profiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        setenv("XDG_STATE_HOME", state.path, 1)
    }

    override func tearDownWithError() throws {
        if let previousState { setenv("XDG_STATE_HOME", previousState, 1) }
        else { unsetenv("XDG_STATE_HOME") }
        try? FileManager.default.removeItem(at: state)
    }

    @discardableResult
    private func confirm(_ evidence: String, name: String = "Alice", id: String? = nil,
                         vector: [Float] = [1, 0], sources: [String] = []) throws -> SpeakerMatch {
        try SpeakerProfileStore.confirm(name: name, profileID: id, transcriptID: evidence,
                                        speakerID: "SPEAKER_0", embedding: vector, modelID: "m", sourceHashes: sources)
    }

    private func match(_ vector: [Float] = [1, 0], excluding: String? = nil,
                       sources: [String] = []) throws -> SpeakerMatch? {
        try SpeakerProfileStore.matches(embeddings: ["local": vector], modelID: "m",
                                        excludingTranscriptID: excluding, excludingSourceHashes: sources)["local"]
    }

    func testRepeatedNameAndProfileConfirmationAreIdempotent() throws {
        let first = try confirm("one")
        XCTAssertEqual(try confirm("one").profileID, first.profileID)
        try confirm("one", id: first.profileID)
        XCTAssertEqual(try SpeakerProfileStore.profiles().count, 1)
        XCTAssertEqual(try SpeakerProfileStore.profiles().first?.examples.count, 1)
        XCTAssertEqual(try match()?.status, .suggested)
    }

    func testTwoIndependentStrongExamplesBecomeAutomatic() throws {
        let first = try confirm("one")
        try confirm("two", id: first.profileID, vector: [0.99, 0.01])
        XCTAssertEqual(try match()?.status, .automatic)
        XCTAssertEqual(try match()?.confirmedExampleCount, 2)
        XCTAssertNil(try match()?.margin)
    }

    func testSelfAndOverlappingEvidenceDoNotSupportAutomaticMatch() throws {
        let first = try confirm("one", sources: ["a", "b"])
        try confirm("two", id: first.profileID, sources: ["b", "c"])
        XCTAssertEqual(try match()?.status, .suggested)
        XCTAssertEqual(try match(excluding: "one")?.status, .suggested)
        XCTAssertNil(try match(sources: ["b"]))
    }

    func testIndependentPairCanBeFoundAfterOverlappingNearestExamples() throws {
        let first = try confirm("one", sources: ["a"])
        try confirm("two", id: first.profileID, vector: [1, 0.01], sources: ["a", "b"])
        try confirm("three", id: first.profileID, vector: [1, 0.02], sources: ["c"])
        XCTAssertEqual(try match()?.status, .automatic)
    }

    func testSimilarCompetingProfileKeepsMatchSuggested() throws {
        let alice = try confirm("one")
        try confirm("two", id: alice.profileID)
        try confirm("three", name: "Bob", vector: [0.99, 0.01])
        XCTAssertEqual(try match()?.status, .suggested)
        XCTAssertLessThan(try XCTUnwrap(match()?.margin), SpeakerProfileStore.marginThreshold)
    }

    func testDistinctCompetitorAllowsAutomaticMatch() throws {
        let alice = try confirm("one")
        try confirm("two", id: alice.profileID)
        try confirm("three", name: "Bob", vector: [0, 1])
        XCTAssertEqual(try match()?.status, .automatic)
    }

    func testWeakSecondExampleCannotEnableAutomaticMatch() throws {
        let alice = try confirm("one")
        try confirm("two", id: alice.profileID, vector: [0, 1])
        XCTAssertEqual(try match()?.status, .suggested)
        XCTAssertNil(try match([-1, 0]))
    }

    func testConflictingAutomaticLocalSpeakersAreDemoted() throws {
        let alice = try confirm("one")
        try confirm("two", id: alice.profileID)
        let matches = try SpeakerProfileStore.matches(embeddings: ["a": [1, 0], "b": [1, 0]], modelID: "m")
        XCTAssertEqual(matches["a"]?.status, .suggested)
        XCTAssertEqual(matches["b"]?.status, .suggested)
    }

    func testExplicitConfirmationTakesPrecedenceOverAutomaticConflict() {
        let confirmed = SpeakerMatch(profileID: "p", name: "Alice", distance: 0, margin: nil,
                                     confirmedExampleCount: 1, status: .confirmed)
        let automatic = SpeakerMatch(profileID: "p", name: "Alice", distance: 0, margin: nil,
                                     confirmedExampleCount: 2, status: .automatic)
        let matches = SpeakerProfileStore.demoteConflictingAutomaticMatches(["a": confirmed, "b": automatic])
        XCTAssertEqual(matches["a"]?.status, .confirmed)
        XCTAssertEqual(matches["b"]?.status, .suggested)
    }

    func testCorrectionMovesEvidenceWithoutRenamingOldPerson() throws {
        let alice = try confirm("one")
        try confirm("two", id: alice.profileID)
        let bob = try confirm("one", name: "Bob")
        XCTAssertNotEqual(alice.profileID, bob.profileID)
        let profiles = try SpeakerProfileStore.profiles()
        XCTAssertEqual(profiles.first { $0.id == alice.profileID }?.name, "Alice")
        XCTAssertEqual(profiles.first { $0.id == alice.profileID }?.examples.count, 1)
        XCTAssertEqual(profiles.first { $0.id == bob.profileID }?.examples.count, 1)
        try confirm("one", name: "Alice", id: alice.profileID)
        XCTAssertEqual(try SpeakerProfileStore.profiles().first { $0.id == bob.profileID }?.examples.count, 0)
    }

    func testWrongModelAndDimensionDoNotMatch() throws {
        try confirm("one")
        XCTAssertTrue(try SpeakerProfileStore.matches(embeddings: ["s": [1, 0]], modelID: "other").isEmpty)
        XCTAssertTrue(try SpeakerProfileStore.matches(embeddings: ["s": [1, 0, 0]], modelID: "m").isEmpty)
        XCTAssertThrowsError(try confirm("two", vector: [1, 0, 0]))
        XCTAssertEqual(try SpeakerProfileStore.profiles().first?.examples.count, 1)
    }

    func testInvalidVectorsAndNamesAreRejectedBeforeSaving() throws {
        for vector: [Float] in [[], [0, 0], [.nan, 0], [.infinity, 0]] {
            XCTAssertThrowsError(try confirm("bad", vector: vector))
        }
        XCTAssertThrowsError(try confirm("bad", name: "  "))
        XCTAssertThrowsError(try confirm("bad", name: "A\nB"))
        XCTAssertTrue(try SpeakerProfileStore.profiles().isEmpty)
    }

    func testLargeFiniteEmbeddingsHaveFiniteDistance() throws {
        try confirm("one", vector: [Float.greatestFiniteMagnitude, 0])
        XCTAssertEqual(try match([Float.greatestFiniteMagnitude, 0])?.distance, 0)
    }

    func testRenameRemoveAndDelete() throws {
        let alice = try confirm("one")
        try SpeakerProfileStore.rename(profileID: alice.profileID, name: "Alicia")
        XCTAssertEqual(try match()?.name, "Alicia")
        try SpeakerProfileStore.removeExample(profileID: alice.profileID, transcriptID: "one", speakerID: "SPEAKER_0")
        XCTAssertNil(try match())
        try SpeakerProfileStore.delete(profileID: alice.profileID)
        XCTAssertTrue(try SpeakerProfileStore.profiles().isEmpty)
        XCTAssertThrowsError(try SpeakerProfileStore.delete(profileID: alice.profileID))
    }

    func testClearExamplesPreservesOtherEvidenceAndIsIdempotent() throws {
        try confirm("one")
        try confirm("two")
        try SpeakerProfileStore.clearExamples(transcriptID: "one", speakerID: "SPEAKER_0")
        try SpeakerProfileStore.clearExamples(transcriptID: "one", speakerID: "SPEAKER_0")
        XCTAssertEqual(try SpeakerProfileStore.profiles().flatMap(\.examples).map(\.transcriptID), ["two"])
    }

    func testCorruptAndUnknownSchemaStoresRemainUntouched() throws {
        try confirm("one")
        let url = try StatePaths.stateDirectoryURL().appendingPathComponent("speaker_profiles.json")
        for contents in ["not JSON", "{\"schema_version\":99,\"profiles\":[]}"] {
            let bytes = Data(contents.utf8)
            try bytes.write(to: url)
            XCTAssertThrowsError(try SpeakerProfileStore.profiles())
            XCTAssertThrowsError(try confirm("two"))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testDuplicateProfilesAreRejected() throws {
        try confirm("one")
        let url = try StatePaths.stateDirectoryURL().appendingPathComponent("speaker_profiles.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let profile = try XCTUnwrap((json["profiles"] as? [[String: Any]])?.first)
        json["profiles"] = [profile, profile]
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        XCTAssertThrowsError(try SpeakerProfileStore.profiles())
    }

    func testStoreAndLockArePrivateAndNoTemporaryFilesRemain() throws {
        try confirm("one")
        try confirm("two")
        let directory = try StatePaths.stateDirectoryURL()
        for name in ["speaker_profiles.json", "speaker_profiles.json.lock"] {
            let mode = try XCTUnwrap(fileModeBits(atPath: directory.appendingPathComponent(name).path))
            XCTAssertEqual(mode & 0o777, 0o600)
        }
        XCTAssertEqual(try XCTUnwrap(fileModeBits(atPath: directory.path)) & 0o777, 0o700)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasSuffix(".tmp") })
    }

    /// The state directory is shared with timing and processing history, so
    /// its permissions belong to the user once it exists.
    func testExistingStateDirectoryKeepsItsPermissions() throws {
        let directory = try StatePaths.stateDirectoryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)

        try confirm("one")
        XCTAssertEqual(try SpeakerProfileStore.profiles().count, 1)

        XCTAssertEqual(try XCTUnwrap(fileModeBits(atPath: directory.path)) & 0o777, 0o755)
        let store = directory.appendingPathComponent("speaker_profiles.json")
        XCTAssertEqual(try XCTUnwrap(fileModeBits(atPath: store.path)) & 0o777, 0o600)
    }
}
