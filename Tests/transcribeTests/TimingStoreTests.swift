import Foundation
import XCTest
@testable import transcribe

final class TimingStoreTests: XCTestCase {
    func testMedianWallSecondsPerAudioSecond() {
        let p = PhaseTimings()
        let r1 = RunTimingRecord(
            endedAt: Date(),
            transcribeVersion: "1.1.0",
            model: "model-a",
            diarizationEnabled: true,
            inputBasename: "a.wav",
            fileBytes: 1000,
            audioDurationS: 10,
            segmentCount: 5,
            speakersDetected: 2,
            phases: p,
            writeOutputsMs: 10,
            totalMs: 10_000
        )
        let r2 = RunTimingRecord(
            endedAt: Date(),
            transcribeVersion: "1.1.0",
            model: "model-a",
            diarizationEnabled: true,
            inputBasename: "b.wav",
            fileBytes: 2000,
            audioDurationS: 10,
            segmentCount: 3,
            speakersDetected: 1,
            phases: p,
            writeOutputsMs: 10,
            totalMs: 20_000
        )
        let m = TimingStore.medianWallSecondsPerAudioSecond(records: [r1, r2])
        XCTAssertNotNil(m)
        XCTAssertEqual(m!, 1.5, accuracy: 0.0001)
    }

    func testMedianEmptyReturnsNil() {
        XCTAssertNil(TimingStore.medianWallSecondsPerAudioSecond(records: []))
    }

    func testV1DecodeDefaultsPhaseFieldsToZero() throws {
        let json = """
        {
          "schema_version": 1,
          "ended_at": "2026-05-28T12:00:00.000Z",
          "transcribe_version": "1.8.0",
          "model": "model-a",
          "diarization_enabled": false,
          "input_basename": "a.wav",
          "file_bytes": 1000,
          "audio_duration_s": 10,
          "segment_count": 5,
          "speakers_detected": null,
          "audio_load_ms": 100,
          "whisper_init_ms": 200,
          "speaker_init_ms": 0,
          "parallel_ms": 0,
          "transcribe_only_ms": 3000,
          "merge_ms": 0,
          "write_outputs_ms": 10,
          "total_ms": 3310,
          "decoding_windows": 2
        }
        """
        let record = try JSONDecoder().decode(RunTimingRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.schema_version, 1)
        XCTAssertEqual(record.whisper_audio_processing_ms, 0)
        XCTAssertEqual(record.whisper_logmels_ms, 0)
        XCTAssertEqual(record.whisper_encoding_ms, 0)
        XCTAssertEqual(record.whisper_decoding_loop_ms, 0)
        XCTAssertEqual(record.whisper_total_encoding_runs, 0)
        XCTAssertEqual(record.speaker_diarization_ms, 0)
        XCTAssertEqual(record.speaker_total_chunks, 0)
    }

    func testMedianEncodingSecondsPerAudioSecondIgnoresZeroAndMissingValues() throws {
        let v1JSON = """
        {
          "schema_version": 1,
          "ended_at": "2026-05-28T12:00:00.000Z",
          "transcribe_version": "1.8.0",
          "model": "model-a",
          "diarization_enabled": false,
          "input_basename": "old.wav",
          "file_bytes": 1000,
          "audio_duration_s": 10,
          "segment_count": 1,
          "speakers_detected": null,
          "audio_load_ms": 100,
          "whisper_init_ms": 100,
          "speaker_init_ms": 0,
          "parallel_ms": 0,
          "transcribe_only_ms": 1000,
          "merge_ms": 0,
          "write_outputs_ms": 10,
          "total_ms": 1210,
          "decoding_windows": 1
        }
        """
        let migratedV1 = try JSONDecoder().decode(RunTimingRecord.self, from: Data(v1JSON.utf8))

        var p1 = PhaseTimings()
        p1.whisperEncodingMs = 1000
        let r1 = RunTimingRecord(
            endedAt: Date(),
            transcribeVersion: "1.8.0",
            model: "model-a",
            diarizationEnabled: false,
            inputBasename: "a.wav",
            fileBytes: 100,
            audioDurationS: 10,
            segmentCount: 1,
            speakersDetected: nil,
            phases: p1,
            writeOutputsMs: 1,
            totalMs: 1000
        )

        var p2 = PhaseTimings()
        p2.whisperEncodingMs = 3000
        let r2 = RunTimingRecord(
            endedAt: Date(),
            transcribeVersion: "1.8.0",
            model: "model-a",
            diarizationEnabled: false,
            inputBasename: "b.wav",
            fileBytes: 100,
            audioDurationS: 10,
            segmentCount: 1,
            speakersDetected: nil,
            phases: p2,
            writeOutputsMs: 1,
            totalMs: 3000
        )

        let median = TimingStore.medianEncodingSecondsPerAudioSecond(records: [migratedV1, r1, r2])
        XCTAssertEqual(try XCTUnwrap(median), 0.2, accuracy: 0.0001)
    }

    func testHistoricalRatiosUsesPhaseRecordsAcrossDiarizationModes() throws {
        var transcriptOnlyPhases = PhaseTimings()
        transcriptOnlyPhases.whisperEncodingMs = 2000
        let transcriptOnly = RunTimingRecord(
            endedAt: Date(),
            transcribeVersion: "1.8.0",
            model: "model-a",
            diarizationEnabled: false,
            inputBasename: "a.wav",
            fileBytes: 100,
            audioDurationS: 10,
            segmentCount: 1,
            speakersDetected: nil,
            phases: transcriptOnlyPhases,
            writeOutputsMs: 1,
            totalMs: 2000
        )

        var diarizedPhases = PhaseTimings()
        diarizedPhases.whisperEncodingMs = 4000
        diarizedPhases.speakerDiarizationMs = 8000
        let diarized = RunTimingRecord(
            endedAt: Date(),
            transcribeVersion: "1.8.0",
            model: "model-a",
            diarizationEnabled: true,
            inputBasename: "b.wav",
            fileBytes: 100,
            audioDurationS: 10,
            segmentCount: 1,
            speakersDetected: 2,
            phases: diarizedPhases,
            writeOutputsMs: 1,
            totalMs: 9000
        )

        let ratios = TimingStore.historicalRatios(
            totalRecords: [diarized],
            phaseRecords: [transcriptOnly, diarized]
        )
        XCTAssertEqual(try XCTUnwrap(ratios.totalSecondsPerAudioSecond), 0.9, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(ratios.encodingSecondsPerAudioSecond), 0.3, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(ratios.diarizationSecondsPerAudioSecond), 0.8, accuracy: 0.0001)
    }

    func testStateDirectoryUnderXDGStateHome() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let prev = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        setenv("XDG_STATE_HOME", temp.path, 1)
        defer {
            if let prev {
                setenv("XDG_STATE_HOME", prev, 1)
            } else {
                unsetenv("XDG_STATE_HOME")
            }
        }
        let dir = try StatePaths.stateDirectoryURL()
        XCTAssertTrue(dir.path.hasSuffix("/transcribe"), "got \(dir.path)")
        XCTAssertEqual(dir.deletingLastPathComponent().path, temp.path)
    }

    func testAppendAndLoadRecentFiltersByModel() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-jsonl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let prev = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        setenv("XDG_STATE_HOME", temp.path, 1)
        defer {
            if let prev {
                setenv("XDG_STATE_HOME", prev, 1)
            } else {
                unsetenv("XDG_STATE_HOME")
            }
        }

        let p = PhaseTimings()
        let recA = RunTimingRecord(
            endedAt: Date(),
            transcribeVersion: "1.1.0",
            model: "alpha",
            diarizationEnabled: false,
            inputBasename: "x.wav",
            fileBytes: 100,
            audioDurationS: 60,
            segmentCount: 1,
            speakersDetected: nil,
            phases: p,
            writeOutputsMs: 1,
            totalMs: 6000
        )
        let recB = RunTimingRecord(
            endedAt: Date(),
            transcribeVersion: "1.1.0",
            model: "beta",
            diarizationEnabled: false,
            inputBasename: "y.wav",
            fileBytes: 100,
            audioDurationS: 60,
            segmentCount: 1,
            speakersDetected: nil,
            phases: p,
            writeOutputsMs: 1,
            totalMs: 6000
        )
        try TimingStore.append(recA)
        try TimingStore.append(recB)

        let loaded = try TimingStore.loadRecent(model: "alpha", diarizationEnabled: false, limit: 10)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].model, "alpha")
    }

    func testConcurrentAppendsPreserveAllRecords() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-jsonl-concurrent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let prev = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        setenv("XDG_STATE_HOME", temp.path, 1)
        defer {
            if let prev {
                setenv("XDG_STATE_HOME", prev, 1)
            } else {
                unsetenv("XDG_STATE_HOME")
            }
        }

        let queue = DispatchQueue(label: "transcribe-tests.timing-store", attributes: .concurrent)
        let group = DispatchGroup()
        let phases = PhaseTimings()
        let totalRecords = 40
        let lock = NSLock()
        var appendErrors: [Error] = []

        for index in 0 ..< totalRecords {
            group.enter()
            queue.async {
                defer { group.leave() }
                let record = RunTimingRecord(
                    endedAt: Date(),
                    transcribeVersion: "1.1.0",
                    model: "alpha",
                    diarizationEnabled: false,
                    inputBasename: "file-\(index).wav",
                    fileBytes: 100,
                    audioDurationS: 60,
                    segmentCount: 1,
                    speakersDetected: nil,
                    phases: phases,
                    writeOutputsMs: 1,
                    totalMs: 6000
                )
                do {
                    try TimingStore.append(record)
                } catch {
                    lock.lock()
                    appendErrors.append(error)
                    lock.unlock()
                }
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(appendErrors.isEmpty, "concurrent append errors: \(appendErrors)")

        let loaded = try TimingStore.loadRecent(model: "alpha", diarizationEnabled: false, limit: 100)
        XCTAssertEqual(loaded.count, totalRecords)
    }
}
