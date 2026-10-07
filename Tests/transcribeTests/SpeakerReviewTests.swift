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

    private func session(
        _ io: ScriptedIO, includeConfirmed: Bool = false, refreshExports: Bool = true
    ) -> SpeakerReview.Session {
        SpeakerReview.Session(
            io: io.io, color: .disabled,
            includeConfirmed: includeConfirmed, refreshExports: refreshExports
        )
    }

    /// Exports the document's txt beside the test directory and re-saves the
    /// document with the matching export record, as a real export would.
    private func seedTxtExport(at url: URL) throws -> URL {
        var document = try CanonicalTranscriptStore.load(from: url)
        let out = directory.appendingPathComponent("exports-\(document.basename)")
        let records = try writeOutputs(
            output: document.output, audioPath: document.audioPath,
            outputDir: out.path, basename: document.basename, formats: ["txt"],
            overwrite: true, model: document.model, version: document.transcribeVersion,
            createdAt: document.createdAt
        )
        document.exports = records
        _ = try CanonicalTranscriptStore.save(document, to: url)
        return out.appendingPathComponent("\(document.basename).txt")
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
        XCTAssertEqual(ReviewReply.parse("m"), .moreSamples)
        XCTAssertEqual(ReviewReply.parse("M"), .moreSamples)
        XCTAssertEqual(ReviewReply.parse("u"), .dismiss)
        XCTAssertEqual(ReviewReply.parse("U"), .dismiss)
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

    func testSampleSelectionExcludingNeverRepeatsAndExhaustsEverySegment() {
        var segments: [TranscriptSegment] = []
        for index in 0..<12 {
            segments.append(segment(
                "SPEAKER_0", Double(index * 10),
                "Sample number \(index) with several spoken words here."
            ))
        }
        var shown = SpeakerReview.selectSamples(from: segments, speaker: "SPEAKER_0")
        XCTAssertEqual(shown.count, 3)
        while true {
            let more = SpeakerReview.selectSamples(from: segments, speaker: "SPEAKER_0", excluding: shown)
            if more.isEmpty { break }
            XCTAssertTrue(
                Set(more.map(\.start)).isDisjoint(with: shown.map(\.start)),
                "a later batch repeats an already shown segment"
            )
            if more.count == 3 {
                XCTAssertGreaterThan(
                    more[2].start - more[0].start, 30,
                    "later batches still spread across the recording"
                )
            }
            shown += more
        }
        XCTAssertEqual(shown.count, segments.count, "every qualifying segment eventually appears")
        XCTAssertTrue(
            SpeakerReview.selectSamples(from: segments, speaker: "SPEAKER_0", excluding: shown).isEmpty,
            "exhausted selection stays empty"
        )
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

    // MARK: - More samples

    func testMoreSamplesShowsNewSegmentsThenReportsExhaustion() throws {
        var segments: [TranscriptSegment] = []
        for index in 0..<6 {
            segments.append(segment(
                "SPEAKER_0", Double(index * 10),
                "Sample number \(index) with several spoken words here."
            ))
        }
        let url = try document("one", hash: "a", segments: segments)
        let scripted = ScriptedIO(["m", "m", "s"])
        try session(scripted).run(documents: [url])
        for index in 0..<6 {
            // The scripted prompt has no terminal echo, so samples can share a
            // line with the prompt; count occurrences rather than lines.
            let occurrences = scripted.output.components(separatedBy: "Sample number \(index) ").count - 1
            XCTAssertEqual(occurrences, 1, "segment \(index) shown exactly once across the two batches")
        }
        XCTAssertTrue(scripted.output.contains("No more samples for this speaker."), scripted.output)
        XCTAssertNil(try CanonicalTranscriptStore.load(from: url).speakerMatches["SPEAKER_0"], "showing samples decides nothing")
    }

    // MARK: - Dismissal

    func testDismissPersistsAndStopsPrompting() throws {
        let url = try document("one", hash: "a")
        let scripted = ScriptedIO(["u"])
        try session(scripted).run(documents: [url])
        XCTAssertTrue(scripted.output.contains("Marked SPEAKER_0 as unidentifiable"), scripted.output)
        let saved = try CanonicalTranscriptStore.load(from: url)
        XCTAssertEqual(saved.dismissedSpeakers, ["SPEAKER_0"])
        XCTAssertNil(saved.speakerMatches["SPEAKER_0"])
        XCTAssertFalse(
            session(ScriptedIO([])).needsAttention(try SpeakerCommands.refreshedDocument(at: url)),
            "a dismissed speaker is not prompted again"
        )
        XCTAssertTrue(
            session(ScriptedIO([]), includeConfirmed: true).needsAttention(saved),
            "--all still revisits a dismissed speaker"
        )
    }

    func testDismissedSpeakerGetsNoFreshSuggestion() throws {
        let one = try document("one", hash: "a")
        try session(ScriptedIO(["Dave"])).run(documents: [one])
        let two = try document("two", hash: "b")
        XCTAssertEqual(
            try SpeakerCommands.refreshedDocument(at: two).speakerMatches["SPEAKER_0"]?.status,
            .suggested, "the matching voice is suggested before dismissal"
        )
        try session(ScriptedIO(["u"])).run(documents: [two])
        XCTAssertNil(
            try SpeakerCommands.refreshedDocument(at: two).speakerMatches["SPEAKER_0"],
            "refresh must not resurrect a dismissed speaker as a suggestion"
        )
    }

    func testConfirmingUnderAllClearsDismissal() throws {
        let url = try document("one", hash: "a")
        try session(ScriptedIO(["u"])).run(documents: [url])
        let revisit = ScriptedIO(["Dave"])
        try session(revisit, includeConfirmed: true).run(documents: [url])
        XCTAssertTrue(revisit.output.contains("marked unidentifiable"), "the mark is shown when revisiting")
        let saved = try CanonicalTranscriptStore.load(from: url)
        XCTAssertNil(saved.dismissedSpeakers, "a confirmed name removes the mark")
        XCTAssertEqual(saved.speakerMatches["SPEAKER_0"]?.status, .confirmed)
    }

    func testDismissingAConfirmedSpeakerWithdrawsItsExample() throws {
        let url = try document("one", hash: "a")
        try session(ScriptedIO(["Dave"])).run(documents: [url])
        XCTAssertEqual(try SpeakerProfileStore.profiles().first?.examples.count, 1)
        try session(ScriptedIO(["u"]), includeConfirmed: true).run(documents: [url])
        let saved = try CanonicalTranscriptStore.load(from: url)
        XCTAssertEqual(saved.dismissedSpeakers, ["SPEAKER_0"])
        XCTAssertNil(saved.speakerMatches["SPEAKER_0"])
        XCTAssertEqual(
            try SpeakerProfileStore.profiles().first?.examples.count, 0,
            "dismissing a confirmed speaker withdraws the voice example, like clear"
        )
    }

    // MARK: - Export refresh

    func testSessionRefreshesRecordedExportsAfterConfirmation() throws {
        let url = try document("one", hash: "a")
        let txt = try seedTxtExport(at: url)
        XCTAssertTrue(try String(contentsOf: txt).contains("SPEAKER_0"))

        let scripted = ScriptedIO(["Siva"])
        try session(scripted).run(documents: [url])

        XCTAssertTrue(try String(contentsOf: txt).contains("Siva"), "recorded export picks up the new name")
        XCTAssertTrue(scripted.output.contains("Refreshed 1 export"), scripted.output)
        XCTAssertFalse(scripted.output.contains("Export again to update rendered files."), scripted.output)
    }

    func testSessionWithoutRefreshKeepsFilesAndClosingHint() throws {
        let url = try document("one", hash: "a")
        let txt = try seedTxtExport(at: url)

        let scripted = ScriptedIO(["Siva"])
        try session(scripted, refreshExports: false).run(documents: [url])

        XCTAssertFalse(try String(contentsOf: txt).contains("Siva"), "disabled refresh leaves files stale")
        XCTAssertTrue(scripted.output.contains("Export again to update rendered files."), scripted.output)
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
