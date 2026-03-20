import Foundation

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
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: out)
        } else {
            try out.write(to: url)
        }
    }

    /// Reads up to `limit` recent records matching model and diarization flag (newest last).
    static func loadRecent(
        model: String,
        diarizationEnabled: Bool,
        limit: Int = recentLimit
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
            if r.model == model && r.diarization_enabled == diarizationEnabled {
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
        let sorted = ratios.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[mid]
        }
        return (sorted[mid - 1] + sorted[mid]) / 2.0
    }
}
