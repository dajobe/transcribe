import Foundation

/// One completed run, stored as a single JSON object (JSON Lines file).
struct RunTimingRecord: Codable, Equatable {
    static let schemaVersion = 1

    var schema_version: Int
    /// ISO8601 with fractional seconds if needed.
    var ended_at: String
    var transcribe_version: String
    var model: String
    var diarization_enabled: Bool
    /// Input filename only (no path).
    var input_basename: String
    var file_bytes: Int64
    var audio_duration_s: Double
    var segment_count: Int
    var speakers_detected: Int?

    var audio_load_ms: Int64
    var whisper_init_ms: Int64
    var speaker_init_ms: Int64
    /// Wall time for concurrent transcribe+diarize when diarization is on; 0 when transcript-only path uses transcribe_only_ms.
    var parallel_ms: Int64
    var transcribe_only_ms: Int64
    var merge_ms: Int64
    var write_outputs_ms: Int64
    var total_ms: Int64

    var decoding_windows: Int?
}
