import Foundation
import XCTest
@testable import transcribe

final class SpeakerReviewTests: XCTestCase {
    private var directory: URL!
    private var previousState: String?

    override func setUpWithError() throws {
        previousState = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("XDG_STATE_HOME", directory.path, 1)
    }

    override func tearDownWithError() throws {
        if let previousState { setenv("XDG_STATE_HOME", previousState, 1) }
        else { unsetenv("XDG_STATE_HOME") }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    private func segment(_ speaker: String, _ start: Double, _ text: String) -> TranscriptSegment {
        TranscriptSegment(speaker: speaker, start: start, end: start + 2, text: text, words: nil)
    }

    private func document(
        _ name: String, hash: String,
        segments: [TranscriptSegment]? = nil,
        embeddings: [String: [Float]] = ["SPEAKER_0": [1, 0]]
    ) throws -> URL {
        let hashes = [String(repeating: hash, count: 64)]
        let result = CanonicalTranscript(
            evidenceID: CanonicalTranscript.evidenceID(forSourceHashes: hashes), sourceHashes: hashes,
            model: "intentionally-unavailable-model", transcribeVersion: Transcribe.version,
            audioPath: "/does/not/exist.wav", basename: name,
            output: TranscriptionOutput(
                segments: segments ?? [segment("SPEAKER_0", 1, "Hello there world, how are you.")],
                language: "en", durationSeconds: 60, diarizationEnabled: true,
                speakersDetected: embeddings.count,
                speakerEmbeddings: embeddings
            )
        )
        let url = directory.appendingPathComponent(name + ".transcript.json")
        _ = try CanonicalTranscriptStore.save(result, to: url)
        return url
    }

    private final class ScriptedIO {
        var inputs: [String]
        var output = ""
        init(_ inputs: [String]) { self.inputs = inputs }
        var io: InteractiveIO {
            InteractiveIO(
                readLine: { [self] in inputs.isEmpty ? nil : inputs.removeFirst() },
                write: { [self] text in output += text }
            )
        }
    }

    private func session(_ io: ScriptedIO, includeConfirmed: Bool = false) -> SpeakerReview.Session {
        SpeakerReview.Session(io: io.io, color: .disabled, includeConfirmed: includeConfirmed)
    }

    // MARK: - Reply parsing

    func testReplyParsing() {
        XCTAssertEqual(ReviewReply.parse(nil), .quit)
        XCTAssertEqual(ReviewReply.parse(""), .acceptDefault)
        XCTAssertEqual(ReviewReply.parse("  "), .acceptDefault)
        XCTAssertEqual(ReviewReply.parse("l"), .listProfiles)
        XCTAssertEqual(ReviewReply.parse("L"), .listProfiles)
        XCTAssertEqual(ReviewReply.parse("s"), .skip)
        XCTAssertEqual(ReviewReply.parse("q"), .quit)
        XCTAssertEqual(ReviewReply.parse("2"), .profileIndex(2))
        XCTAssertEqual(ReviewReply.parse(" Dave Beckett "), .name("Dave Beckett"))
        XCTAssertEqual(ReviewReply.parse("lars"), .name("lars"))
    }

    // MARK: - Sample selection

    func testSampleSelectionSpreadsAcrossTranscriptAndSkipsFragments() {
        var segments: [TranscriptSegment] = []
        for index in 0..<30 {
            let words = index % 3 == 0 ? "Yeah." : "Segment number \(index) with several words spoken here."
            segments.append(segment("SPEAKER_0", Double(index * 10), words))
            segments.append(segment("SPEAKER_1", Double(index * 10 + 5), "Other speaker text at \(index)."))
        }
        let samples = SpeakerReview.selectSamples(from: segments, speaker: "SPEAKER_0")
        XCTAssertEqual(samples.count, 3)
        XCTAssertTrue(samples.allSatisfy { $0.speaker == "SPEAKER_0" })
        XCTAssertTrue(samples.allSatisfy { !$0.text.hasPrefix("Yeah") }, "fragments are filtered out")
        XCTAssertLessThan(samples[0].start, samples[1].start)
        XCTAssertLessThan(samples[1].start, samples[2].start)
        XCTAssertGreaterThan(samples[2].start - samples[0].start, 90, "samples span the recording, not the head")
    }

    func testSampleSelectionFallsBackWhenAllSegmentsAreShort() {
        let segments = [segment("SPEAKER_0", 0, "Yes."), segment("SPEAKER_0", 5, "No.")]
        let samples = SpeakerReview.selectSamples(from: segments, speaker: "SPEAKER_0")
        XCTAssertEqual(samples.count, 2, "short segments are better than nothing")
    }

    // MARK: - Interactive sessions

    func testTypedNameCreatesProfileAndConfirms() throws {
        let url = try document("one", hash: "a")
        let scripted = ScriptedIO(["Siva"])
        try session(scripted).run(documents: [url])
        let profiles = try SpeakerProfileStore.profiles()
        XCTAssertEqual(profiles.map(\.name), ["Siva"])
        XCTAssertEqual(try CanonicalTranscriptStore.load(from: url).speakerMatches["SPEAKER_0"]?.status, .confirmed)
        XCTAssertTrue(scripted.output.contains("Confirmed SPEAKER_0 as Siva"))
        XCTAssertTrue(scripted.output.contains("Hello there world"), "shows a speech sample")
    }

    func testTypedNameMatchesExistingProfileCaseInsensitively() throws {
        let one = try document("one", hash: "a")
        try session(ScriptedIO(["Dave"])).run(documents: [one])
        let two = try document("two", hash: "b")
        try session(ScriptedIO(["dave"])).run(documents: [two])
        let profiles = try SpeakerProfileStore.profiles()
        XCTAssertEqual(profiles.count, 1, "case-variant name must not create a duplicate profile")
        XCTAssertEqual(profiles.first?.examples.count, 2)
    }

    func testEmptyInputAcceptsSuggestionAndSkipsWithoutOne() throws {
        let one = try document("one", hash: "a")
        try session(ScriptedIO(["Dave"])).run(documents: [one])
        let two = try document("two", hash: "b")
        let scripted = ScriptedIO([""])
        try session(scripted).run(documents: [two])
        XCTAssertTrue(scripted.output.contains("suggested: Dave"))
        XCTAssertEqual(try CanonicalTranscriptStore.load(from: two).speakerMatches["SPEAKER_0"]?.status, .confirmed)
        XCTAssertEqual(try SpeakerProfileStore.profiles().first?.examples.count, 2)

        let three = try document("three", hash: "c", embeddings: ["SPEAKER_0": [0, 1]])
        let noSuggestion = ScriptedIO([""])
        try session(noSuggestion).run(documents: [three])
        XCTAssertNil(try CanonicalTranscriptStore.load(from: three).speakerMatches["SPEAKER_0"], "empty input without a suggestion skips")
    }

    func testProfileMenuSelection() throws {
        let one = try document("one", hash: "a")
        try session(ScriptedIO(["Dave"])).run(documents: [one])
        let two = try document("two", hash: "b", embeddings: ["SPEAKER_0": [0, 1]])
        let scripted = ScriptedIO(["l", "9", "1"])
        try session(scripted).run(documents: [two])
        XCTAssertTrue(scripted.output.contains("1  Dave"), "menu lists profiles")
        XCTAssertTrue(scripted.output.contains("No profile numbered 9"))
        XCTAssertEqual(try CanonicalTranscriptStore.load(from: two).speakerMatches["SPEAKER_0"]?.name, "Dave")
    }

    func testQuitAppliesEarlierDecisionsAndStopsLaterDocuments() throws {
        let segments = [
            segment("SPEAKER_0", 0, "First speaker saying quite a few words."),
            segment("SPEAKER_1", 3, "Second speaker also saying quite a few words."),
        ]
        let one = try document(
            "one", hash: "a", segments: segments,
            embeddings: ["SPEAKER_0": [1, 0], "SPEAKER_1": [0, 1]]
        )
        let two = try document("two", hash: "b")
        let scripted = ScriptedIO(["Dave", "q"])
        try session(scripted).run(documents: [one, two])
        let document = try CanonicalTranscriptStore.load(from: one)
        XCTAssertEqual(document.speakerMatches["SPEAKER_0"]?.name, "Dave", "decision before quit is applied")
        XCTAssertNil(document.speakerMatches["SPEAKER_1"])
        XCTAssertNil(try CanonicalTranscriptStore.load(from: two).speakerMatches["SPEAKER_0"], "later documents are not visited")
        XCTAssertFalse(scripted.output.contains("two —"), "no header for unvisited document")
    }

    func testSkipWritesNothing() throws {
        let url = try document("one", hash: "a")
        let before = try Data(contentsOf: url)
        try session(ScriptedIO(["s"])).run(documents: [url])
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertTrue(try SpeakerProfileStore.profiles().isEmpty)
    }

    func testConfirmedSpeakersOnlyRevisitedWithIncludeConfirmed() throws {
        let url = try document("one", hash: "a")
        try session(ScriptedIO(["Dave"])).run(documents: [url])
        let settled = try SpeakerCommands.refreshedDocument(at: url)
        XCTAssertFalse(session(ScriptedIO([])).needsAttention(settled))

        let corrective = ScriptedIO(["Matt"])
        try session(corrective, includeConfirmed: true).run(documents: [url])
        XCTAssertTrue(corrective.output.contains("confirmed: Dave"), "current name is shown when revisiting")
        XCTAssertEqual(try CanonicalTranscriptStore.load(from: url).speakerMatches["SPEAKER_0"]?.name, "Matt")
    }

    func testEndOfInputQuitsCleanly() throws {
        let url = try document("one", hash: "a")
        try session(ScriptedIO([])).run(documents: [url])
        XCTAssertNil(try CanonicalTranscriptStore.load(from: url).speakerMatches["SPEAKER_0"])
    }

    // MARK: - Color gating

    func testColorDetection() {
        func detect(_ environment: [String: String], fd: Int32 = -1) -> Bool {
            TerminalColor.detect(fileDescriptor: fd, environment: environment).enabled
        }
        XCTAssertFalse(detect(["TERM": "xterm-256color"]), "not a terminal")
        XCTAssertFalse(detect(["TERM": "dumb", "CLICOLOR_FORCE": "0"]))
        XCTAssertFalse(detect([:]), "no TERM")
        XCTAssertFalse(detect(["TERM": "xterm", "NO_COLOR": "", "CLICOLOR_FORCE": "1"]), "NO_COLOR wins")
        XCTAssertTrue(detect(["CLICOLOR_FORCE": "1"]), "forced onto a pipe")
    }

    func testStylingWrapsOnlyWhenEnabled() {
        XCTAssertEqual(TerminalColor.disabled.green("ok"), "ok")
        XCTAssertEqual(TerminalColor(enabled: true).green("ok"), "\u{1B}[32mok\u{1B}[0m")
        XCTAssertEqual(TerminalColor(enabled: true).bold("b"), "\u{1B}[1mb\u{1B}[0m")
    }

    func testSessionOutputCarriesColorWhenEnabled() throws {
        let url = try document("one", hash: "a")
        let scripted = ScriptedIO(["Dave"])
        var colored = session(scripted)
        colored.color = TerminalColor(enabled: true)
        try colored.run(documents: [url])
        XCTAssertTrue(scripted.output.contains("\u{1B}["), "styled session output contains ANSI sequences")
    }
}
