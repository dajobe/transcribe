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

            try FileManager.default.removeItem(at: transcript)
            XCTAssertFalse(try ProcessingStore.shouldSkipCompleted(
                sourceKind: .file,
                sourceID: sourceID,
                fingerprint: fingerprint,
                settings: settings,
                outputPaths: [transcript.path]
            ))
        }
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
        }
    }

    private func sampleSettings(model: String = "model") -> ProcessingSettingsSignature {
        ProcessingSettingsSignature(
            model: model,
            language: "en",
            diarization_enabled: false,
            speaker_strategy: "subsegment",
            min_speakers: nil,
            max_speakers: nil,
            formats: ["json"],
            write_txt_to_stdout: false,
            transcribe_version: "1.0.0"
        )
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
