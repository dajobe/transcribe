import ArgumentParser

/// Boolean CLI options expressed as `on` / `off` (e.g. `--eta-hints off`).
enum OnOff: String, CaseIterable, ExpressibleByArgument {
    case on
    case off
}

/// How processing progress is rendered.
enum ProgressLogMode: String, CaseIterable, ExpressibleByArgument {
    /// Live TUI when stdout is a terminal; otherwise stdout event logs.
    case auto
    /// Plain stdout event logs for pipes and batch logs.
    case plain
    /// No progress/status rendering.
    case off
}

/// Directory input: whether to recover ordering times from filename prefixes when embedded metadata is missing or untrusted.
enum InputTimeSource: String, CaseIterable, ExpressibleByArgument {
    case auto
    case embedded
    case filename
    case off

    var filenameRecoveryEnabled: Bool {
        switch self {
        case .auto, .filename: return true
        case .embedded, .off: return false
        }
    }
}

/// Directory input: how session output basenames are chosen.
enum SessionNamingMode: String, CaseIterable, ExpressibleByArgument {
    case auto
    case clip
    case off

    var autoSessionBasenameEnabled: Bool {
        switch self {
        case .auto: return true
        case .clip, .off: return false
        }
    }
}
