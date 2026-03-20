import Foundation

/// Resolves the directory for application state (timing history, etc.).
enum StatePaths {
    /// Base directory: `XDG_STATE_HOME/transcribe` if set, else macOS Application Support, else `~/.local/state/transcribe`.
    static func stateDirectoryURL() throws -> URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_STATE_HOME"], !xdg.isEmpty {
            let expanded = (xdg as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded, isDirectory: true).appendingPathComponent("transcribe", isDirectory: true)
        }
#if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("transcribe", isDirectory: true)
#else
        let home = (("~") as NSString).expandingTildeInPath
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".local/state/transcribe", isDirectory: true)
#endif
    }

    /// JSON Lines file of completed run timing records.
    static func timingHistoryURL() throws -> URL {
        try stateDirectoryURL().appendingPathComponent("timing_history.jsonl", isDirectory: false)
    }
}
