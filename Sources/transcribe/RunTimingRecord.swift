import Foundation

/// One completed run, stored as a single JSON object (JSON Lines file).
struct RunTimingRecord: Codable, Equatable {
    static let schemaVersion = 2

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

    var whisper_audio_processing_ms: Int64
    var whisper_logmels_ms: Int64
    var whisper_encoding_ms: Int64
    var whisper_decoding_loop_ms: Int64
    var whisper_total_audio_processing_runs: Double
    var whisper_total_logmel_runs: Double
    var whisper_total_encoding_runs: Double
    var whisper_total_decoding_windows: Double
    var whisper_first_progress_ms: Int64
    var speaker_diarization_ms: Int64
    var speaker_segmenter_ms: Int64
    var speaker_embedder_ms: Int64
    var speaker_clustering_ms: Int64
    var speaker_total_chunks: Int
    var speaker_total_embeddings: Int

    init(
        schema_version: Int = schemaVersion,
        ended_at: String,
        transcribe_version: String,
        model: String,
        diarization_enabled: Bool,
        input_basename: String,
        file_bytes: Int64,
        audio_duration_s: Double,
        segment_count: Int,
        speakers_detected: Int?,
        audio_load_ms: Int64,
        whisper_init_ms: Int64,
        speaker_init_ms: Int64,
        parallel_ms: Int64,
        transcribe_only_ms: Int64,
        merge_ms: Int64,
        write_outputs_ms: Int64,
        total_ms: Int64,
        decoding_windows: Int?,
        whisper_audio_processing_ms: Int64 = 0,
        whisper_logmels_ms: Int64 = 0,
        whisper_encoding_ms: Int64 = 0,
        whisper_decoding_loop_ms: Int64 = 0,
        whisper_total_audio_processing_runs: Double = 0,
        whisper_total_logmel_runs: Double = 0,
        whisper_total_encoding_runs: Double = 0,
        whisper_total_decoding_windows: Double = 0,
        whisper_first_progress_ms: Int64 = 0,
        speaker_diarization_ms: Int64 = 0,
        speaker_segmenter_ms: Int64 = 0,
        speaker_embedder_ms: Int64 = 0,
        speaker_clustering_ms: Int64 = 0,
        speaker_total_chunks: Int = 0,
        speaker_total_embeddings: Int = 0
    ) {
        self.schema_version = schema_version
        self.ended_at = ended_at
        self.transcribe_version = transcribe_version
        self.model = model
        self.diarization_enabled = diarization_enabled
        self.input_basename = input_basename
        self.file_bytes = file_bytes
        self.audio_duration_s = audio_duration_s
        self.segment_count = segment_count
        self.speakers_detected = speakers_detected
        self.audio_load_ms = audio_load_ms
        self.whisper_init_ms = whisper_init_ms
        self.speaker_init_ms = speaker_init_ms
        self.parallel_ms = parallel_ms
        self.transcribe_only_ms = transcribe_only_ms
        self.merge_ms = merge_ms
        self.write_outputs_ms = write_outputs_ms
        self.total_ms = total_ms
        self.decoding_windows = decoding_windows
        self.whisper_audio_processing_ms = whisper_audio_processing_ms
        self.whisper_logmels_ms = whisper_logmels_ms
        self.whisper_encoding_ms = whisper_encoding_ms
        self.whisper_decoding_loop_ms = whisper_decoding_loop_ms
        self.whisper_total_audio_processing_runs = whisper_total_audio_processing_runs
        self.whisper_total_logmel_runs = whisper_total_logmel_runs
        self.whisper_total_encoding_runs = whisper_total_encoding_runs
        self.whisper_total_decoding_windows = whisper_total_decoding_windows
        self.whisper_first_progress_ms = whisper_first_progress_ms
        self.speaker_diarization_ms = speaker_diarization_ms
        self.speaker_segmenter_ms = speaker_segmenter_ms
        self.speaker_embedder_ms = speaker_embedder_ms
        self.speaker_clustering_ms = speaker_clustering_ms
        self.speaker_total_chunks = speaker_total_chunks
        self.speaker_total_embeddings = speaker_total_embeddings
    }

    private enum CodingKeys: String, CodingKey {
        case schema_version, ended_at, transcribe_version, model, diarization_enabled
        case input_basename, file_bytes, audio_duration_s, segment_count, speakers_detected
        case audio_load_ms, whisper_init_ms, speaker_init_ms
        case parallel_ms, transcribe_only_ms, merge_ms, write_outputs_ms, total_ms
        case decoding_windows
        case whisper_audio_processing_ms, whisper_logmels_ms, whisper_encoding_ms
        case whisper_decoding_loop_ms, whisper_total_audio_processing_runs
        case whisper_total_logmel_runs, whisper_total_encoding_runs
        case whisper_total_decoding_windows, whisper_first_progress_ms
        case speaker_diarization_ms, speaker_segmenter_ms, speaker_embedder_ms
        case speaker_clustering_ms, speaker_total_chunks, speaker_total_embeddings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schema_version = try c.decodeIfPresent(Int.self, forKey: .schema_version) ?? 1
        self.ended_at = try c.decode(String.self, forKey: .ended_at)
        self.transcribe_version = try c.decode(String.self, forKey: .transcribe_version)
        self.model = try c.decode(String.self, forKey: .model)
        self.diarization_enabled = try c.decode(Bool.self, forKey: .diarization_enabled)
        self.input_basename = try c.decode(String.self, forKey: .input_basename)
        self.file_bytes = try c.decode(Int64.self, forKey: .file_bytes)
        self.audio_duration_s = try c.decode(Double.self, forKey: .audio_duration_s)
        self.segment_count = try c.decode(Int.self, forKey: .segment_count)
        self.speakers_detected = try c.decodeIfPresent(Int.self, forKey: .speakers_detected)
        self.audio_load_ms = try c.decode(Int64.self, forKey: .audio_load_ms)
        self.whisper_init_ms = try c.decode(Int64.self, forKey: .whisper_init_ms)
        self.speaker_init_ms = try c.decode(Int64.self, forKey: .speaker_init_ms)
        self.parallel_ms = try c.decode(Int64.self, forKey: .parallel_ms)
        self.transcribe_only_ms = try c.decode(Int64.self, forKey: .transcribe_only_ms)
        self.merge_ms = try c.decode(Int64.self, forKey: .merge_ms)
        self.write_outputs_ms = try c.decode(Int64.self, forKey: .write_outputs_ms)
        self.total_ms = try c.decode(Int64.self, forKey: .total_ms)
        self.decoding_windows = try c.decodeIfPresent(Int.self, forKey: .decoding_windows)
        self.whisper_audio_processing_ms = try c.decodeIfPresent(Int64.self, forKey: .whisper_audio_processing_ms) ?? 0
        self.whisper_logmels_ms = try c.decodeIfPresent(Int64.self, forKey: .whisper_logmels_ms) ?? 0
        self.whisper_encoding_ms = try c.decodeIfPresent(Int64.self, forKey: .whisper_encoding_ms) ?? 0
        self.whisper_decoding_loop_ms = try c.decodeIfPresent(Int64.self, forKey: .whisper_decoding_loop_ms) ?? 0
        self.whisper_total_audio_processing_runs = try c.decodeIfPresent(Double.self, forKey: .whisper_total_audio_processing_runs) ?? 0
        self.whisper_total_logmel_runs = try c.decodeIfPresent(Double.self, forKey: .whisper_total_logmel_runs) ?? 0
        self.whisper_total_encoding_runs = try c.decodeIfPresent(Double.self, forKey: .whisper_total_encoding_runs) ?? 0
        self.whisper_total_decoding_windows = try c.decodeIfPresent(Double.self, forKey: .whisper_total_decoding_windows) ?? 0
        self.whisper_first_progress_ms = try c.decodeIfPresent(Int64.self, forKey: .whisper_first_progress_ms) ?? 0
        self.speaker_diarization_ms = try c.decodeIfPresent(Int64.self, forKey: .speaker_diarization_ms) ?? 0
        self.speaker_segmenter_ms = try c.decodeIfPresent(Int64.self, forKey: .speaker_segmenter_ms) ?? 0
        self.speaker_embedder_ms = try c.decodeIfPresent(Int64.self, forKey: .speaker_embedder_ms) ?? 0
        self.speaker_clustering_ms = try c.decodeIfPresent(Int64.self, forKey: .speaker_clustering_ms) ?? 0
        self.speaker_total_chunks = try c.decodeIfPresent(Int.self, forKey: .speaker_total_chunks) ?? 0
        self.speaker_total_embeddings = try c.decodeIfPresent(Int.self, forKey: .speaker_total_embeddings) ?? 0
    }
}
