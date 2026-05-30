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

            try FileManager.default.removeItem(at: try StatePaths.processingHistoryURL())
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
        let url = try StatePaths.processingHistoryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
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
        var line = data
        line.append(Data("\n".utf8))
        try line.write(to: url)
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
