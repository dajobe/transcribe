import Foundation
import SQLite3

/// Errors raised by `StateDatabase`. `busy` is separate from other SQLite
/// failures because it is the one a user can fix by waiting: another process
/// held the write lock past `busy_timeout`.
enum StateDatabaseError: Error, LocalizedError, Equatable {
    case busy
    case newerSchema(found: Int, supported: Int)
    case unexpectedSchema(found: Int)
    case transactionAborted
    case invalidVectorBlob(byteCount: Int)
    case insecurePath(String)
    case legacyStatePresent(String)
    case sqlite(code: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .busy:
            return "Another transcribe process is writing to the state database; retry when it finishes."
        case .insecurePath(let path):
            return "The state database path \(path) is a symbolic link; refusing to open it."
        case .legacyStatePresent(let path):
            return "Found existing transcribe state at \(path), but this build cannot migrate it yet; refusing to start a separate empty state database."
        case .newerSchema(let found, let supported):
            return "The state database uses schema version \(found), but this transcribe understands up to version \(supported). A newer transcribe is required."
        case .unexpectedSchema(let found):
            return "The state database reports schema version \(found), which this transcribe cannot open."
        case .transactionAborted:
            return "A state database update failed part-way and was rolled back."
        case .invalidVectorBlob(let byteCount):
            return "Stored embedding vector has \(byteCount) bytes, which is not a whole number of float32 values."
        case .sqlite(_, let message):
            return "State database error: \(message)"
        }
    }
}

/// A value bound to a `?` parameter of a prepared statement.
enum SQLValue: Equatable {
    case text(String)
    case integer(Int64)
    case real(Double)
    case blob(Data)
    case null
}

/// Writable counterpart of `ReadOnlyDatabase` for the transcribe state store
/// (`<state>/state.db`). One instance owns one connection opened with
/// `SQLITE_OPEN_NOMUTEX`: callers must never use an instance from two tasks or
/// threads at once. The pipeline is async and hops threads between awaits,
/// which is fine as long as state access stays serialized; inside a
/// transaction the body is synchronous, so the owning thread is asserted.
///
/// Construction runs the initialization guard under `<state>/init.lock` (see
/// `initialize`), so any instance a caller holds has a complete schema.
final class StateDatabase {
    enum TransactionKind {
        case read
        case write
    }

    /// The highest `PRAGMA user_version` this binary understands. Bump it
    /// together with an upgrade step in `initialize`.
    static let schemaVersion = 1

    /// Default `busy_timeout`. Transactions cover row reads and writes only, so
    /// any wait anywhere near this long means something is wrong with the other
    /// writer; failing with `.busy` beats hanging like an unbounded flock.
    static let defaultBusyTimeoutMilliseconds: Int32 = 30_000

    private var handle: OpaquePointer?
    private var transactionDepth = 0
    private var transactionKind: TransactionKind?
    /// Set when a joined (inner) body throws. The inner error may be caught by
    /// an outer body, but its partial writes are already in the shared
    /// transaction; without savepoints the only safe outcome is a rollback.
    private var transactionDoomed = false
    private var transactionThread: pthread_t?

    let databaseURL: URL
    private let busyTimeoutMilliseconds: Int32

    /// Opens the state database in the current state directory, creating or
    /// rebuilding it under the init lock first.
    init(busyTimeoutMilliseconds: Int32 = StateDatabase.defaultBusyTimeoutMilliseconds) throws {
        let stateDirectory = try StatePaths.stateDirectoryURL()
        databaseURL = try StatePaths.stateDatabaseURL()
        self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
        // Same rule as the JSON stores: only a directory this tool creates is
        // tightened; an existing one keeps the permissions the user chose.
        if !FileManager.default.fileExists(atPath: stateDirectory.path) {
            try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            try tightenPermissions(ofPath: stateDirectory.path, to: privateDirectoryMode)
        }
        try Self.withInitLock(at: StatePaths.initLockURL()) {
            try initialize()
        }
    }

    deinit {
        if handle != nil {
            sqlite3_close_v2(handle)
        }
    }

    // MARK: - Initialization

    /// Serializes first-run creation and rebuilds across processes. Without
    /// it, two processes starting together could both see no database and
    /// both create one, or one could delete a database the other is still
    /// populating. Held only during `initialize`.
    private static func withInitLock<T>(at lock: URL, _ body: () throws -> T) throws -> T {
        let fd = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, privateFileMode)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        try tightenPermissions(ofFileDescriptor: fd, at: lock.path, to: privateFileMode)
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    /// Runs under the init lock. Meta markers record how far setup got:
    /// `import_complete` is written in the same transaction as the schema (or,
    /// once migration exists, after the import commits), and
    /// `archive_complete` after legacy files are moved aside. A database that
    /// was created fresh, with no legacy state to import, records both as
    /// `'fresh'` so later phases treat it as fully migrated.
    private func initialize() throws {
        // The open below cannot use SQLITE_OPEN_NOFOLLOW (see openConnection),
        // so refuse a symlinked database name outright: following it would
        // read and write a file outside this state directory, unprotected by
        // this directory's init lock.
        var linkStat = stat()
        if lstat(databaseURL.path, &linkStat) == 0, linkStat.st_mode & S_IFMT == S_IFLNK {
            throw StateDatabaseError.insecurePath(databaseURL.path)
        }
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            // A database copied or restored from a backup can arrive with
            // looser modes; restore 0600 before SQLite creates `-wal` and
            // `-shm` companions that copy the main file's mode.
            for suffix in ["", "-wal", "-shm"] {
                let path = databaseURL.path + suffix
                if FileManager.default.fileExists(atPath: path) {
                    try tightenPermissions(ofPath: path, to: privateFileMode)
                }
            }
            try openConnection()
            let version = try userVersion()
            // Checked before anything is deleted: a newer binary's database is
            // never rebuilt by an older one.
            if version > Self.schemaVersion {
                closeConnection()
                throw StateDatabaseError.newerSchema(found: version, supported: Self.schemaVersion)
            }
            if try metaValue("import_complete") != nil {
                guard version == Self.schemaVersion else {
                    // Upgrade steps from older schema versions go here once a
                    // version 2 exists.
                    closeConnection()
                    throw StateDatabaseError.unexpectedSchema(found: version)
                }
                // StateMigration hook: resume the archive phase when
                // `archive_complete` is absent, then check for reappeared
                // legacy files, all still under the init lock.
                return
            }
            // No import marker: an earlier setup stopped before committing.
            // Legacy sources are only moved after the marker, so starting over
            // loses nothing.
            closeConnection()
            try removeDatabaseFiles()
        }
        // StateMigration hook: when legacy JSON state exists, the import
        // replaces this refusal, and `import_complete` is written only after
        // that import commits; the archive phase then sets `archive_complete`.
        // Until then, creating a fresh database here would set markers that
        // permanently hide the legacy files from the future migration.
        if let legacy = try Self.legacyStatePath() {
            throw StateDatabaseError.legacyStatePresent(legacy)
        }
        try createDatabaseFile()
        try openConnection()
        try inTransaction(.write) {
            try exec(Self.schemaV1)
            try exec("PRAGMA user_version = \(Self.schemaVersion)")
            try setMeta("schema_version", String(Self.schemaVersion))
            try setMeta("created_by", Transcribe.version)
            try setMeta("import_complete", "fresh")
            try setMeta("archive_complete", "fresh")
        }
        // Push the marker out of the WAL so it is in the main file at rest.
        checkpoint()
    }

    /// SQLite creates a missing database file 0644 masked by umask. Creating
    /// it first at 0600 fixes that, and the `-wal` and `-shm` files SQLite
    /// creates later copy the main file's mode.
    private func createDatabaseFile() throws {
        let path = databaseURL.path
        let fd = open(path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, privateFileMode)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        try tightenPermissions(ofFileDescriptor: fd, at: path, to: privateFileMode)
    }

    /// The first legacy JSON state location that still exists, or nil on a
    /// genuinely fresh machine. Used to refuse fresh creation until
    /// StateMigration can import these files. Only stores the database has
    /// already superseded count: the profile store and transcripts directory
    /// are still live JSON stores, and a run legitimately creates them before
    /// its first history append reaches here.
    private static func legacyStatePath() throws -> String? {
        let candidates = [
            try StatePaths.processingHistoryURL().path,
            try StatePaths.timingHistoryURL().path,
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func removeDatabaseFiles() throws {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let path = databaseURL.path + suffix
            if unlink(path) != 0 && errno != ENOENT {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private func openConnection() throws {
        // No SQLITE_OPEN_NOFOLLOW: it rejects a symlink anywhere in the path,
        // and macOS temporary and some home directories sit behind one. The
        // O_NOFOLLOW pre-create guards the file name itself.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
        if status != SQLITE_OK {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "code \(status)"
            closeConnection()
            throw StateDatabaseError.sqlite(code: status, message: "cannot open \(databaseURL.path): \(message)")
        }
        do {
            // busy_timeout first so the pragmas below wait out a concurrent
            // writer instead of failing immediately.
            sqlite3_busy_timeout(handle, busyTimeoutMilliseconds)
            try exec("PRAGMA foreign_keys = ON")
            try exec("PRAGMA journal_mode = WAL")
            // FULL matches the fsync-before-rename durability of
            // `writePrivateAtomically`; NORMAL can lose a committed WAL
            // transaction on OS crash.
            try exec("PRAGMA synchronous = FULL")
        } catch {
            closeConnection()
            throw error
        }
    }

    private func closeConnection() {
        if handle != nil {
            sqlite3_close_v2(handle)
            handle = nil
        }
    }

    private func userVersion() throws -> Int {
        try query("PRAGMA user_version") { Int($0.int(0) ?? 0) }.first ?? 0
    }

    /// Returns nil when the key is absent or the `meta` table itself is
    /// missing (a database interrupted before its schema committed).
    func metaValue(_ key: String) throws -> String? {
        let hasMeta = try query(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'meta'"
        ) { _ in true }.first ?? false
        guard hasMeta else { return nil }
        return try query("SELECT value FROM meta WHERE key = ?", [.text(key)]) { $0.text(0) }.first ?? nil
    }

    func setMeta(_ key: String, _ value: String) throws {
        try execute(
            "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [.text(key), .text(value)]
        )
    }

    // MARK: - Transactions

    /// Runs `body` in a transaction. The outermost call issues `BEGIN DEFERRED`
    /// (`.read`) or `BEGIN IMMEDIATE` (`.write`) and owns commit and rollback;
    /// nested calls join it instead of nesting, so store methods that open
    /// their own transaction compose under a caller's. A throw anywhere rolls
    /// back the whole transaction, including a joined body's throw that an
    /// outer body caught.
    ///
    /// `.write` takes the write lock up front: a deferred transaction that
    /// reads and then writes must upgrade its lock, and in WAL mode that
    /// upgrade fails with `SQLITE_BUSY_SNAPSHOT` when another connection
    /// committed in between, which `busy_timeout` does not retry. The same
    /// reason makes a `.write` joining an active `.read` a programmer error.
    func inTransaction<T>(_ kind: TransactionKind, _ body: () throws -> T) throws -> T {
        if let active = transactionKind {
            assertOwningThread()
            // XCTest cannot catch a trap, so this check has no unit test; it is
            // exercised only by assertion-enabled runs that hit the bug.
            precondition(
                !(active == .read && kind == .write),
                "StateDatabase: a .write transaction cannot join an active .read transaction"
            )
            transactionDepth += 1
            defer { transactionDepth -= 1 }
            do {
                return try body()
            } catch {
                transactionDoomed = true
                throw error
            }
        }

        try execControl(kind == .write ? "BEGIN IMMEDIATE" : "BEGIN DEFERRED")
        transactionKind = kind
        transactionDepth = 1
        transactionDoomed = false
        transactionThread = pthread_self()
        defer {
            transactionKind = nil
            transactionDepth = 0
            transactionDoomed = false
            transactionThread = nil
        }

        let result: T
        do {
            result = try body()
        } catch {
            rollbackIgnoringErrors()
            throw error
        }
        if transactionDoomed {
            rollbackIgnoringErrors()
            throw StateDatabaseError.transactionAborted
        }
        // SQLite rolls some failures back by itself (ON CONFLICT ROLLBACK, a
        // full disk); if that happened and the body swallowed the error,
        // committing here would be a lie — there is no transaction left.
        if let handle, sqlite3_get_autocommit(handle) != 0 {
            throw StateDatabaseError.transactionAborted
        }
        do {
            try execControl("COMMIT")
        } catch {
            rollbackIgnoringErrors()
            throw error
        }
        return result
    }

    var isInTransaction: Bool { transactionKind != nil }

    /// SQLite rolls back by itself after some errors (for example a full
    /// disk); issuing ROLLBACK then would fail and mask the original error.
    private func rollbackIgnoringErrors() {
        guard let handle, sqlite3_get_autocommit(handle) == 0 else { return }
        sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
    }

    private func assertOwningThread() {
        assert(
            transactionThread.map { pthread_equal($0, pthread_self()) != 0 } ?? true,
            "StateDatabase used from a second thread during a transaction"
        )
    }

    // MARK: - Statements

    /// Runs one or more SQL statements without parameters (DDL, pragmas).
    /// Result rows, if any, are discarded.
    func exec(_ sql: String) throws {
        try ensureTransactionStillOpen()
        try execControl(sql)
    }

    /// `exec` without the aborted-transaction check, for the BEGIN/COMMIT
    /// statements `inTransaction` itself issues.
    private func execControl(_ sql: String) throws {
        assertOwningThread()
        var errorPointer: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        let detail = errorPointer.map { String(cString: $0) }
        sqlite3_free(errorPointer)
        if status != SQLITE_OK {
            throw error(status: status, detail: detail)
        }
    }

    /// SQLite rolls back by itself after some failures (ON CONFLICT ROLLBACK,
    /// a full disk). The wrapper's transaction state does not see that happen,
    /// and a later statement would otherwise run in autocommit mode and
    /// commit on its own — outside the transaction the caller thinks it is
    /// in. Refuse it and doom the transaction instead.
    private func ensureTransactionStillOpen() throws {
        guard transactionKind != nil, let handle, sqlite3_get_autocommit(handle) != 0 else { return }
        transactionDoomed = true
        throw StateDatabaseError.transactionAborted
    }

    /// Prepares `sql`, binds `bindings` to its `?` parameters in order, and
    /// steps it to completion, discarding rows.
    func execute(_ sql: String, _ bindings: [SQLValue] = []) throws {
        _ = try query(sql, bindings) { _ in () }
    }

    /// Prepares `sql`, binds `bindings`, steps every row, and returns values
    /// produced by `map`. The statement is finalized regardless of outcome, so
    /// no statement outlives the call and none can hold a read snapshot open
    /// past its transaction.
    func query<T>(_ sql: String, _ bindings: [SQLValue] = [], map: (Statement) throws -> T) throws -> [T] {
        assertOwningThread()
        try ensureTransactionStillOpen()
        var stmt: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard prepareStatus == SQLITE_OK, let stmt else {
            let failure = error(status: prepareStatus, detail: nil)
            sqlite3_finalize(stmt)
            throw failure
        }
        defer { sqlite3_finalize(stmt) }

        for (offset, value) in bindings.enumerated() {
            let status = bind(value, at: Int32(offset + 1), in: stmt)
            if status != SQLITE_OK { throw error(status: status, detail: nil) }
        }

        let statement = Statement(handle: stmt)
        var rows: [T] = []
        while true {
            let stepStatus = sqlite3_step(stmt)
            switch stepStatus {
            case SQLITE_ROW:
                rows.append(try map(statement))
            case SQLITE_DONE:
                return rows
            default:
                throw error(status: stepStatus, detail: nil)
            }
        }
    }

    /// Rowid of the most recent successful INSERT on this connection.
    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    /// Rows changed by the most recent INSERT, UPDATE or DELETE.
    var changes: Int { Int(sqlite3_changes(handle)) }

    private func bind(_ value: SQLValue, at index: Int32, in stmt: OpaquePointer) -> Int32 {
        // SQLITE_TRANSIENT: SQLite copies the bytes before the call returns,
        // so the Swift buffers below need not outlive it.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        switch value {
        case .null:
            return sqlite3_bind_null(stmt, index)
        case .integer(let number):
            return sqlite3_bind_int64(stmt, index, number)
        case .real(let number):
            return sqlite3_bind_double(stmt, index, number)
        case .text(let string):
            // Explicit length keeps an embedded NUL from truncating the text.
            let bytes = Array(string.utf8)
            return bytes.withUnsafeBufferPointer { buffer in
                buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: max(buffer.count, 1)) {
                    sqlite3_bind_text(stmt, index, $0, Int32(buffer.count), transient)
                }
            }
        case .blob(let data):
            // A nil pointer binds NULL, not an empty blob, which a NOT NULL
            // column would reject.
            if data.isEmpty { return sqlite3_bind_zeroblob(stmt, index, 0) }
            return data.withUnsafeBytes {
                sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(data.count), transient)
            }
        }
    }

    private func error(status: Int32, detail: String?) -> StateDatabaseError {
        if status & 0xff == SQLITE_BUSY { return .busy }
        let message = detail ?? handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(status)"
        return .sqlite(code: status, message: message.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Shutdown

    /// Best-effort `wal_checkpoint(TRUNCATE)` so the `-wal` file is empty at
    /// rest, when backups usually run. Another process reading or writing
    /// makes it return `SQLITE_BUSY`; that is expected under concurrency and
    /// ignored, as is any other failure — the WAL stays valid either way.
    func checkpoint() {
        guard handle != nil, transactionKind == nil else { return }
        // TRUNCATE invokes the busy handler while it waits for readers, so
        // with the normal timeout an exiting command would stall behind any
        // other process holding a read snapshot. Give up at once instead.
        sqlite3_busy_timeout(handle, 0)
        defer { sqlite3_busy_timeout(handle, busyTimeoutMilliseconds) }
        _ = sqlite3_wal_checkpoint_v2(handle, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
    }

    /// Clean-exit close: checkpoint, then release the connection. The
    /// instance must not be used afterwards.
    func close() {
        checkpoint()
        closeConnection()
    }

    // MARK: - Schema

    /// Schema version 1, exactly as in specs/sqlite-state-store.md.
    static let schemaV1 = """
        CREATE TABLE meta (
          key   TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );  -- 'schema_version' = '1', 'created_by' = transcribe version,
            -- migration markers (see Migration)

        CREATE TABLE documents (
          id                  TEXT PRIMARY KEY,     -- internal document UUID, lowercased
          evidence_id         TEXT NOT NULL UNIQUE, -- sha256:…
          source_hashes       TEXT NOT NULL,        -- JSON array, sorted unique
          created_at          TEXT NOT NULL,        -- ISO 8601, whole seconds
          model               TEXT NOT NULL,
          transcribe_version  TEXT NOT NULL,
          audio_path          TEXT NOT NULL,
          audio_files         TEXT,                 -- JSON array or NULL
          basename            TEXT NOT NULL,
          source_metadata     TEXT,                 -- JSON object or NULL
          embedding_model_id  TEXT NOT NULL,
          language            TEXT,
          duration_seconds    REAL NOT NULL,
          diarization_enabled INTEGER NOT NULL,
          speakers_detected   INTEGER,
          speaker_strategy    TEXT NOT NULL,
          warnings            TEXT NOT NULL,        -- JSON array
          segment_count       INTEGER NOT NULL,     -- lifted so inspect/review
          segment_speakers    TEXT NOT NULL,        -- never read the payload
          exports_recorded    INTEGER NOT NULL,     -- 0 = today's nil exports
          updated_at          TEXT NOT NULL         -- bumped by EVERY mutation
        );

        -- The heavy payload, separated so metadata queries never touch it.
        CREATE TABLE document_segments (
          document_id TEXT PRIMARY KEY REFERENCES documents(id) ON DELETE CASCADE,
          encoding    TEXT NOT NULL,              -- 'json' initially
          payload     BLOB NOT NULL               -- segments array incl. words
        );

        CREATE TABLE document_embeddings (
          document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
          speaker_id  TEXT NOT NULL,              -- SPEAKER_n
          vector      BLOB NOT NULL,              -- float32 little-endian
          PRIMARY KEY (document_id, speaker_id)
        );

        CREATE TABLE speaker_matches (
          document_id   TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
          speaker_id    TEXT NOT NULL,
          profile_id    TEXT NOT NULL,            -- no FK: name snapshots survive
          name          TEXT NOT NULL,            -- speakers delete, as today
          distance      REAL NOT NULL,
          margin        REAL,
          example_count INTEGER NOT NULL,
          status        TEXT NOT NULL,            -- suggested|automatic|confirmed
          PRIMARY KEY (document_id, speaker_id)
        );

        CREATE TABLE dismissed_speakers (
          document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
          speaker_id  TEXT NOT NULL,
          PRIMARY KEY (document_id, speaker_id)
        );

        CREATE TABLE exports (
          document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
          position    INTEGER NOT NULL,           -- preserves array order
          path        TEXT NOT NULL,
          format      TEXT NOT NULL,
          sha256      TEXT NOT NULL,
          exported_at TEXT NOT NULL,
          PRIMARY KEY (document_id, path)
        );

        CREATE TABLE profiles (
          id   TEXT PRIMARY KEY,
          name TEXT NOT NULL
        );

        CREATE TABLE profile_examples (
          profile_id    TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
          transcript_id TEXT NOT NULL,            -- evidence ID, as today
          speaker_id    TEXT NOT NULL,
          model_id      TEXT NOT NULL,
          vector        BLOB NOT NULL,            -- float32 little-endian
          source_hashes TEXT NOT NULL,            -- JSON array
          PRIMARY KEY (profile_id, transcript_id, speaker_id)
        );
        -- One voice, one person: the current store validates example identity
        -- globally and confirmation MOVES evidence between profiles.
        CREATE UNIQUE INDEX profile_examples_identity
          ON profile_examples(transcript_id, speaker_id);

        CREATE TABLE processing_history (
          rowid        INTEGER PRIMARY KEY,
          completed_at TEXT NOT NULL,             -- the record's own recorded_at
          source_kind  TEXT NOT NULL,             -- names the recording date
          source_id    TEXT NOT NULL,
          record       TEXT NOT NULL              -- VERBATIM JSONL line
        );
        -- Completion and baseline decisions scan newest-first per source.
        CREATE INDEX processing_history_source
          ON processing_history(source_kind, source_id, rowid);

        CREATE TABLE timing_history (
          rowid       INTEGER PRIMARY KEY,
          recorded_at TEXT NOT NULL,
          model       TEXT NOT NULL,
          diarization INTEGER NOT NULL,
          record      TEXT NOT NULL               -- VERBATIM JSONL line
        );
        CREATE INDEX timing_history_key ON timing_history(model, diarization, rowid);

        CREATE TABLE migration_sources (          -- see Migration
          source_path   TEXT PRIMARY KEY,
          status        TEXT NOT NULL,            -- imported|skipped|conflict
          detail        TEXT,                     -- skip/conflict reason
          planned_path  TEXT,                     -- written BEFORE the rename
          archived_path TEXT                      -- confirmed after the rename
        );
        """
}

/// Embedding vectors stored as little-endian float32 blobs. The dimension is
/// implied by the byte count; values round-trip bit for bit. Finiteness and
/// per-model dimension checks stay with the stores that validate vectors.
enum Float32Blob {
    static func encode(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * 4)
        for value in vector {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decode(_ data: Data) throws -> [Float] {
        guard data.count % 4 == 0 else {
            throw StateDatabaseError.invalidVectorBlob(byteCount: data.count)
        }
        var vector: [Float] = []
        vector.reserveCapacity(data.count / 4)
        data.withUnsafeBytes { raw in
            for offset in stride(from: 0, to: raw.count, by: 4) {
                let bits = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                vector.append(Float(bitPattern: UInt32(littleEndian: bits)))
            }
        }
        return vector
    }
}
