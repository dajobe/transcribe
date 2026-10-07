import CryptoKit
import Foundation
import XCTest
@testable import transcribe

final class ProcessingStoreTests: XCTestCase {
    func testFingerprintChangesWhenContentChanges() throws {
        let dir = try makeTempDir()
        let file = dir.appendingPathComponent("clip.m4a")
        try Data("one".utf8).write(to: file)
        let first = try ProcessingStore.fingerprint(files: [file.path])

        try Data("two".utf8).write(to: file)
        let second = try ProcessingStore.fingerprint(files: [file.path])

        XCTAssertNotEqual(first, second)
    }

    func testFingerprintStreamingMatchesWholeFileHashAcrossChunks() throws {
        // The streaming reader uses 1 MiB chunks; build a > 2 MiB payload so
        // the hash is composed from at least three chunks and pin that the
        // result equals the one-shot SHA256.
        let dir = try makeTempDir()
        let file = dir.appendingPathComponent("big.bin")
        var bytes = Data(count: 0)
        bytes.reserveCapacity(2 * 1024 * 1024 + 17)
        for index in 0..<(2 * 1024 * 1024 + 17) {
            bytes.append(UInt8(index & 0xff))
        }
        try bytes.write(to: file)

        let result = try ProcessingStore.fingerprint(files: [file.path])
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(result.files.count, 1)
        XCTAssertEqual(result.files[0].sha256, expected)
        XCTAssertEqual(result.files[0].bytes, Int64(bytes.count))
    }

    func testCompletedRecordSkipsOnlyWhenOutputsExist() throws {
        let state = try makeTempDir()
        let output = try makeTempDir()
        try withXDGStateHome(state.path) {
            let audio = output.appendingPathComponent("clip.m4a")
            try Data("audio".utf8).write(to: audio)
            let transcript = output.appendingPathComponent("clip.json")
            try Data("{}".utf8).write(to: transcript)
            let fingerprint = try ProcessingStore.fingerprint(files: [audio.path])
            let settings = sampleSettings()
            let sourceID = sourceIDForFiles(kind: .file, files: [audio.path])
            try ProcessingStore.append(ProcessingRecord(
                completed_at: iso8601String(Date()),
                history_reason: .firstRun,
                source_kind: .file,
                source_id: sourceID,
                source_fingerprint: fingerprint,
                settings_signature: settings,
                output_dir: output.path,
                basename: "clip",
                output_paths: [transcript.path],
                audio_duration_s: 1,
                warning_count: 0,
                recording_title: nil,
                recorded_at: nil,
                voice_memos_unique_id: nil,
                voice_memos_path: nil
            ))

            XCTAssertTrue(try ProcessingStore.shouldSkipCompleted(
                sourceKind: .file,
                sourceID: sourceID,
                fingerprint: fingerprint,
                settings: settings,
                outputPaths: [transcript.path]
            ))
            XCTAssertEqual(try ProcessingStore.completionDecision(
                sourceKind: .file,
                sourceID: sourceID,
                fingerprint: fingerprint,
                settings: settings,
                outputPaths: [transcript.path]
            ), ProcessingDecision(action: .skip, reason: .skipDuplicate))

            try FileManager.default.removeItem(at: transcript)
            XCTAssertFalse(try ProcessingStore.shouldSkipCompleted(
                sourceKind: .file,
                sourceID: sourceID,
                fingerprint: fingerprint,
                settings: settings,
                outputPaths: [transcript.path]
            ))
            XCTAssertEqual(try ProcessingStore.completionDecision(
                sourceKind: .file,
                sourceID: sourceID,
                fingerprint: fingerprint,
                settings: settings,
                outputPaths: [transcript.path]
            ), ProcessingDecision(action: .process, reason: .missingOutputs))
        }
    }

    func testCompletedRecordIgnoresTranscribeVersionForSkip() throws {
        let state = try makeTempDir()
        let output = try makeTempDir()
        try withXDGStateHome(state.path) {
            let audio = output.appendingPathComponent("clip.m4a")
            try Data("audio".utf8).write(to: audio)
            let transcript = output.appendingPathComponent("clip.json")
            try Data("{}".utf8).write(to: transcript)
            let fingerprint = try ProcessingStore.fingerprint(files: [audio.path])
            let sourceID = sourceIDForFiles(kind: .file, files: [audio.path])
            try ProcessingStore.append(ProcessingRecord(
                completed_at: iso8601String(Date()),
                history_reason: .firstRun,
                source_kind: .file,
                source_id: sourceID,
                source_fingerprint: fingerprint,
                settings_signature: sampleSettings(version: "2.4.0"),
                output_dir: output.path,
                basename: "clip",
                output_paths: [transcript.path],
                audio_duration_s: 1,
                warning_count: 0,
                recording_title: nil,
                recorded_at: nil,
                voice_memos_unique_id: nil,
                voice_memos_path: nil
            ))

            XCTAssertEqual(try ProcessingStore.completionDecision(
                sourceKind: .file,
                sourceID: sourceID,
                fingerprint: fingerprint,
                settings: sampleSettings(version: "2.4.3"),
                outputPaths: [transcript.path]
            ), ProcessingDecision(action: .skip, reason: .skipDuplicate))
        }
    }

    func testLegacyStdoutFalseRecordStillSkipsButLegacyStdoutTrueDoesNot() throws {
        let state = try makeTempDir()
        let output = try makeTempDir()
        try withXDGStateHome(state.path) {
            let audio = output.appendingPathComponent("clip.m4a")
            try Data("audio".utf8).write(to: audio)
            let transcript = output.appendingPathComponent("clip.txt")
            try Data("text".utf8).write(to: transcript)
            let fingerprint = try ProcessingStore.fingerprint(files: [audio.path])
            let sourceID = sourceIDForFiles(kind: .file, files: [audio.path])
            let settings = ProcessingSettingsSignature(
                model: "model",
                language: "en",
                diarization_enabled: false,
                speaker_strategy: "subsegment",
                min_speakers: nil,
                max_speakers: nil,
                formats: ["txt"],
                transcribe_version: "2.5.2"
            )

            try writeLegacyProcessingRecord(
                sourceID: sourceID,
                fingerprint: fingerprint,
                output: output,
                transcript: transcript,
                writeTxtToStdout: false
            )
            XCTAssertEqual(try ProcessingStore.completionDecision(
                sourceKind: .file,
                sourceID: sourceID,
                fingerprint: fingerprint,
                settings: settings,
                outputPaths: [transcript.path]
            ), ProcessingDecision(action: .skip, reason: .skipDuplicate))

            try StateStore.withDatabase { try $0.execute("DELETE FROM processing_history") }
            try writeLegacyProcessingRecord(
                sourceID: sourceID,
                fingerprint: fingerprint,
                output: output,
                transcript: transcript,
                writeTxtToStdout: true
            )
            XCTAssertEqual(try ProcessingStore.completionDecision(
                sourceKind: .file,
                sourceID: sourceID,
                fingerprint: fingerprint,
                settings: settings,
                outputPaths: [transcript.path]
            ), ProcessingDecision(action: .process, reason: .settingsChanged))
        }
    }

    func testSettingsSignatureEncodingOmitsLegacyStdoutField() throws {
        let data = try JSONEncoder().encode(sampleSettings())
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("write_txt_to_stdout"), text)
    }

    func testChangedSettingsDoNotSkip() throws {
        let state = try makeTempDir()
        let output = try makeTempDir()
        try withXDGStateHome(state.path) {
            let audio = output.appendingPathComponent("clip.m4a")
            try Data("audio".utf8).write(to: audio)
            let transcript = output.appendingPathComponent("clip.json")
            try Data("{}".utf8).write(to: transcript)
            let fingerprint = try ProcessingStore.fingerprint(files: [audio.path])
            let original = sampleSettings(model: "a")
            let changed = sampleSettings(model: "b")
            let sourceID = sourceIDForFiles(kind: .file, files: [audio.path])
            try ProcessingStore.append(ProcessingRecord(
                completed_at: iso8601String(Date()),
                history_reason: .firstRun,
                source_kind: .file,
                source_id: sourceID,
                source_fingerprint: fingerprint,
                settings_signature: original,
                output_dir: output.path,
                basename: "clip",
                output_paths: [transcript.path],
                audio_duration_s: 1,
                warning_count: 0,
                recording_title: nil,
                recorded_at: nil,
                voice_memos_unique_id: nil,
                voice_memos_path: nil
            ))

            XCTAssertFalse(try ProcessingStore.shouldSkipCompleted(
                sourceKind: .file,
                sourceID: sourceID,
                fingerprint: fingerprint,
                settings: changed,
                outputPaths: [transcript.path]
            ))
            XCTAssertEqual(try ProcessingStore.completionDecision(
                sourceKind: .file,
                sourceID: sourceID,
                fingerprint: fingerprint,
                settings: changed,
                outputPaths: [transcript.path]
            ), ProcessingDecision(action: .process, reason: .settingsChanged))
        }
    }

    func testSameSourceWithChangedFileReportsChangedFile() throws {
        let state = try makeTempDir()
        let output = try makeTempDir()
        try withXDGStateHome(state.path) {
            let audio = output.appendingPathComponent("clip.m4a")
            try Data("old audio".utf8).write(to: audio)
            let oldFingerprint = try ProcessingStore.fingerprint(files: [audio.path])
            let transcript = output.appendingPathComponent("clip.json")
            try Data("{}".utf8).write(to: transcript)
            let settings = sampleSettings()
            let sourceID = sourceIDForFiles(kind: .file, files: [audio.path])
            try ProcessingStore.append(ProcessingRecord(
                completed_at: iso8601String(Date()),
                history_reason: .firstRun,
                source_kind: .file,
                source_id: sourceID,
                source_fingerprint: oldFingerprint,
                settings_signature: settings,
                output_dir: output.path,
                basename: "clip",
                output_paths: [transcript.path],
                audio_duration_s: 1,
                warning_count: 0,
                recording_title: nil,
                recorded_at: nil,
                voice_memos_unique_id: nil,
                voice_memos_path: nil
            ))

            try Data("new audio".utf8).write(to: audio)
            let newFingerprint = try ProcessingStore.fingerprint(files: [audio.path])

            XCTAssertEqual(try ProcessingStore.completionDecision(
                sourceKind: .file,
                sourceID: sourceID,
                fingerprint: newFingerprint,
                settings: settings,
                outputPaths: [transcript.path]
            ), ProcessingDecision(action: .process, reason: .changedFile))
        }
    }

    func testContentMatchSkipsMovedFileWithIntactPriorOutputs() throws {
        let state = try makeTempDir()
        let originalDir = try makeTempDir()
        let elsewhere = try makeTempDir()
        try withXDGStateHome(state.path) {
            // Same bytes at two different paths => same SHA-256, different
            // FileFingerprint.path entries.
            let bytes = Data("payload-bytes".utf8)
            let oldPath = originalDir.appendingPathComponent("clip.m4a")
            let newPath = elsewhere.appendingPathComponent("clip.m4a")
            try bytes.write(to: oldPath)
            try bytes.write(to: newPath)

            let oldFingerprint = try ProcessingStore.fingerprint(files: [oldPath.path])
            let newFingerprint = try ProcessingStore.fingerprint(files: [newPath.path])
            XCTAssertNotEqual(oldFingerprint, newFingerprint, "fingerprint paths should differ across the two locations")

            let settings = sampleSettings()
            let oldTranscript = originalDir.appendingPathComponent("clip.json")
            try Data("{}".utf8).write(to: oldTranscript)

            try ProcessingStore.append(ProcessingRecord(
                completed_at: iso8601String(Date()),
                history_reason: .firstRun,
                source_kind: .file,
                source_id: "file:\(oldPath.path)",
                source_fingerprint: oldFingerprint,
                settings_signature: settings,
                output_dir: originalDir.path,
                basename: "clip",
                output_paths: [oldTranscript.path],
                audio_duration_s: 1,
                warning_count: 0,
                recording_title: nil,
                recorded_at: nil,
                voice_memos_unique_id: nil,
                voice_memos_path: nil
            ))

            XCTAssertTrue(try ProcessingStore.shouldSkipByContent(
                fingerprint: newFingerprint,
                settings: settings
            ))
            XCTAssertEqual(try ProcessingStore.contentDecision(
                fingerprint: newFingerprint,
                settings: settings
            ), ProcessingDecision(action: .skip, reason: .skipDuplicate))

            // Strict path still says no (paths differ); the content path is what
            // catches this case.
            XCTAssertFalse(try ProcessingStore.shouldSkipCompleted(
                sourceKind: .file,
                sourceID: "file:\(newPath.path)",
                fingerprint: newFingerprint,
                settings: settings,
                outputPaths: [newPath.deletingPathExtension().appendingPathExtension("json").path]
            ))

            // Delete the prior transcript: content match must back off and re-run.
            try FileManager.default.removeItem(at: oldTranscript)
            XCTAssertFalse(try ProcessingStore.shouldSkipByContent(
                fingerprint: newFingerprint,
                settings: settings
            ))
            XCTAssertEqual(try ProcessingStore.contentDecision(
                fingerprint: newFingerprint,
                settings: settings
            ), ProcessingDecision(action: .process, reason: .missingOutputs))
        }
    }

    func testContentMatchSkipsSingleFileExtractedFromPriorDirSession() throws {
        let state = try makeTempDir()
        let dir = try makeTempDir()
        try withXDGStateHome(state.path) {
            let a = dir.appendingPathComponent("a.m4a")
            let b = dir.appendingPathComponent("b.m4a")
            let c = dir.appendingPathComponent("c.m4a")
            try Data("aaa".utf8).write(to: a)
            try Data("bbb".utf8).write(to: b)
            try Data("ccc".utf8).write(to: c)

            let sessionFingerprint = try ProcessingStore.fingerprint(files: [a.path, b.path, c.path])
            let solo = try ProcessingStore.fingerprint(files: [b.path])

            let settings = sampleSettings()
            let priorOutput = dir.appendingPathComponent("session.json")
            try Data("{}".utf8).write(to: priorOutput)

            try ProcessingStore.append(ProcessingRecord(
                completed_at: iso8601String(Date()),
                history_reason: .firstRun,
                source_kind: .directorySession,
                source_id: sourceIDForFiles(kind: .directorySession, files: [a.path, b.path, c.path]),
                source_fingerprint: sessionFingerprint,
                settings_signature: settings,
                output_dir: dir.path,
                basename: "session",
                output_paths: [priorOutput.path],
                audio_duration_s: 1,
                warning_count: 0,
                recording_title: nil,
                recorded_at: nil,
                voice_memos_unique_id: nil,
                voice_memos_path: nil
            ))

            XCTAssertTrue(try ProcessingStore.shouldSkipByContent(
                fingerprint: solo,
                settings: settings
            ), "solo file whose SHA was in a prior dir session should skip")

            // A new run that adds a fresh file should NOT skip — subset semantics.
            let extra = dir.appendingPathComponent("d.m4a")
            try Data("ddd".utf8).write(to: extra)
            let supersetFingerprint = try ProcessingStore.fingerprint(files: [a.path, b.path, c.path, extra.path])
            XCTAssertFalse(try ProcessingStore.shouldSkipByContent(
                fingerprint: supersetFingerprint,
                settings: settings
            ), "a session containing genuinely new content must not skip")
        }
    }

    func testContentMatchAgainstBaselineIgnoresSettings() throws {
        let state = try makeTempDir()
        let dir = try makeTempDir()
        try withXDGStateHome(state.path) {
            let audio = dir.appendingPathComponent("memo.m4a")
            try Data("memo".utf8).write(to: audio)
            let fingerprint = try ProcessingStore.fingerprint(files: [audio.path])

            try ProcessingStore.append(ProcessingRecord(
                completed_at: iso8601String(Date()),
                history_reason: .imported,
                source_kind: .voiceMemosBaseline,
                source_id: "voice_memos:abc",
                source_fingerprint: fingerprint,
                settings_signature: nil,
                output_dir: nil,
                basename: nil,
                output_paths: [],
                audio_duration_s: nil,
                warning_count: 0,
                recording_title: "Memo",
                recorded_at: iso8601String(Date()),
                voice_memos_unique_id: "abc",
                voice_memos_path: audio.path
            ))

            XCTAssertTrue(try ProcessingStore.shouldSkipByContent(
                fingerprint: fingerprint,
                settings: sampleSettings(model: "any")
            ))
            XCTAssertEqual(try ProcessingStore.contentDecision(
                fingerprint: fingerprint,
                settings: sampleSettings(model: "any")
            ), ProcessingDecision(action: .skip, reason: .skipDuplicate, recordsSkipHistory: false))
            XCTAssertTrue(try ProcessingStore.shouldSkipByContent(
                fingerprint: fingerprint,
                settings: sampleSettings(model: "different-model")
            ))
        }
    }

    func testContentMatchRespectsSettingsForCompletedRecords() throws {
        let state = try makeTempDir()
        let dir = try makeTempDir()
        try withXDGStateHome(state.path) {
            let audio = dir.appendingPathComponent("clip.m4a")
            try Data("clip".utf8).write(to: audio)
            let fingerprint = try ProcessingStore.fingerprint(files: [audio.path])
            let priorOutput = dir.appendingPathComponent("clip.json")
            try Data("{}".utf8).write(to: priorOutput)

            try ProcessingStore.append(ProcessingRecord(
                completed_at: iso8601String(Date()),
                history_reason: .firstRun,
                source_kind: .file,
                source_id: "file:\(audio.path)",
                source_fingerprint: fingerprint,
                settings_signature: sampleSettings(model: "model-a"),
                output_dir: dir.path,
                basename: "clip",
                output_paths: [priorOutput.path],
                audio_duration_s: 1,
                warning_count: 0,
                recording_title: nil,
                recorded_at: nil,
                voice_memos_unique_id: nil,
                voice_memos_path: nil
            ))

            XCTAssertTrue(try ProcessingStore.shouldSkipByContent(
                fingerprint: fingerprint,
                settings: sampleSettings(model: "model-a")
            ))
            XCTAssertFalse(try ProcessingStore.shouldSkipByContent(
                fingerprint: fingerprint,
                settings: sampleSettings(model: "model-b")
            ), "different model should re-run; transcript content depends on settings")
            XCTAssertEqual(try ProcessingStore.contentDecision(
                fingerprint: fingerprint,
                settings: sampleSettings(model: "model-b")
            ), ProcessingDecision(action: .process, reason: .settingsChanged))
        }
    }

    func testContentMatchIgnoresTranscribeVersionForCompletedRecords() throws {
        let state = try makeTempDir()
        let dir = try makeTempDir()
        try withXDGStateHome(state.path) {
            let audio = dir.appendingPathComponent("clip.m4a")
            try Data("clip".utf8).write(to: audio)
            let fingerprint = try ProcessingStore.fingerprint(files: [audio.path])
            let priorOutput = dir.appendingPathComponent("clip.json")
            try Data("{}".utf8).write(to: priorOutput)

            try ProcessingStore.append(ProcessingRecord(
                completed_at: iso8601String(Date()),
                history_reason: .firstRun,
                source_kind: .voiceMemos,
                source_id: "voice_memos:abc",
                source_fingerprint: fingerprint,
                settings_signature: sampleSettings(version: "2.4.0"),
                output_dir: dir.path,
                basename: "clip",
                output_paths: [priorOutput.path],
                audio_duration_s: 1,
                warning_count: 0,
                recording_title: "clip",
                recorded_at: nil,
                voice_memos_unique_id: "abc",
                voice_memos_path: audio.path
            ))

            XCTAssertEqual(try ProcessingStore.contentDecision(
                fingerprint: fingerprint,
                settings: sampleSettings(version: "2.4.3")
            ), ProcessingDecision(action: .skip, reason: .skipDuplicate))
        }
    }

    func testImportedBaselineSkipsWithoutOutputs() throws {
        let state = try makeTempDir()
        let dir = try makeTempDir()
        try withXDGStateHome(state.path) {
            let audio = dir.appendingPathComponent("memo.m4a")
            try Data("audio".utf8).write(to: audio)
            let fingerprint = try ProcessingStore.fingerprint(files: [audio.path])
            try ProcessingStore.append(ProcessingRecord(
                completed_at: iso8601String(Date()),
                history_reason: .imported,
                source_kind: .importedBaseline,
                source_id: "file:\(audio.path)",
                source_fingerprint: fingerprint,
                settings_signature: nil,
                output_dir: nil,
                basename: nil,
                output_paths: [],
                audio_duration_s: 12,
                warning_count: 0,
                recording_title: "Memo",
                recorded_at: iso8601String(Date()),
                voice_memos_unique_id: "abc",
                voice_memos_path: audio.path
            ))

            XCTAssertTrue(try ProcessingStore.shouldSkipImportedBaseline(
                sourceID: "file:\(audio.path)",
                fingerprint: fingerprint
            ))
            XCTAssertEqual(try ProcessingStore.importedBaselineDecision(
                sourceID: "file:\(audio.path)",
                fingerprint: fingerprint
            ), ProcessingDecision(action: .skip, reason: .skipDuplicate, recordsSkipHistory: false))
        }
    }

    // MARK: - Database-backed ledger

    func testAppendStoresTodaysEncodedLineAndLiftedKeys() throws {
        try withXDGStateHome(try makeTempDir().path) {
            let record = sampleRecord(kind: .voiceMemos, sourceID: "voice_memos:abc", completedAt: "2026-06-01T10:00:00Z")
            try ProcessingStore.append(record)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let expected = String(decoding: try encoder.encode(record), as: UTF8.self)
            let rows = try StateStore.withDatabase { database in
                try database.query("SELECT completed_at, source_kind, source_id, record FROM processing_history") {
                    [$0.text(0), $0.text(1), $0.text(2), $0.text(3)]
                }
            }
            XCTAssertEqual(rows, [["2026-06-01T10:00:00Z", "voice_memos", "voice_memos:abc", expected]])
            XCTAssertFalse(expected.contains("\n"))
        }
    }

    func testUnknownFieldsSurviveVerbatim() throws {
        try withXDGStateHome(try makeTempDir().path) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let known = String(decoding: try encoder.encode(sampleRecord(kind: .file, sourceID: "file:/a.m4a")), as: UTF8.self)
            // A field this binary does not know, in a position a re-encode
            // would not reproduce, plus spacing a re-encode would drop.
            let line = "{\"unknown_field\": {\"nested\": [1, 2.50]}, " + known.dropFirst()
            try ProcessingStore.appendVerbatim(line: line)

            XCTAssertEqual(try ProcessingStore.recordLines(), [line])
            let loaded = try ProcessingStore.loadRecords()
            XCTAssertEqual(loaded.map(\.source_id), ["file:/a.m4a"])
            let lifted = try StateStore.withDatabase { database in
                try database.query("SELECT source_kind, source_id FROM processing_history") { [$0.text(0), $0.text(1)] }
            }
            XCTAssertEqual(lifted, [["file", "file:/a.m4a"]])
        }
    }

    func testUndecodableRowsAreSkippedNotErrors() throws {
        try withXDGStateHome(try makeTempDir().path) {
            let state = try makeTempDir()
            let audio = state.appendingPathComponent("clip.m4a")
            try Data("audio".utf8).write(to: audio)
            let transcript = state.appendingPathComponent("clip.json")
            try Data("{}".utf8).write(to: transcript)
            let fingerprint = try ProcessingStore.fingerprint(files: [audio.path])
            let sourceID = sourceIDForFiles(kind: .file, files: [audio.path])
            try ProcessingStore.append(sampleRecord(
                kind: .file, sourceID: sourceID, fingerprint: fingerprint,
                settings: sampleSettings(), outputPaths: [transcript.path]
            ))
            // Newer rows for the same source that cannot decode: a truncated
            // line (torn final JSONL write) with lifted keys, a record missing
            // a required field, and plain garbage with placeholder keys.
            try ProcessingStore.appendVerbatim(line: "{\"source_kind\":\"file\",\"source_id\":\"\(sourceID)\",\"source_fing")
            try ProcessingStore.appendVerbatim(line: "{\"source_kind\":\"file\",\"source_id\":\"\(sourceID)\",\"warning_count\":0}")
            try ProcessingStore.appendVerbatim(line: "not json")

            XCTAssertEqual(try ProcessingStore.recordLines().count, 4)
            XCTAssertEqual(try ProcessingStore.loadRecords().count, 1)
            // The newest decodable record for the source still decides.
            XCTAssertEqual(try ProcessingStore.completionDecision(
                sourceKind: .file,
                sourceID: sourceID,
                fingerprint: fingerprint,
                settings: sampleSettings(),
                outputPaths: [transcript.path]
            ), ProcessingDecision(action: .skip, reason: .skipDuplicate))
            XCTAssertEqual(try ProcessingStore.contentDecision(
                fingerprint: fingerprint,
                settings: sampleSettings()
            ), ProcessingDecision(action: .skip, reason: .skipDuplicate))
        }
    }

    func testCompletionDecisionUsesNewestRecordForSourceOnly() throws {
        try withXDGStateHome(try makeTempDir().path) {
            let dir = try makeTempDir()
            let audio = dir.appendingPathComponent("clip.m4a")
            try Data("audio".utf8).write(to: audio)
            let transcript = dir.appendingPathComponent("clip.json")
            try Data("{}".utf8).write(to: transcript)
            let fingerprint = try ProcessingStore.fingerprint(files: [audio.path])
            let stale = SourceFingerprint(files: [FileFingerprint(path: audio.path, sha256: "00", bytes: 1, mtime: nil)])
            let sourceID = sourceIDForFiles(kind: .file, files: [audio.path])

            try ProcessingStore.append(sampleRecord(
                kind: .file, sourceID: sourceID, fingerprint: fingerprint,
                settings: sampleSettings(), outputPaths: [transcript.path]
            ))
            // Same source ID under another kind, and another source: neither
            // may influence the decision for (.file, sourceID).
            try ProcessingStore.append(sampleRecord(kind: .directorySession, sourceID: sourceID, fingerprint: stale))
            try ProcessingStore.append(sampleRecord(kind: .file, sourceID: "file:/elsewhere.m4a", fingerprint: stale))
            XCTAssertEqual(try ProcessingStore.completionDecision(
                sourceKind: .file, sourceID: sourceID, fingerprint: fingerprint,
                settings: sampleSettings(), outputPaths: [transcript.path]
            ), ProcessingDecision(action: .skip, reason: .skipDuplicate))

            try ProcessingStore.append(sampleRecord(kind: .file, sourceID: sourceID, fingerprint: stale))
            XCTAssertEqual(try ProcessingStore.completionDecision(
                sourceKind: .file, sourceID: sourceID, fingerprint: fingerprint,
                settings: sampleSettings(), outputPaths: [transcript.path]
            ), ProcessingDecision(action: .process, reason: .changedFile))
            XCTAssertEqual(try ProcessingStore.completionDecision(
                sourceKind: .file, sourceID: "file:/never-seen.m4a", fingerprint: fingerprint,
                settings: sampleSettings(), outputPaths: [transcript.path]
            ), ProcessingDecision(action: .process, reason: .firstRun))
        }
    }

    func testSourceIDsMatchAcrossUnicodeNormalizationForms() throws {
        try withXDGStateHome(try makeTempDir().path) {
            // Filename-derived IDs can arrive NFD (HFS/APFS) or NFC. Swift ==
            // treats them as equal; the lifted SQL column must too.
            let nfc = "voice_memos:caf\u{E9}.m4a"
            let nfd = "voice_memos:cafe\u{301}.m4a"
            let fingerprint = SourceFingerprint(files: [FileFingerprint(path: "/a.m4a", sha256: "aa", bytes: 1, mtime: nil)])
            try ProcessingStore.append(sampleRecord(kind: .importedBaseline, sourceID: nfd, fingerprint: fingerprint))
            XCTAssertEqual(
                try ProcessingStore.importedBaselineDecision(sourceID: nfc, fingerprint: fingerprint),
                ProcessingDecision(action: .skip, reason: .skipDuplicate, recordsSkipHistory: false),
                "an NFC query must find the NFD-recorded baseline"
            )
        }
    }

    func testImportedBaselineMatchesBothBaselineKindsNewestFirst() throws {
        try withXDGStateHome(try makeTempDir().path) {
            let fingerprint = SourceFingerprint(files: [FileFingerprint(path: "/a.m4a", sha256: "aa", bytes: 1, mtime: nil)])
            let changed = SourceFingerprint(files: [FileFingerprint(path: "/a.m4a", sha256: "bb", bytes: 1, mtime: nil)])

            // A completed (non-baseline) record never counts as a baseline.
            try ProcessingStore.append(sampleRecord(kind: .voiceMemos, sourceID: "voice_memos:a", fingerprint: fingerprint))
            XCTAssertEqual(
                try ProcessingStore.importedBaselineDecision(sourceID: "voice_memos:a", fingerprint: fingerprint),
                ProcessingDecision(action: .process, reason: .firstRun)
            )

            try ProcessingStore.append(sampleRecord(kind: .importedBaseline, sourceID: "voice_memos:a", fingerprint: changed))
            XCTAssertEqual(
                try ProcessingStore.importedBaselineDecision(sourceID: "voice_memos:a", fingerprint: fingerprint),
                ProcessingDecision(action: .process, reason: .changedFile)
            )

            try ProcessingStore.append(sampleRecord(kind: .voiceMemosBaseline, sourceID: "voice_memos:a", fingerprint: fingerprint))
            XCTAssertEqual(
                try ProcessingStore.importedBaselineDecision(sourceID: "voice_memos:a", fingerprint: fingerprint),
                ProcessingDecision(action: .skip, reason: .skipDuplicate, recordsSkipHistory: false)
            )
        }
    }

    /// The database-backed store must return exactly what the 2.x JSONL store
    /// returned for the same appends: today's encoder, one line per record,
    /// decoded line by line.
    func testAppendThenLoadMatchesFileBackedBehavior() throws {
        try withXDGStateHome(try makeTempDir().path) {
            let fingerprint = SourceFingerprint(files: [
                FileFingerprint(path: "/rec/a.m4a", sha256: "aa", bytes: 10, mtime: "2026-01-01T00:00:00Z"),
                FileFingerprint(path: "/rec/b.m4a", sha256: "bb", bytes: 20, mtime: nil),
            ])
            let legacyStdout = ProcessingSettingsSignature(
                model: "m", language: nil, diarization_enabled: true, speaker_strategy: "segment",
                min_speakers: 2, max_speakers: 4, formats: ["txt", "srt"], transcribe_version: "2.4.0",
                legacy_write_txt_to_stdout: true
            )
            let records = [
                sampleRecord(kind: .file, sourceID: "file:/rec/a.m4a", completedAt: "2026-01-01T00:00:00Z"),
                sampleRecord(
                    kind: .directorySession, sourceID: "directory_session:/rec/a.m4a\u{1f}/rec/b.m4a",
                    fingerprint: fingerprint, settings: legacyStdout, outputPaths: ["/out/s.txt", "/out/s.srt"],
                    reason: .settingsChanged, completedAt: "2026-01-02T00:00:00Z"
                ),
                ProcessingRecord(
                    completed_at: "2026-01-03T00:00:00Z", history_reason: nil, source_kind: .voiceMemosBaseline,
                    source_id: "voice_memos:x", source_fingerprint: SourceFingerprint(files: []),
                    settings_signature: nil, output_dir: nil, basename: nil, output_paths: [],
                    audio_duration_s: nil, warning_count: 0, recording_title: "Memo \"quoted\" ünïcode",
                    recorded_at: "2014-05-13T00:30:35Z", voice_memos_unique_id: "x", voice_memos_path: "/vm/x.m4a"
                ),
                sampleRecord(kind: .importedBaseline, sourceID: "file:/rec/c.m4a", reason: .imported),
            ]
            for record in records {
                try ProcessingStore.append(record)
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            var file = ""
            for record in records {
                file += String(decoding: try encoder.encode(record), as: UTF8.self) + "\n"
            }
            let fileBacked = file.split(separator: "\n", omittingEmptySubsequences: true).compactMap {
                try? JSONDecoder().decode(ProcessingRecord.self, from: Data($0.utf8))
            }

            XCTAssertEqual(try ProcessingStore.loadRecords(), fileBacked)
            XCTAssertEqual(try ProcessingStore.recordLines().joined(separator: "\n") + "\n", file)
            // The legacy stdout flag is decode-only, exactly as with the file.
            XCTAssertEqual(try ProcessingStore.loadRecords()[1].settings_signature?.legacy_write_txt_to_stdout, false)
        }
    }

    private func sampleRecord(
        kind: ProcessingSourceKind,
        sourceID: String,
        fingerprint: SourceFingerprint = SourceFingerprint(files: [FileFingerprint(path: "/a.m4a", sha256: "aa", bytes: 1, mtime: nil)]),
        settings: ProcessingSettingsSignature? = nil,
        outputPaths: [String] = [],
        reason: ProcessingHistoryReason = .firstRun,
        completedAt: String = "2026-06-01T00:00:00Z"
    ) -> ProcessingRecord {
        ProcessingRecord(
            completed_at: completedAt,
            history_reason: reason,
            source_kind: kind,
            source_id: sourceID,
            source_fingerprint: fingerprint,
            settings_signature: settings,
            output_dir: outputPaths.isEmpty ? nil : "/out",
            basename: "clip",
            output_paths: outputPaths,
            audio_duration_s: 1.5,
            warning_count: 0,
            recording_title: nil,
            recorded_at: nil,
            voice_memos_unique_id: nil,
            voice_memos_path: nil
        )
    }

    private func sampleSettings(model: String = "model", version: String = "1.0.0") -> ProcessingSettingsSignature {
        ProcessingSettingsSignature(
            model: model,
            language: "en",
            diarization_enabled: false,
            speaker_strategy: "subsegment",
            min_speakers: nil,
            max_speakers: nil,
            formats: ["json"],
            transcribe_version: version
        )
    }

    private func writeLegacyProcessingRecord(
        sourceID: String,
        fingerprint: SourceFingerprint,
        output: URL,
        transcript: URL,
        writeTxtToStdout: Bool
    ) throws {
        let files = fingerprint.files.map { file -> [String: Any] in
            var row: [String: Any] = [
                "path": file.path,
                "sha256": file.sha256,
                "bytes": file.bytes,
            ]
            if let mtime = file.mtime {
                row["mtime"] = mtime
            }
            return row
        }
        let row: [String: Any] = [
            "schema_version": 1,
            "completed_at": "2026-05-29T00:00:00Z",
            "history_reason": "first_run",
            "source_kind": "file",
            "source_id": sourceID,
            "source_fingerprint": ["files": files],
            "settings_signature": [
                "model": "model",
                "language": "en",
                "diarization_enabled": false,
                "speaker_strategy": "subsegment",
                "formats": ["txt"],
                "write_txt_to_stdout": writeTxtToStdout,
                "transcribe_version": "2.4.0",
            ],
            "output_dir": output.path,
            "basename": "clip",
            "output_paths": [transcript.path],
            "audio_duration_s": 1.0,
            "warning_count": 0,
        ]
        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        try ProcessingStore.appendVerbatim(line: String(decoding: data, as: UTF8.self))
    }

    private func withXDGStateHome(_ path: String, _ body: () throws -> Void) throws {
        let previous = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        setenv("XDG_STATE_HOME", path, 1)
        defer {
            if let previous {
                setenv("XDG_STATE_HOME", previous, 1)
            } else {
                unsetenv("XDG_STATE_HOME")
            }
        }
        try body()
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
