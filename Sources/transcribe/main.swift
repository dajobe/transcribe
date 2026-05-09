import ArgumentParser

@main
struct Transcribe: AsyncParsableCommand {
    // When bumping this, run `make tag` (or `make release`) immediately
    // afterwards so the matching `vX.Y.Z` annotated tag lands with the
    // version-bump commit. See README "Releasing" and AGENTS.md.
    static let version = "2.0.0"

    /// Default Whisper model when `--model` is not supplied.
    /// `openai_whisper-large-v3_turbo` is the strongest model that runs at
    /// usable speed on Apple Silicon with the Neural Engine; the previously
    /// auto-selected `openai_whisper-base` produced poor results on real-world
    /// noisy or far-field audio (meetings, conferences, voice notes).
    /// Override with `--model <name>`.
    static let defaultModel = "openai_whisper-large-v3_turbo"

    static var configuration = CommandConfiguration(
        abstract: "On-device meeting transcription with optional speaker diarization.",
        usage: "transcribe [<global-options>] <source> [<source-options>]",
        discussion: """
            Transcribes an audio file using WhisperKit and optionally adds speaker \
            labels using SpeakerKit. All processing runs on-device on Apple Silicon. \
            Output formats: txt, json, srt, vtt, md (use --format to select).

            Source commands:
              file <audio-file>
              dir [dir-options] <directory>
              voice-memos [voice-memos-options]

            Global options must appear before the source command. For source-specific \
            options, run `transcribe file --help`, `transcribe dir --help`, or \
            `transcribe voice-memos --help`.
            """,
        version: version
    )

    @OptionGroup var options: SharedTranscriptionOptions

    @Argument(
        parsing: .captureForPassthrough,
        help: "Source command and arguments, or a file/directory path alias."
    )
    var sourceArgs: [String] = []

    func run() async throws {
        await runAndExitOnError {
            try await SourceCommandDispatcher(options: options, sourceArgs: sourceArgs).run()
        }
    }
}
