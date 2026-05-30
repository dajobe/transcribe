import Foundation

/// Single source of truth for built-in defaults (CLI help, `config show`, merge fallback).
enum TranscriptionDefaults {
    /// Delegates to `Transcribe.defaultModel` so release tagging rules stay centralized.
    static var defaultModel: String { Transcribe.defaultModel }

    static let outputDir = "."
    static let format = "txt,json"
    static let modelDir = "~/.cache/transcribe"
    static let speakerMerge = "subsegment"

    static let speakersEnabled = true
    static let verbose = false
    static let logLevel = TranscribeEventLevel.info
    /// When true, timing stats / ETA hints are allowed unless env disables them.
    static let etaHintsEnabled = true
    static let progressLogMode = ProgressLogMode.auto

    static let audioEncoderCompute = ComputeUnitsOption.auto
    static let textDecoderCompute = ComputeUnitsOption.auto
    static let segmenterCompute = ComputeUnitsOption.auto
    static let embedderCompute = ComputeUnitsOption.auto

    // MARK: Directory source ([`DirectoryInputOptions`])

    static let dirSort: InputSortOrder = .recorded
    static let dirSessionGapMinutes = 10
    static let dirInputTimeSource: InputTimeSource = .auto
    static let dirSessionNaming: SessionNamingMode = .auto

    // MARK: Voice Memos ([`VoiceMemosSourceArguments`])

    /// Same path as [`VoiceMemosImport.defaultRecordingsDirectory`].
    static let voiceMemosRecordingsDir = VoiceMemosImport.defaultRecordingsDirectory
    static let voiceMemosSessionGapMinutes = 10

    /// Maximum decoded audio size in megabytes (`0` disables the hard cap).
    static let maxAudioMB = 2048
}
