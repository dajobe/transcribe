import Foundation

/// Process-wide access to the state database for the stores built on it.
///
/// One lazily opened `StateDatabase` serves the whole process: the wrapper
/// owns a single connection, and construction runs the init guard, which
/// should happen once per process rather than once per store call. Nothing
/// opens the database until a store first needs it, so a `--stateless` run,
/// whose code paths never call a store, never creates it or takes
/// `init.lock`.
///
/// Every use runs under one recursive lock. The CLI already serializes state
/// access, but the lock makes that a guarantee for the `SQLITE_OPEN_NOMUTEX`
/// connection rather than an assumption, and lets a store call made inside
/// another store's `withDatabase` body reuse the same connection.
///
/// The instance is keyed on the database path resolved at each call. Tests
/// point `XDG_STATE_HOME` at a fresh directory per test within one process,
/// so a path change (or a database file deleted underneath the cached
/// connection) opens a new instance instead of writing to the old one.
enum StateStore {
    private static let lock = NSRecursiveLock()
    private static var cached: StateDatabase?
    private static var registeredExitHook = false

    static func withDatabase<T>(_ body: (StateDatabase) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(try current())
    }

    /// Checkpoints and closes the shared connection, if one is open. Runs at
    /// process exit so the `-wal` file is empty at rest.
    static func closeShared() {
        // An exit raised while another thread is mid-statement must not
        // deadlock on the lock; skipping the checkpoint there loses nothing.
        guard lock.try() else { return }
        defer { lock.unlock() }
        cached?.close()
        cached = nil
    }

    /// Canonical (NFC) form for lifted key columns and their query bindings.
    /// Swift's `==` matches strings by canonical equivalence, but SQLite's
    /// `=` compares bytes, so an NFD spelling of a filename-derived source ID
    /// would silently stop matching its NFC twin once lifted into a column.
    /// The verbatim record text is never normalized.
    static func normalizedKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
    }

    /// Top-level fields of a ledger line, for lifting key columns out of a
    /// verbatim row. Lenient by design: a line that is not a JSON object
    /// yields no fields and is stored with placeholder keys, never dropped.
    static func ledgerFields(_ line: String) -> [String: Any] {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private static func current() throws -> StateDatabase {
        let url = try StatePaths.stateDatabaseURL()
        if let cached, cached.databaseURL == url, FileManager.default.fileExists(atPath: url.path) {
            return cached
        }
        // Dropping the stale instance closes its connection without a
        // checkpoint; its directory may already be gone.
        cached = nil
        let database = try StateDatabase()
        cached = database
        if !registeredExitHook {
            registeredExitHook = true
            atexit { StateStore.closeShared() }
        }
        return database
    }
}
