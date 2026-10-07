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

    private func record(
        model: String = "model-a",
        diarizationEnabled: Bool,
        audioDurationS: Double = 10,
        phases: PhaseTimings,
        totalMs: Int64
    ) -> RunTimingRecord {
        RunTimingRecord(
            endedAt: Date(),
            transcribeVersion: "2.7.0",
            model: model,
            diarizationEnabled: diarizationEnabled,
            inputBasename: "a.wav",
            fileBytes: 100,
            audioDurationS: audioDurationS,
            segmentCount: 1,
            speakersDetected: diarizationEnabled ? 2 : nil,
            phases: phases,
            writeOutputsMs: 1,
            totalMs: totalMs
        )
    }

    func testMedianProcessingSecondsPerAudioSecondPrefersParallelAndSkipsZero() throws {
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

        // Diarized run: parallel block wins even though the summed decoder time is huge.
        var diarized = PhaseTimings()
        diarized.parallelMs = 3000
        diarized.whisperDecodingLoopMs = 36_000
        diarized.whisperEncodingMs = 9_000
        let r1 = record(diarizationEnabled: true, phases: diarized, totalMs: 3200)

        // Record with neither block recorded is ignored.
        let r2 = record(diarizationEnabled: false, phases: PhaseTimings(), totalMs: 5000)

        let median = TimingStore.medianProcessingSecondsPerAudioSecond(records: [migratedV1, r1, r2])
        // Ratios: v1 transcribe_only 0.1, diarized parallel 0.3 -> median 0.2.
        XCTAssertEqual(try XCTUnwrap(median), 0.2, accuracy: 0.0001)
        XCTAssertNil(TimingStore.medianProcessingSecondsPerAudioSecond(records: [r2]))
    }

    func testMedianFirstProgressAndModelLoadAreAbsoluteSeconds() throws {
        var fast = PhaseTimings()
        fast.whisperFirstProgressMs = 1500
        fast.whisperInitMs = 4000
        fast.speakerInitMs = 60
        let r1 = record(diarizationEnabled: true, audioDurationS: 600, phases: fast, totalMs: 90_000)

        var slow = PhaseTimings()
        slow.whisperFirstProgressMs = 2500
        slow.whisperInitMs = 6000
        slow.speakerInitMs = 140
        let r2 = record(diarizationEnabled: true, audioDurationS: 60, phases: slow, totalMs: 12_000)

        // Reused models within a batch record zero init and no first-progress sample.
        let reused = record(diarizationEnabled: true, audioDurationS: 60, phases: PhaseTimings(), totalMs: 9_000)

        let firstProgress = try XCTUnwrap(TimingStore.medianFirstProgressSeconds(records: [r1, r2, reused]))
        XCTAssertEqual(firstProgress, 2.0, accuracy: 0.0001)
        let modelLoad = try XCTUnwrap(TimingStore.medianModelLoadSeconds(records: [r1, r2, reused]))
        XCTAssertEqual(modelLoad, 5.1, accuracy: 0.0001)
        XCTAssertNil(TimingStore.medianFirstProgressSeconds(records: [reused]))
        XCTAssertNil(TimingStore.medianModelLoadSeconds(records: [reused]))
    }

    func testHistoricalRatiosUsesWallClockPredictors() throws {
        var transcriptOnlyPhases = PhaseTimings()
        transcriptOnlyPhases.transcribeOnlyMs = 2000
        transcriptOnlyPhases.whisperEncodingMs = 20_000
        transcriptOnlyPhases.whisperFirstProgressMs = 1000
        transcriptOnlyPhases.whisperInitMs = 3000
        let transcriptOnly = record(diarizationEnabled: false, phases: transcriptOnlyPhases, totalMs: 2000)

        var diarizedPhases = PhaseTimings()
        diarizedPhases.parallelMs = 4000
        diarizedPhases.whisperDecodingLoopMs = 48_000
        diarizedPhases.speakerDiarizationMs = 8000
        diarizedPhases.whisperFirstProgressMs = 2000
        diarizedPhases.whisperInitMs = 5000
        let diarized = record(diarizationEnabled: true, phases: diarizedPhases, totalMs: 9000)

        let ratios = TimingStore.historicalRatios(
            totalRecords: [diarized],
            phaseRecords: [transcriptOnly, diarized]
        )
        XCTAssertEqual(try XCTUnwrap(ratios.totalSecondsPerAudioSecond), 0.9, accuracy: 0.0001)
        // Processing ratio comes from the diarization-matched records only.
        XCTAssertEqual(try XCTUnwrap(ratios.processingSecondsPerAudioSecond), 0.4, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(ratios.diarizationSecondsPerAudioSecond), 0.8, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(ratios.firstProgressSeconds), 1.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(ratios.modelLoadSeconds), 4.0, accuracy: 0.0001)

        // Without diarization-matched records the processing ratio falls back to model-only records.
        let fallback = TimingStore.historicalRatios(totalRecords: [], phaseRecords: [transcriptOnly, diarized])
        XCTAssertEqual(try XCTUnwrap(fallback.processingSecondsPerAudioSecond), 0.3, accuracy: 0.0001)
        XCTAssertNil(fallback.totalSecondsPerAudioSecond)
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

    // MARK: - Database-backed ledger

    private func timingRecord(_ name: String, model: String = "alpha", diarization: Bool = false) -> RunTimingRecord {
        RunTimingRecord(
            endedAt: Date(timeIntervalSince1970: 1_780_000_000),
            transcribeVersion: "2.7.0",
            model: model,
            diarizationEnabled: diarization,
            inputBasename: name,
            fileBytes: 100,
            audioDurationS: 60,
            segmentCount: 1,
            speakersDetected: diarization ? 2 : nil,
            phases: PhaseTimings(),
            writeOutputsMs: 1,
            totalMs: 6000
        )
    }

    private func withTemporaryState(_ body: () throws -> Void) throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-timing-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let prev = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        setenv("XDG_STATE_HOME", temp.path, 1)
        defer {
            if let prev { setenv("XDG_STATE_HOME", prev, 1) } else { unsetenv("XDG_STATE_HOME") }
            try? FileManager.default.removeItem(at: temp)
        }
        try body()
    }

    func testAppendStoresTodaysEncodedLineAndLiftedKeys() throws {
        try withTemporaryState {
            let record = timingRecord("a.wav", model: "beta", diarization: true)
            try TimingStore.append(record)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let expected = String(decoding: try encoder.encode(record), as: UTF8.self)
            let rows = try StateStore.withDatabase { database in
                try database.query("SELECT recorded_at, model, diarization, record FROM timing_history") {
                    [$0.text(0) ?? "", $0.text(1) ?? "", String($0.int(2) ?? -1), $0.text(3) ?? ""]
                }
            }
            XCTAssertEqual(rows, [[record.ended_at, "beta", "1", expected]])
        }
    }

    func testUnknownFieldsSurviveVerbatim() throws {
        try withTemporaryState {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let known = String(decoding: try encoder.encode(timingRecord("a.wav")), as: UTF8.self)
            let line = "{\"unknown_field\": \"kept\", " + known.dropFirst()
            try TimingStore.appendVerbatim(line: line)

            let stored = try StateStore.withDatabase { database in
                try database.query("SELECT record FROM timing_history") { $0.text(0) }
            }
            XCTAssertEqual(stored, [line])
            XCTAssertEqual(try TimingStore.loadRecent(model: "alpha", diarizationEnabled: false).map(\.input_basename), ["a.wav"])
        }
    }

    func testModelNamesMatchAcrossUnicodeNormalizationForms() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-nfc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let prev = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        setenv("XDG_STATE_HOME", temp.path, 1)
        defer {
            if let prev {
                setenv("XDG_STATE_HOME", prev, 1)
            } else {
                unsetenv("XDG_STATE_HOME")
            }
            try? FileManager.default.removeItem(at: temp)
        }

        // Swift == matches by canonical equivalence; the lifted SQL column
        // must not quietly diverge for NFD-spelled model names.
        let nfd = "mod\u{65}\u{300}le"
        let nfc = "mod\u{E8}le"
        try TimingStore.append(record(model: nfd, diarizationEnabled: false, phases: PhaseTimings(), totalMs: 10))
        XCTAssertEqual(
            try TimingStore.loadRecent(model: nfc, diarizationEnabled: false).count, 1,
            "an NFC query must find the NFD-recorded model"
        )
    }

    /// Same contract as the JSONL reader: the newest `limit` decodable,
    /// matching records, returned oldest first; undecodable rows neither
    /// error nor take a slot.
    func testLoadRecentKeepsNewestDecodableRecordsInLedgerOrder() throws {
        try withTemporaryState {
            for index in 0 ..< 5 {
                try TimingStore.append(timingRecord("r\(index).wav"))
                try TimingStore.append(timingRecord("d\(index).wav", diarization: true))
                try TimingStore.append(timingRecord("o\(index).wav", model: "other"))
            }
            // Torn or foreign rows carrying the queried keys.
            try TimingStore.appendVerbatim(line: "{\"model\":\"alpha\",\"diarization_enabled\":false,\"ended_")
            try TimingStore.appendVerbatim(line: "{\"model\":\"alpha\",\"diarization_enabled\":false}")
            try TimingStore.appendVerbatim(line: "garbage")

            XCTAssertEqual(
                try TimingStore.loadRecent(model: "alpha", diarizationEnabled: false, limit: 3).map(\.input_basename),
                ["r2.wav", "r3.wav", "r4.wav"]
            )
            XCTAssertEqual(
                try TimingStore.loadRecent(model: "alpha", diarizationEnabled: true, limit: 50).map(\.input_basename),
                ["d0.wav", "d1.wav", "d2.wav", "d3.wav", "d4.wav"]
            )
            XCTAssertEqual(
                try TimingStore.loadRecent(model: "alpha", limit: 4).map(\.input_basename),
                ["r3.wav", "d3.wav", "r4.wav", "d4.wav"]
            )
            XCTAssertEqual(try TimingStore.loadRecent(model: "alpha", diarizationEnabled: false, limit: 0), [])
            XCTAssertEqual(try TimingStore.loadRecent(model: "missing"), [])
        }
    }

    func testHistoricalRatiosFromStoredHistory() throws {
        try withTemporaryState {
            try TimingStore.append(timingRecord("a.wav"))
            try TimingStore.append(timingRecord("b.wav"))
            let ratios = TimingStore.historicalRatios(
                totalRecords: try TimingStore.loadRecent(model: "alpha", diarizationEnabled: false),
                phaseRecords: try TimingStore.loadRecent(model: "alpha")
            )
            XCTAssertEqual(try XCTUnwrap(ratios.totalSecondsPerAudioSecond), 0.1, accuracy: 1e-9)
        }
    }
}
