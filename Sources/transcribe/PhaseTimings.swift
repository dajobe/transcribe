import Foundation

/// Wall-clock phase durations collected during a pipeline run (milliseconds).
struct PhaseTimings: Equatable {
    var audioLoadMs: Int64 = 0
    var whisperInitMs: Int64 = 0
    var speakerInitMs: Int64 = 0
    /// Concurrent transcribe + diarization wall time (diarization path).
    var parallelMs: Int64 = 0
    /// `whisperKit.transcribe` only (`--transcript-only` or short-audio path).
    var transcribeOnlyMs: Int64 = 0
    var mergeMs: Int64 = 0
    var decodingWindows: Int? = nil
    var whisperAudioProcessingMs: Int64 = 0
    var whisperLogmelsMs: Int64 = 0
    var whisperEncodingMs: Int64 = 0
    var whisperDecodingLoopMs: Int64 = 0
    var whisperTotalAudioProcessingRuns: Double = 0
    var whisperTotalLogmelRuns: Double = 0
    var whisperTotalEncodingRuns: Double = 0
    var whisperTotalDecodingWindows: Double = 0
    var whisperFirstProgressMs: Int64 = 0
    var speakerDiarizationMs: Int64 = 0
    var speakerSegmenterMs: Int64 = 0
    var speakerEmbedderMs: Int64 = 0
    var speakerClusteringMs: Int64 = 0
    var speakerTotalChunks: Int = 0
    var speakerTotalEmbeddings: Int = 0
}

extension RunTimingRecord {
    init(
        endedAt: Date,
        transcribeVersion: String,
        model: String,
        diarizationEnabled: Bool,
        inputBasename: String,
        fileBytes: Int64,
        audioDurationS: Double,
        segmentCount: Int,
        speakersDetected: Int?,
        phases: PhaseTimings,
        writeOutputsMs: Int64,
        totalMs: Int64
    ) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.schema_version = RunTimingRecord.schemaVersion
        self.ended_at = formatter.string(from: endedAt)
        self.transcribe_version = transcribeVersion
        self.model = model
        self.diarization_enabled = diarizationEnabled
        self.input_basename = inputBasename
        self.file_bytes = fileBytes
        self.audio_duration_s = audioDurationS
        self.segment_count = segmentCount
        self.speakers_detected = speakersDetected
        self.audio_load_ms = phases.audioLoadMs
        self.whisper_init_ms = phases.whisperInitMs
        self.speaker_init_ms = phases.speakerInitMs
        self.parallel_ms = phases.parallelMs
        self.transcribe_only_ms = phases.transcribeOnlyMs
        self.merge_ms = phases.mergeMs
        self.write_outputs_ms = writeOutputsMs
        self.total_ms = totalMs
        self.decoding_windows = phases.decodingWindows
        self.whisper_audio_processing_ms = phases.whisperAudioProcessingMs
        self.whisper_logmels_ms = phases.whisperLogmelsMs
        self.whisper_encoding_ms = phases.whisperEncodingMs
        self.whisper_decoding_loop_ms = phases.whisperDecodingLoopMs
        self.whisper_total_audio_processing_runs = phases.whisperTotalAudioProcessingRuns
        self.whisper_total_logmel_runs = phases.whisperTotalLogmelRuns
        self.whisper_total_encoding_runs = phases.whisperTotalEncodingRuns
        self.whisper_total_decoding_windows = phases.whisperTotalDecodingWindows
        self.whisper_first_progress_ms = phases.whisperFirstProgressMs
        self.speaker_diarization_ms = phases.speakerDiarizationMs
        self.speaker_segmenter_ms = phases.speakerSegmenterMs
        self.speaker_embedder_ms = phases.speakerEmbedderMs
        self.speaker_clustering_ms = phases.speakerClusteringMs
        self.speaker_total_chunks = phases.speakerTotalChunks
        self.speaker_total_embeddings = phases.speakerTotalEmbeddings
    }
}
