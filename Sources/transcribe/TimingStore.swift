import Foundation

/// Wall-clock predictors derived from prior runs, used by the live ETA.
///
/// Every `*SecondsPerAudioSecond` value is wall seconds per second of audio.
/// WhisperKit's own `encoding` / `decodingLoop` timings are deliberately not
/// used here: with VAD chunking WhisperKit decodes many chunks concurrently and
/// those timings are summed across workers, so they overstate wall time by an
/// order of magnitude.
struct HistoricalTimingRatios: Sendable, Equatable {
    /// Whole run (`total_ms`), used only as a last-resort fallback.
    var totalSecondsPerAudioSecond: Double?
    var audioLoadSecondsPerAudioSecond: Double?
    /// Wall time of the transcribe (+ concurrent diarize) block:
    /// `parallel_ms` or `transcribe_only_ms`.
    var processingSecondsPerAudioSecond: Double?
    var diarizationSecondsPerAudioSecond: Double?
    var outputSecondsPerAudioSecond: Double?
    /// Absolute seconds from transcribe start until WhisperKit's first progress
    /// callback (VAD chunking plus the first encoder pass); does not scale with audio length.
    var firstProgressSeconds: Double?
    /// Absolute seconds to initialize WhisperKit (+ SpeakerKit when recorded).
    var modelLoadSeconds: Double?

    init(
        totalSecondsPerAudioSecond: Double? = nil,
        audioLoadSecondsPerAudioSecond: Double? = nil,
        processingSecondsPerAudioSecond: Double? = nil,
        diarizationSecondsPerAudioSecond: Double? = nil,
        outputSecondsPerAudioSecond: Double? = nil,
        firstProgressSeconds: Double? = nil,
        modelLoadSeconds: Double? = nil
    ) {
        self.totalSecondsPerAudioSecond = totalSecondsPerAudioSecond
        self.audioLoadSecondsPerAudioSecond = audioLoadSecondsPerAudioSecond
        self.processingSecondsPerAudioSecond = processingSecondsPerAudioSecond
        self.diarizationSecondsPerAudioSecond = diarizationSecondsPerAudioSecond
        self.outputSecondsPerAudioSecond = outputSecondsPerAudioSecond
        self.firstProgressSeconds = firstProgressSeconds
        self.modelLoadSeconds = modelLoadSeconds
    }
}

/// Run-timing history, stored as rows of `timing_history`, and helpers for
/// ETA prediction.
///
/// As with `ProcessingStore`, the `record` column is the verbatim single-line
/// JSON of the 2.x JSONL ledger; the lifted `model` and `diarization` columns
/// only narrow the query. Callers gate both reads and writes on
/// `TRANSCRIBE_ETA_HINTS` / `--eta-hints` (and `--stateless`).
enum TimingStore {
    private static let recentLimit = 50

    static func append(_ record: RunTimingRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard let line = String(data: data, encoding: .utf8) else {
            throw TranscribeError(message: "Failed to encode timing record.", exitCode: .outputWrite)
        }
        try insert(
            line: line,
            recordedAt: record.ended_at,
            model: record.model,
            diarization: record.diarization_enabled
        )
    }

    /// Stores one ledger line verbatim, lifting its key columns leniently;
    /// see `ProcessingStore.appendVerbatim(line:)`.
    static func appendVerbatim(line: String) throws {
        let fields = StateStore.ledgerFields(line)
        try insert(
            line: line,
            recordedAt: fields["ended_at"] as? String ?? "",
            model: fields["model"] as? String ?? "",
            diarization: fields["diarization_enabled"] as? Bool ?? false
        )
    }

    private static func insert(line: String, recordedAt: String, model: String, diarization: Bool) throws {
        try StateStore.withDatabase { database in
            try database.inTransaction(.write) {
                try database.execute(
                    "INSERT INTO timing_history (recorded_at, model, diarization, record) VALUES (?, ?, ?, ?)",
                    [
                        .text(recordedAt),
                        .text(StateStore.normalizedKey(model)),
                        .integer(diarization ? 1 : 0),
                        .text(line),
                    ]
                )
            }
        }
    }

    /// Reads up to `limit` recent records matching model and diarization flag (newest last).
    static func loadRecent(
        model: String,
        diarizationEnabled: Bool,
        limit: Int = recentLimit
    ) throws -> [RunTimingRecord] {
        try loadRecent(
            where: "model = ? AND diarization = ?",
            [.text(StateStore.normalizedKey(model)), .integer(diarizationEnabled ? 1 : 0)],
            limit: limit
        ) { r in
            r.model == model && r.diarization_enabled == diarizationEnabled
        }
    }

    /// Reads up to `limit` recent records matching model only (newest last).
    static func loadRecent(
        model: String,
        limit: Int = recentLimit
    ) throws -> [RunTimingRecord] {
        try loadRecent(where: "model = ?", [.text(StateStore.normalizedKey(model))], limit: limit) { $0.model == model }
    }

    /// The limit counts decoded, matching records, so it cannot be a SQL
    /// `LIMIT`: an undecodable row must not take a slot. The predicate is
    /// re-applied to the decoded record so a row stored with placeholder keys
    /// can never match by accident.
    private static func loadRecent(
        where condition: String,
        _ bindings: [SQLValue],
        limit: Int,
        matching predicate: (RunTimingRecord) -> Bool
    ) throws -> [RunTimingRecord] {
        let lines = try StateStore.withDatabase { database in
            try database.inTransaction(.read) {
                try database.query(
                    "SELECT record FROM timing_history WHERE \(condition) ORDER BY rowid DESC",
                    bindings
                ) { $0.text(0) ?? "" }
            }
        }
        var records: [RunTimingRecord] = []
        let decoder = JSONDecoder()
        for line in lines {
            guard records.count < limit else { break }
            guard let r = try? decoder.decode(RunTimingRecord.self, from: Data(line.utf8)), predicate(r) else { continue }
            records.append(r)
        }
        return records.reversed()
    }

    /// Median of `total_ms / (1000 * audio_duration_s)` = wall seconds per second of audio.
    static func medianWallSecondsPerAudioSecond(records: [RunTimingRecord]) -> Double? {
        guard !records.isEmpty else { return nil }
        let ratios: [Double] = records.compactMap { r in
            guard r.audio_duration_s > 0 else { return nil }
            return Double(r.total_ms) / 1000.0 / r.audio_duration_s
        }
        guard !ratios.isEmpty else { return nil }
        return median(ratios)
    }

    /// Median of source audio load seconds per second of audio.
    static func medianAudioLoadSecondsPerAudioSecond(records: [RunTimingRecord]) -> Double? {
        let ratios: [Double] = records.compactMap { r in
            guard r.audio_duration_s > 0, r.audio_load_ms > 0 else { return nil }
            return Double(r.audio_load_ms) / 1000.0 / r.audio_duration_s
        }
        return median(ratios)
    }

    /// Median wall seconds per second of audio for the transcribe (+ diarize)
    /// block: `parallel_ms` when diarization ran, otherwise `transcribe_only_ms`.
    static func medianProcessingSecondsPerAudioSecond(records: [RunTimingRecord]) -> Double? {
        let ratios: [Double] = records.compactMap { r in
            let ms = r.parallel_ms > 0 ? r.parallel_ms : r.transcribe_only_ms
            guard r.audio_duration_s > 0, ms > 0 else { return nil }
            return Double(ms) / 1000.0 / r.audio_duration_s
        }
        return median(ratios)
    }

    /// Median absolute seconds until WhisperKit's first progress callback.
    static func medianFirstProgressSeconds(records: [RunTimingRecord]) -> Double? {
        let values: [Double] = records.compactMap { r in
            guard r.whisper_first_progress_ms > 0 else { return nil }
            return Double(r.whisper_first_progress_ms) / 1000.0
        }
        return median(values)
    }

    /// Median absolute seconds spent initializing WhisperKit and SpeakerKit.
    /// Records with `whisper_init_ms == 0` (models reused within a batch) are skipped.
    static func medianModelLoadSeconds(records: [RunTimingRecord]) -> Double? {
        let values: [Double] = records.compactMap { r in
            guard r.whisper_init_ms > 0 else { return nil }
            return Double(r.whisper_init_ms + r.speaker_init_ms) / 1000.0
        }
        return median(values)
    }

    /// Median of SpeakerKit diarization full-pipeline seconds per second of audio.
    static func medianDiarizationSecondsPerAudioSecond(records: [RunTimingRecord]) -> Double? {
        let ratios: [Double] = records.compactMap { r in
            guard r.diarization_enabled, r.audio_duration_s > 0, r.speaker_diarization_ms > 0 else { return nil }
            return Double(r.speaker_diarization_ms) / 1000.0 / r.audio_duration_s
        }
        return median(ratios)
    }

    /// Median of merge + output write seconds per second of audio.
    static func medianOutputSecondsPerAudioSecond(records: [RunTimingRecord]) -> Double? {
        let ratios: [Double] = records.compactMap { r in
            let ms = r.merge_ms + r.write_outputs_ms
            guard r.audio_duration_s > 0, ms > 0 else { return nil }
            return Double(ms) / 1000.0 / r.audio_duration_s
        }
        return median(ratios)
    }

    /// - Parameters:
    ///   - totalRecords: Recent runs matching model and diarization flag; used
    ///     for whole-run and processing-block ratios whose cost depends on the phase mix.
    ///   - phaseRecords: Recent runs matching model only; used for per-phase
    ///     predictors that do not depend on diarization.
    static func historicalRatios(
        totalRecords: [RunTimingRecord],
        phaseRecords: [RunTimingRecord]
    ) -> HistoricalTimingRatios {
        HistoricalTimingRatios(
            totalSecondsPerAudioSecond: medianWallSecondsPerAudioSecond(records: totalRecords),
            audioLoadSecondsPerAudioSecond: medianAudioLoadSecondsPerAudioSecond(records: phaseRecords),
            processingSecondsPerAudioSecond: medianProcessingSecondsPerAudioSecond(records: totalRecords)
                ?? medianProcessingSecondsPerAudioSecond(records: phaseRecords),
            diarizationSecondsPerAudioSecond: medianDiarizationSecondsPerAudioSecond(records: phaseRecords),
            outputSecondsPerAudioSecond: medianOutputSecondsPerAudioSecond(records: phaseRecords),
            firstProgressSeconds: medianFirstProgressSeconds(records: phaseRecords),
            modelLoadSeconds: medianModelLoadSeconds(records: phaseRecords)
        )
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[mid]
        }
        return (sorted[mid - 1] + sorted[mid]) / 2.0
    }
}
