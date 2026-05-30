import Foundation

struct HistoricalTimingRatios: Sendable, Equatable {
    var totalSecondsPerAudioSecond: Double?
    var audioLoadSecondsPerAudioSecond: Double?
    var whisperPrepSecondsPerAudioSecond: Double?
    var encodingSecondsPerAudioSecond: Double?
    var transcriptionSecondsPerAudioSecond: Double?
    var diarizationSecondsPerAudioSecond: Double?
    var outputSecondsPerAudioSecond: Double?

    init(
        totalSecondsPerAudioSecond: Double? = nil,
        audioLoadSecondsPerAudioSecond: Double? = nil,
        whisperPrepSecondsPerAudioSecond: Double? = nil,
        encodingSecondsPerAudioSecond: Double? = nil,
        transcriptionSecondsPerAudioSecond: Double? = nil,
        diarizationSecondsPerAudioSecond: Double? = nil,
        outputSecondsPerAudioSecond: Double? = nil
    ) {
        self.totalSecondsPerAudioSecond = totalSecondsPerAudioSecond
        self.audioLoadSecondsPerAudioSecond = audioLoadSecondsPerAudioSecond
        self.whisperPrepSecondsPerAudioSecond = whisperPrepSecondsPerAudioSecond
        self.encodingSecondsPerAudioSecond = encodingSecondsPerAudioSecond
        self.transcriptionSecondsPerAudioSecond = transcriptionSecondsPerAudioSecond
        self.diarizationSecondsPerAudioSecond = diarizationSecondsPerAudioSecond
        self.outputSecondsPerAudioSecond = outputSecondsPerAudioSecond
    }
}

/// Append-only JSON Lines store and helpers for ETA prediction.
enum TimingStore {
    private static let recentLimit = 50

    /// Append one record; creates parent directory if needed.
    static func append(_ record: RunTimingRecord) throws {
        let url = try StatePaths.timingHistoryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        guard var line = String(data: data, encoding: .utf8) else {
            throw TranscribeError(message: "Failed to encode timing record.", exitCode: .outputWrite)
        }
        line.append("\n")
        guard let out = line.data(using: .utf8) else { return }
        try LockedAppendWriter.append(out, to: url)
    }

    /// Reads up to `limit` recent records matching model and diarization flag (newest last).
    static func loadRecent(
        model: String,
        diarizationEnabled: Bool,
        limit: Int = recentLimit
    ) throws -> [RunTimingRecord] {
        try loadRecent(limit: limit) { r in
            r.model == model && r.diarization_enabled == diarizationEnabled
        }
    }

    /// Reads up to `limit` recent records matching model only (newest last).
    static func loadRecent(
        model: String,
        limit: Int = recentLimit
    ) throws -> [RunTimingRecord] {
        try loadRecent(limit: limit) { $0.model == model }
    }

    private static func loadRecent(
        limit: Int,
        matching predicate: (RunTimingRecord) -> Bool
    ) throws -> [RunTimingRecord] {
        let url = try StatePaths.timingHistoryURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var records: [RunTimingRecord] = []
        let decoder = JSONDecoder()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let row = line.data(using: .utf8) else { continue }
            guard let r = try? decoder.decode(RunTimingRecord.self, from: row) else { continue }
            if predicate(r) {
                records.append(r)
            }
        }
        if records.count <= limit { return records }
        return Array(records.suffix(limit))
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

    /// Median of Whisper audio-encoder seconds per second of audio.
    static func medianEncodingSecondsPerAudioSecond(records: [RunTimingRecord]) -> Double? {
        let ratios: [Double] = records.compactMap { r in
            guard r.audio_duration_s > 0, r.whisper_encoding_ms > 0 else { return nil }
            return Double(r.whisper_encoding_ms) / 1000.0 / r.audio_duration_s
        }
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

    /// Median of Whisper preprocessing (window prep + log-mel) seconds per second of audio.
    static func medianWhisperPrepSecondsPerAudioSecond(records: [RunTimingRecord]) -> Double? {
        let ratios: [Double] = records.compactMap { r in
            let ms = r.whisper_audio_processing_ms + r.whisper_logmels_ms
            guard r.audio_duration_s > 0, ms > 0 else { return nil }
            return Double(ms) / 1000.0 / r.audio_duration_s
        }
        return median(ratios)
    }

    /// Median of Whisper decoder loop seconds per second of audio.
    static func medianTranscriptionSecondsPerAudioSecond(records: [RunTimingRecord]) -> Double? {
        let ratios: [Double] = records.compactMap { r in
            guard r.audio_duration_s > 0, r.whisper_decoding_loop_ms > 0 else { return nil }
            return Double(r.whisper_decoding_loop_ms) / 1000.0 / r.audio_duration_s
        }
        return median(ratios)
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

    static func historicalRatios(
        totalRecords: [RunTimingRecord],
        phaseRecords: [RunTimingRecord]
    ) -> HistoricalTimingRatios {
        HistoricalTimingRatios(
            totalSecondsPerAudioSecond: medianWallSecondsPerAudioSecond(records: totalRecords),
            audioLoadSecondsPerAudioSecond: medianAudioLoadSecondsPerAudioSecond(records: phaseRecords),
            whisperPrepSecondsPerAudioSecond: medianWhisperPrepSecondsPerAudioSecond(records: phaseRecords),
            encodingSecondsPerAudioSecond: medianEncodingSecondsPerAudioSecond(records: phaseRecords),
            transcriptionSecondsPerAudioSecond: medianTranscriptionSecondsPerAudioSecond(records: phaseRecords),
            diarizationSecondsPerAudioSecond: medianDiarizationSecondsPerAudioSecond(records: phaseRecords),
            outputSecondsPerAudioSecond: medianOutputSecondsPerAudioSecond(records: phaseRecords)
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
