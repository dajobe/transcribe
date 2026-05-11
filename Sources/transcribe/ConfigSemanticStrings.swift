import Foundation

/// Shared wording for `transcribe config show` `#` comment lines and matching global `--help` text.
enum ConfigSemanticStrings {
    /// Language: unset / `(auto)` in config display.
    static let languageWhenUnset =
        "When omitted or (auto), Whisper auto-detects the language."

    /// output.prefix: no fixed string default; naming comes from the input.
    static let outputPrefixWhenUnset =
        "When omitted, the output basename is derived from the input path."

    static let speakersMinWhenUnset =
        "When omitted, no minimum speaker-count hint is applied."

    static let speakersMaxWhenUnset =
        "When omitted, no maximum speaker-count hint is applied."
}
