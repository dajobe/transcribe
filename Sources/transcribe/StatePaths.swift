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

    /// The 2.x JSON Lines timing ledger, superseded by the state database's
    /// `timing_history` table; kept as the legacy location migration reads.
    static func timingHistoryURL() throws -> URL {
        try stateDirectoryURL().appendingPathComponent("timing_history.jsonl", isDirectory: false)
    }

    /// The 2.x JSON Lines processing ledger, superseded by the state
    /// database's `processing_history` table; kept as the legacy location
    /// migration reads.
    static func processingHistoryURL() throws -> URL {
        try stateDirectoryURL().appendingPathComponent("processing_history.jsonl", isDirectory: false)
    }

    /// SQLite state database (`StateDatabase`); its `-wal` and `-shm`
    /// companions sit beside it.
    static func stateDatabaseURL() throws -> URL {
        try stateDirectoryURL().appendingPathComponent("state.db", isDirectory: false)
    }

    /// Bootstrap lock held while a process creates, rebuilds or migrates the
    /// state database. Normal operation relies on database transactions.
    static func initLockURL() throws -> URL {
        try stateDirectoryURL().appendingPathComponent("init.lock", isDirectory: false)
    }

    /// Directory of per-document advisory locks held around export render and
    /// record commit for managed documents.
    static func locksDirectoryURL() throws -> URL {
        try stateDirectoryURL().appendingPathComponent("locks", isDirectory: true)
    }
}
