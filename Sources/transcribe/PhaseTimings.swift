import Foundation

/// Wall-clock phase durations collected during a pipeline run (milliseconds).
struct PhaseTimings: Equatable {
    var audioLoadMs: Int64 = 0
    var whisperInitMs: Int64 = 0
    var speakerInitMs: Int64 = 0
    /// Concurrent transcribe + diarization wall time (diarization path).
    var parallelMs: Int64 = 0
    /// `whisperKit.transcribe` only (`--no-diarize` or short-audio path).
    var transcribeOnlyMs: Int64 = 0
    var mergeMs: Int64 = 0
    var decodingWindows: Int? = nil
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
    }
}
