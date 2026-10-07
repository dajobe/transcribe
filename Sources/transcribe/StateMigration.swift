import CryptoKit
import Darwin
import Foundation

enum StateMigrationError: Error, LocalizedError, Equatable {
    case invalidProfileStore(path: String, reason: String)
    case unreadableLedger(path: String, reason: String)
    case unreadableTranscriptsDirectory(path: String, reason: String)
    case archiveIncomplete(remaining: Int)

    var errorDescription: String? {
        switch self {
        case .unreadableTranscriptsDirectory(let path, let reason):
            return "Cannot list \(path) to migrate it: \(reason). Nothing was migrated and no file was moved; fix its permissions and run transcribe again."
        case .archiveIncomplete(let remaining):
            return "\(remaining) migrated file\(remaining == 1 ? "" : "s") could not be confirmed as moved"
        case .invalidProfileStore(let path, let reason):
            return "Cannot migrate the speaker profile store at \(path): \(reason). Nothing was migrated and no file was moved; repair the file (or restore it from a backup) and run transcribe again."
        case .unreadableLedger(let path, let reason):
            return "Cannot read \(path) to migrate it: \(reason). Nothing was migrated and no file was moved; fix the file and run transcribe again."
        }
    }
}

/// One `migration_sources` row: what happened to one legacy file.
struct MigrationSourceRow: Equatable {
    /// The legacy file's path; a file recreated after migration at a path
    /// that already has a row gets a `#reappeared-N` suffix, since the
    /// column is the table's key.
    let sourcePath: String
    let status: String
    let detail: String?
    let plannedPath: String?
    let archivedPath: String?

    /// The file system path `sourcePath` names.
    var filePath: String { StateMigration.filePath(ofSourceKey: sourcePath) }

    /// Recreated by an older binary after migration finished.
    var isReappeared: Bool {
        sourcePath != filePath || (detail ?? "").hasPrefix(StateMigration.reappearedPrefix)
    }
}

/// Moves 2.x JSON state (managed `.transcript.json` files, the profile
/// store, and both JSONL ledgers) into the state database, in the phases
/// specs/sqlite-state-store.md describes. Everything here runs under
/// `init.lock`, called from `StateDatabase.initialize`, on a connection the
/// shared `StateStore` does not know about yet — so it uses the stores'
/// explicit-connection entry points, never `StateStore.withDatabase`.
///
/// Phase 1 (`importLegacyState`) runs in the schema-creating transaction:
/// either everything imports and `import_complete` commits with it, or the
/// database is deleted and no source was touched. Phase 2
/// (`completeArchive`) moves imported sources under `migrated-v1/` one at a
/// time with a write-ahead `planned_path`, so it can resume after a crash at
/// any point without losing or double-moving a file.
enum StateMigration {
    static let archiveDirectoryName = "migrated-v1"
    static let manifestFileName = "MANIFEST.tsv"
    static let transcriptSuffix = ".transcript.json"
    static let reappearedPrefix = "reappeared after migration"
    static let reappearedTranscriptDetail = "reappeared after migration; import with transcribe transcripts import"
    static let reappearedProfilesDetail = "reappeared after migration; not merged into the stored profiles"
    private static let reappearedKeyMarker = "#reappeared-"

    struct ImportSummary: Equatable {
        var imported = 0
        var skipped = 0
        var conflicts = 0
    }

    // MARK: - Locations

    static func archiveDirectoryURL() throws -> URL {
        try StatePaths.stateDirectoryURL().appendingPathComponent(archiveDirectoryName, isDirectory: true)
    }

    static func manifestURL() throws -> URL {
        try archiveDirectoryURL().appendingPathComponent(manifestFileName, isDirectory: false)
    }

    /// Whether any 2.x state location exists. Checked before creating a
    /// database: a fresh one would set markers that hide these files.
    static func legacyStateExists() throws -> Bool {
        [
            try StatePaths.processingHistoryURL(),
            try StatePaths.timingHistoryURL(),
            try StatePaths.legacySpeakerProfilesURL(),
            try StatePaths.legacyTranscriptsDirectoryURL(),
        ].contains { pathExists($0.path) }
    }

    static func filePath(ofSourceKey key: String) -> String {
        guard let range = key.range(of: reappearedKeyMarker, options: .backwards),
              !key[range.upperBound...].isEmpty,
              key[range.upperBound...].allSatisfy(\.isNumber) else {
            return key
        }
        return String(key[..<range.lowerBound])
    }

    // MARK: - Phase 1: import

    /// Imports every legacy store into `database`. The caller owns the write
    /// transaction (the one that created the schema) and commits it together
    /// with the `import_complete` marker. Throws, leaving the caller to roll
    /// back and delete the database, when the profile store or a ledger
    /// cannot be read; individual transcripts that cannot be read are
    /// recorded as skipped instead.
    static func importLegacyState(into database: StateDatabase) throws -> ImportSummary {
        var summary = ImportSummary()
        try importTranscripts(into: database, summary: &summary)

        let profiles = try StatePaths.legacySpeakerProfilesURL()
        if pathExists(profiles.path) {
            let count: Int
            let contents: Data
            do {
                contents = try Data(contentsOf: profiles)
                count = try SpeakerProfileStore.importLegacyStore(data: contents, in: database)
            } catch {
                throw StateMigrationError.invalidProfileStore(
                    path: profiles.path, reason: SpeakerCommands.errorText(error)
                )
            }
            try record(
                profiles.path, status: "imported", detail: count == 1 ? "1 profile" : "\(count) profiles",
                sha256: sha256Hex(contents), in: database
            )
            summary.imported += 1
        }

        // The caller holds both ledger locks (`withLedgerLocks`); a ledger
        // this process created only to lock it is not legacy state.
        for ledger in ledgers() {
            let url = try ledger.url()
            guard ledgerPresent(url.path) else { continue }
            let counts = try importLedger(at: url, append: ledger.append, in: database)
            try record(url.path, status: "imported", detail: ledgerDetail(counts), sha256: counts.sha256, in: database)
            summary.imported += 1
        }
        return summary
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct Ledger {
        let url: () throws -> URL
        let append: (String, StateDatabase) throws -> Void
    }

    private static func ledgers() -> [Ledger] {
        [
            Ledger(url: StatePaths.processingHistoryURL, append: { try ProcessingStore.appendVerbatim(line: $0, in: $1) }),
            Ledger(url: StatePaths.timingHistoryURL, append: { try TimingStore.appendVerbatim(line: $0, in: $1) }),
        ]
    }

    /// Identity is the document's internal ID. UUID-named files are visited
    /// first, in path order, then other names: the first file per ID and per
    /// evidence ID wins and the rest are recorded as conflicts, left in place
    /// for the user to inspect and import deliberately.
    private static func importTranscripts(into database: StateDatabase, summary: inout ImportSummary) throws {
        let directory = try StatePaths.legacyTranscriptsDirectoryURL()
        var winnersByID: [String: String] = [:]
        var winnersByEvidence: [String: String] = [:]
        for url in try transcriptFiles(in: directory) {
            let path = url.path
            let loaded: CanonicalTranscript
            let contents: Data
            do {
                contents = try Data(contentsOf: url)
                loaded = try CanonicalTranscriptStore.load(data: contents)
            } catch {
                try record(path, status: "skipped", detail: "unreadable: \(SpeakerCommands.errorText(error))", in: database)
                summary.skipped += 1
                continue
            }
            let key = loaded.id.uuidString.lowercased()
            if let winner = winnersByID[key] {
                try record(path, status: "conflict", detail: "document ID \(key) was already imported from \(winner)", in: database)
                summary.conflicts += 1
                continue
            }
            if let winner = winnersByEvidence[loaded.evidenceID] {
                try record(path, status: "conflict", detail: "same recording (evidence ID) was already imported from \(winner)", in: database)
                summary.conflicts += 1
                continue
            }

            var document = loaded
            var notes: [String] = []
            let stem = String(url.lastPathComponent.dropLast(transcriptSuffix.count))
            if UUID(uuidString: stem) != loaded.id {
                notes.append("filename stem differs from document ID \(key); address it by that ID")
            }
            // Today's validation accepts repeated export paths, but the
            // exports table keys on (document, path); keep the last record
            // per path, the one a refresh would have acted on.
            if let exports = document.exports, Set(exports.map(\.path)).count != exports.count {
                document.exports = exports.enumerated().filter { index, record in
                    !exports[(index + 1)...].contains { $0.path == record.path }
                }.map(\.element)
                notes.append("duplicate export records; kept the last one per path")
            }
            let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
                ?? loaded.createdAt

            // A savepoint keeps one document's unexpected insert failure from
            // leaving half its rows behind or aborting the whole migration.
            try database.exec("SAVEPOINT migrate_document")
            do {
                try CanonicalTranscriptStore.importMigrated(document, updatedAt: modified, in: database)
                try database.exec("RELEASE migrate_document")
            } catch {
                try database.exec("ROLLBACK TO migrate_document")
                try database.exec("RELEASE migrate_document")
                try record(path, status: "skipped", detail: "could not be stored: \(SpeakerCommands.errorText(error))", in: database)
                summary.skipped += 1
                continue
            }
            winnersByID[key] = path
            winnersByEvidence[loaded.evidenceID] = path
            try record(
                path, status: "imported", detail: notes.isEmpty ? nil : notes.joined(separator: "; "),
                sha256: sha256Hex(contents), in: database
            )
            summary.imported += 1
        }
    }

    /// `*.transcript.json` entries of the legacy directory, UUID-named first.
    /// Only a missing directory counts as empty: one that exists but cannot
    /// be listed must stop the migration, or its files would be left behind
    /// unimported and later mistaken for files an older binary recreated.
    static func transcriptFiles(in directory: URL) throws -> [URL] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            let nsError = error as NSError
            let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError
                || underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(ENOENT) {
                return []
            }
            throw StateMigrationError.unreadableTranscriptsDirectory(
                path: directory.path, reason: underlying?.localizedDescription ?? error.localizedDescription
            )
        }
        let candidates = names.filter { $0.hasSuffix(transcriptSuffix) && $0.count > transcriptSuffix.count }
            .map { directory.appendingPathComponent($0, isDirectory: false) }
            .filter { !isDirectory($0.path) }
        func isUUIDNamed(_ url: URL) -> Bool {
            UUID(uuidString: String(url.lastPathComponent.dropLast(transcriptSuffix.count))) != nil
        }
        let byPath: (URL, URL) -> Bool = { $0.path < $1.path }
        return candidates.filter(isUUIDNamed).sorted(by: byPath)
            + candidates.filter { !isUUIDNamed($0) }.sorted(by: byPath)
    }

    struct LedgerCounts: Equatable {
        var rows = 0
        var unreadable = 0
        /// Of the exact bytes read, recorded as the row's `source_sha256`.
        var sha256 = ""
    }

    /// Stores every line that is a JSON object verbatim, including rows with
    /// fields this binary does not know. Torn or undecodable lines are
    /// counted, not imported: the 2.x loaders skipped them too, and their
    /// bytes survive in the archived file.
    private static func importLedger(
        at url: URL, append: (String, StateDatabase) throws -> Void, in database: StateDatabase
    ) throws -> LedgerCounts {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StateMigrationError.unreadableLedger(path: url.path, reason: error.localizedDescription)
        }
        var counts = LedgerCounts()
        counts.sha256 = sha256Hex(data)
        for slice in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let line = String(data: Data(slice), encoding: .utf8) else {
                counts.unreadable += 1
                continue
            }
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            guard (try? JSONSerialization.jsonObject(with: Data(slice))) is [String: Any] else {
                counts.unreadable += 1
                continue
            }
            try append(line, database)
            counts.rows += 1
        }
        return counts
    }

    private static func ledgerDetail(_ counts: LedgerCounts) -> String {
        var detail = counts.rows == 1 ? "1 row" : "\(counts.rows) rows"
        if counts.unreadable > 0 {
            let lines = counts.unreadable == 1 ? "1 unreadable line" : "\(counts.unreadable) unreadable lines"
            detail += "; \(lines) kept only in the archive"
        }
        return detail
    }

    /// Inserts a `migration_sources` row. Callers run inside a write
    /// transaction, which this joins so the dirty-manifest flag commits with
    /// the row.
    private static func record(
        _ sourceKey: String, status: String, detail: String?, plannedPath: String? = nil,
        sha256: String? = nil, in database: StateDatabase
    ) throws {
        try database.execute(
            """
            INSERT INTO migration_sources (source_path, status, detail, planned_path, source_sha256)
            VALUES (?, ?, ?, ?, ?)
            """,
            [.text(sourceKey), .text(status), detail.map { .text($0) } ?? .null,
             plannedPath.map { .text($0) } ?? .null, sha256.map { .text($0) } ?? .null]
        )
        try markManifestDirty(database)
    }

    /// `MANIFEST.tsv` is rewritten after the rows change, outside the
    /// transaction; a crash or write failure in between would leave it stale
    /// forever. The flag commits with every row change and is cleared only
    /// after a successful write, so the next open rewrites a stale manifest.
    static let manifestDirtyKey = "manifest_dirty"

    private static func markManifestDirty(_ database: StateDatabase) throws {
        try database.setMeta(manifestDirtyKey, "1")
    }

    // MARK: - Phase 2: archive

    /// Moves every imported source not yet archived under `migrated-v1/`,
    /// writes `MANIFEST.tsv`, and commits `archive_complete` last. Safe to
    /// rerun after a crash at any point; a row whose move could not be made
    /// durable leaves the marker unset so the next open retries it.
    static func completeArchive(_ database: StateDatabase) throws {
        try archivePending(database)
        try removeTranscriptsDirectoryIfDone(database)
        try writeManifest(database)
        let remaining = try pendingArchiveRows(database).count
        guard remaining == 0 else { throw StateMigrationError.archiveIncomplete(remaining: remaining) }
        try database.inTransaction(.write) {
            try database.setMeta("archive_complete", "migrated")
        }
        database.checkpoint()
    }

    private struct PendingArchive {
        let key: String
        let planned: String?
        let sha256: String?
    }

    private static func pendingArchiveRows(_ database: StateDatabase) throws -> [PendingArchive] {
        try database.query(
            """
            SELECT source_path, planned_path, source_sha256 FROM migration_sources
            WHERE status = 'imported' AND archived_path IS NULL ORDER BY rowid
            """
        ) { PendingArchive(key: $0.text(0) ?? "", planned: $0.text(1), sha256: $0.text(2)) }
    }

    /// Flushes a directory entry; false when the directory cannot be opened
    /// or fsync fails. A seam so tests can observe and fail it.
    static var syncDirectory: (String) -> Bool = { path in
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        return fsync(fd) == 0
    }

    /// Archives each `imported` row whose `archived_path` is unset. Per row:
    /// commit `planned_path`, rename, fsync both directories, commit
    /// `archived_path`, then delete the source's `.lock` sidecar.
    ///
    /// On resume, a file at the planned destination is the completed move
    /// only when its bytes hash to the row's `source_sha256`; then whatever
    /// the source path holds was recreated afterwards (rename is atomic) and
    /// is left for `checkReappeared`, never archived unread. A different file
    /// there is someone else's: it is left alone and the source, if still
    /// present, moves to a fresh destination instead.
    /// Returns whether any row changed.
    @discardableResult
    static func archivePending(_ database: StateDatabase) throws -> Bool {
        let pending = try pendingArchiveRows(database)
        guard !pending.isEmpty else { return false }
        try ensurePrivateDirectory(try archiveDirectoryURL())

        for row in pending {
            let source = filePath(ofSourceKey: row.key)
            var destination = row.planned
            if let planned = destination, pathExists(planned), !fileMatches(planned, sha256: row.sha256) {
                guard pathExists(source) else {
                    try recordNothingMoved(
                        row.key, note: "\(planned) holds a different file and the source was gone, so nothing was archived",
                        in: database
                    )
                    continue
                }
                destination = nil
            }
            if destination == nil {
                let chosen = try planDestination(for: source, in: database)
                try database.inTransaction(.write) {
                    try database.execute(
                        "UPDATE migration_sources SET planned_path = ? WHERE source_path = ?",
                        [.text(chosen), .text(row.key)]
                    )
                    try markManifestDirty(database)
                }
                destination = chosen
            }
            guard let destination else { continue }
            if !pathExists(destination) {
                guard pathExists(source) else {
                    // Neither file exists: the source vanished after import.
                    // The rows are in the database; record that nothing was
                    // moved so the archive phase can finish.
                    try recordNothingMoved(row.key, note: "source was gone before it could be archived", in: database)
                    continue
                }
                try ensurePrivateDirectory(URL(fileURLWithPath: destination).deletingLastPathComponent())
                try withLedgerLock(ifLedger: source) {
                    guard Darwin.rename(source, destination) == 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                }
            }
            // The rename must be on disk before the database says it
            // happened. If either directory cannot be flushed, leave the row
            // unrecorded: the next open finds the destination and retries.
            // A source directory that is already gone (removed after an
            // earlier, unconfirmed move) is flushed through its surviving
            // parent, whose entry for it changed.
            let directories = [(destination as NSString).deletingLastPathComponent,
                               nearestExistingDirectory(of: source)]
            guard directories.map({ syncDirectory($0) }).allSatisfy({ $0 }) else { continue }
            try database.inTransaction(.write) {
                try database.execute(
                    "UPDATE migration_sources SET archived_path = ? WHERE source_path = ?",
                    [.text(destination), .text(row.key)]
                )
                try markManifestDirty(database)
            }
            // Best effort: a leftover sidecar is harmless once the move is
            // recorded, and most sources (the ledgers) never had one.
            _ = unlink(source + ".lock")
        }
        return true
    }

    private static func recordNothingMoved(_ key: String, note: String, in database: StateDatabase) throws {
        try database.inTransaction(.write) {
            try database.execute(
                """
                UPDATE migration_sources SET archived_path = '',
                  detail = CASE WHEN detail IS NULL THEN ? ELSE detail || '; ' || ? END
                WHERE source_path = ?
                """,
                [.text(note), .text(note), .text(key)]
            )
            try markManifestDirty(database)
        }
    }

    /// Whether `path` holds the bytes migration imported. A row without a
    /// recorded hash cannot be checked and is trusted.
    private static func fileMatches(_ path: String, sha256: String?) -> Bool {
        guard let sha256 else { return true }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return false }
        return sha256Hex(data) == sha256
    }

    /// The parent directory of `path`, or its nearest existing ancestor.
    private static func nearestExistingDirectory(of path: String) -> String {
        var directory = (path as NSString).deletingLastPathComponent
        while !pathExists(directory), directory != "/", !directory.isEmpty {
            directory = (directory as NSString).deletingLastPathComponent
        }
        return directory
    }

    // MARK: - Ledger locks

    /// Ledger locks this process holds, by path. flock locks belong to an
    /// open file description, so a second open-and-lock of the same file in
    /// this process would deadlock on the first; nested users reuse it.
    private static var heldLedgerLocks: [String: Int32] = [:]
    /// Ledger paths this process created only to hold their lock.
    private static var createdLedgerPaths: Set<String> = []

    /// Holds the exclusive flock a 2.x `LockedAppendWriter` takes on the
    /// ledger file for each append, across read, import and rename, so no
    /// append can land between the read and the move, and no half-written
    /// line is read.
    ///
    /// With `create`, a missing ledger is created (as the legacy writer's
    /// own O_CREAT open would) and locked too, so a writer that appears
    /// mid-migration queues behind this process instead of writing a file
    /// the import never reads. Such a file holds nothing while the lock is
    /// held, counts as absent (`ledgerPresent`), and is removed on release
    /// if still empty.
    ///
    /// Residual window, accepted and covered by the release notes' "stop
    /// every transcribe process" instruction: an older binary that opened
    /// the file before the rename (or unlink) and is blocked on this lock
    /// writes to the moved or removed file once the lock is released.
    static func withLedgerLock<T>(_ path: String, create: Bool = false, _ body: () throws -> T) throws -> T {
        if heldLedgerLocks[path] != nil { return try body() }
        var created = false
        var fd = open(path, O_RDWR | O_NOFOLLOW)
        if fd < 0 && errno == ENOENT {
            guard create else { return try body() }
            fd = open(path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, privateFileMode)
            created = fd >= 0
            if fd < 0 && errno == EEXIST { fd = open(path, O_RDWR | O_NOFOLLOW) }
        }
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        heldLedgerLocks[path] = fd
        if created { createdLedgerPaths.insert(path) }
        defer {
            if created {
                createdLedgerPaths.remove(path)
                // Still empty and still this file: nothing was written, so
                // remove it before anyone else gets the lock.
                var held = stat()
                var named = stat()
                if fstat(fd, &held) == 0, held.st_size == 0, lstat(path, &named) == 0,
                   named.st_ino == held.st_ino, named.st_dev == held.st_dev {
                    _ = unlink(path)
                }
            }
            heldLedgerLocks[path] = nil
            _ = flock(fd, LOCK_UN)
        }
        return try body()
    }

    /// Whether a ledger file is legacy state to import: it exists and is not
    /// an empty placeholder this process created to hold its lock.
    static func ledgerPresent(_ path: String) -> Bool {
        guard pathExists(path) else { return false }
        guard createdLedgerPaths.contains(path) else { return true }
        var info = stat()
        return lstat(path, &info) == 0 && info.st_size > 0
    }

    private static func withLedgerLock<T>(ifLedger path: String, _ body: () throws -> T) throws -> T {
        let ledgerPaths = try ledgers().map { try $0.url().path }
        guard ledgerPaths.contains(path) else { return try body() }
        return try withLedgerLock(path, body)
    }

    /// Locks both canonical ledger paths, creating either if missing, always
    /// in the same order. Taken before any import transaction begins, never
    /// inside one, and held until the ledgers have been moved.
    static func withLedgerLocks<T>(_ body: () throws -> T) throws -> T {
        let paths = try ledgers().map { try $0.url().path }
        func lock(_ index: Int) throws -> T {
            guard index < paths.count else { return try body() }
            return try withLedgerLock(paths[index], create: true) { try lock(index + 1) }
        }
        return try lock(0)
    }


    /// The layout-preserving destination under `migrated-v1/`, with a
    /// numeric suffix when a file or another row's plan already claims it.
    private static func planDestination(for source: String, in database: StateDatabase) throws -> String {
        let state = try StatePaths.stateDirectoryURL().path
        let relative = source.hasPrefix(state + "/")
            ? String(source.dropFirst(state.count + 1))
            : (source as NSString).lastPathComponent
        let base = try archiveDirectoryURL().appendingPathComponent(relative, isDirectory: false).path
        let claimed = Set(try database.query(
            "SELECT planned_path FROM migration_sources WHERE planned_path IS NOT NULL"
        ) { $0.text(0) ?? "" })
        if !pathExists(base) && !claimed.contains(base) { return base }

        let directory = (base as NSString).deletingLastPathComponent
        let name = (base as NSString).lastPathComponent
        let stem: String
        let suffix: String
        if name.hasSuffix(transcriptSuffix), name.count > transcriptSuffix.count {
            stem = String(name.dropLast(transcriptSuffix.count))
            suffix = transcriptSuffix
        } else if !(name as NSString).pathExtension.isEmpty {
            stem = (name as NSString).deletingPathExtension
            suffix = "." + (name as NSString).pathExtension
        } else {
            stem = name
            suffix = ""
        }
        var counter = 2
        while true {
            let candidate = (directory as NSString).appendingPathComponent("\(stem).\(counter)\(suffix)")
            if !pathExists(candidate) && !claimed.contains(candidate) { return candidate }
            counter += 1
        }
    }

    /// Lock sidecars of files left in place keep the directory; an emptied
    /// one is removed so later startups have nothing to stat — but only once
    /// every move out of it is recorded, since an unconfirmed move still
    /// needs its source directory flushed on retry.
    private static func removeTranscriptsDirectoryIfDone(_ database: StateDatabase) throws {
        let directory = try StatePaths.legacyTranscriptsDirectoryURL().path
        let unconfirmed = try pendingArchiveRows(database).contains {
            (filePath(ofSourceKey: $0.key) as NSString).deletingLastPathComponent == directory
        }
        guard !unconfirmed else { return }
        _ = rmdir(directory)
    }

    // MARK: - Later imports

    /// Status of a skipped or conflicting transcript file that
    /// `transcripts import` stored afterwards. The file stays where it was:
    /// unlike `imported`, the row is never archived, and with no
    /// `archived_path` it still counts as left in place, so the file is not
    /// reported as reappeared.
    static let importedLaterStatus = "imported-later"

    /// Marks the skipped or conflict rows whose path still names the file
    /// import read (`identity`, taken from the descriptor it read through,
    /// so any spelling of the path matches but a file swapped in since does
    /// not) as imported later, keeping the original reason in the detail.
    /// Joins the caller's write transaction; the caller rewrites
    /// `MANIFEST.tsv` after commit. Returns the number of rows updated.
    @discardableResult
    static func recordLaterImport(ofFileWithIdentity identity: FileID, as id: UUID, in database: StateDatabase) throws -> Int {
        let rows = try manifestRows(in: database).filter {
            ($0.status == "skipped" || $0.status == "conflict") && $0.archivedPath == nil
                && fileIdentity($0.filePath) == identity.text
        }
        let note = "imported later as \(id.uuidString.lowercased()) with transcribe transcripts import; the file was left in place"
        try database.inTransaction(.write) {
            for row in rows {
                let detail = (row.detail ?? "").isEmpty ? note : "\(row.detail!); \(note)"
                try database.execute(
                    "UPDATE migration_sources SET status = ?, detail = ? WHERE source_path = ?",
                    [.text(importedLaterStatus), .text(detail), .text(row.sourcePath)]
                )
            }
            if !rows.isEmpty { try markManifestDirty(database) }
        }
        return rows.count
    }

    // MARK: - Manifest

    static func manifestRows(in database: StateDatabase) throws -> [MigrationSourceRow] {
        try database.query(
            "SELECT source_path, status, detail, planned_path, archived_path FROM migration_sources ORDER BY rowid"
        ) { row in
            MigrationSourceRow(
                sourcePath: row.text(0) ?? "", status: row.text(1) ?? "", detail: row.text(2),
                plannedPath: row.text(3), archivedPath: row.text(4)
            )
        }
    }

    /// Writes `migrated-v1/MANIFEST.tsv`, a plain-text copy of
    /// `migration_sources`, so restoring the snapshot never depends on
    /// reading the database. Tabs, newlines and backslashes in a field are
    /// written as `\t`, `\n`, `\r` and `\\`.
    static func writeManifest(_ database: StateDatabase) throws {
        let rows = try manifestRows(in: database)
        var text = "source_path\tstatus\tarchived_path\tdetail\n"
        for row in rows {
            let fields = [row.sourcePath, row.status, row.archivedPath ?? "", row.detail ?? ""]
            text += fields.map(escapeManifestField).joined(separator: "\t") + "\n"
        }
        let archive = try archiveDirectoryURL()
        try ensurePrivateDirectory(archive)
        try writePrivateAtomically(data: Data(text.utf8), to: try manifestURL())
        // writePrivateAtomically's own directory flush is best effort; the
        // flag clears only once the new entry is known to be on disk.
        guard syncDirectory(archive.path) else { return }
        try database.inTransaction(.write) {
            try database.execute("DELETE FROM meta WHERE key = ?", [.text(manifestDirtyKey)])
        }
    }

    private static func escapeManifestField(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    // MARK: - Reappeared legacy files

    /// Runs on every open of a fully migrated (or fresh) database. An older
    /// binary still running across the upgrade recreates legacy files with
    /// O_CREAT; ignoring them would silently split state. Ledger files are
    /// imported verbatim (they hold only rows written since the originals
    /// were archived) and archived; transcript files are recorded for
    /// `transcripts import`; a profile store is never merged automatically.
    static func checkReappeared(_ database: StateDatabase) throws {
        // Registered first, so a failure anywhere below — even in finishing
        // pending moves — cannot skip repairing a stale manifest. Rows
        // committed by an earlier run whose manifest write never happened are
        // caught here too. Best effort: the flag stays set on failure and the
        // next open tries again.
        defer {
            if (try? database.metaValue(manifestDirtyKey)) != nil {
                try? writeManifest(database)
            }
        }
        // Finish any reappeared ledger whose move was interrupted first, so
        // its file is not mistaken for a new reappearance and imported twice.
        try archivePending(database)

        let profiles = try StatePaths.legacySpeakerProfilesURL()
        let transcriptsDirectory = try StatePaths.legacyTranscriptsDirectoryURL()
        let anyLedger = try ledgers().contains { pathExists(try $0.url().path) }
        let transcripts = pathExists(transcriptsDirectory.path) ? try transcriptFiles(in: transcriptsDirectory) : []
        let profilesPresent = pathExists(profiles.path)
        guard anyLedger || !transcripts.isEmpty || profilesPresent else { return }

        let rows = try manifestRows(in: database)
        // A file at a path with an unarchived row is one migration already
        // left in place (skipped, conflict, or recorded as reappeared).
        let leftInPlace = Set(rows.filter { $0.archivedPath == nil }.map(\.filePath))
        var keys = Set(rows.map(\.sourcePath))

        if anyLedger {
            // Both ledger locks, taken before any import transaction and
            // held through the renames, exactly as for the first migration;
            // presence is decided only under them.
            let imported = try withLedgerLocks { () -> [(URL, LedgerCounts)] in
                var imported: [(URL, LedgerCounts)] = []
                for ledger in ledgers() {
                    let url = try ledger.url()
                    guard ledgerPresent(url.path), !leftInPlace.contains(url.path) else { continue }
                    let key = nextSourceKey(for: url.path, existing: keys)
                    keys.insert(key)
                    let counts = try database.inTransaction(.write) { () -> LedgerCounts in
                        let counts = try importLedger(at: url, append: ledger.append, in: database)
                        let planned = try planDestination(for: url.path, in: database)
                        try record(
                            key, status: "imported", detail: "\(reappearedPrefix); \(ledgerDetail(counts))",
                            plannedPath: planned, sha256: counts.sha256, in: database
                        )
                        return counts
                    }
                    imported.append((url, counts))
                }
                try archivePending(database)
                return imported
            }
            let archive = try archiveDirectoryURL().path
            for (url, counts) in imported {
                emitWarning(
                    "\(url.path) was recreated by an older transcribe after the state moved to \(database.databaseURL.path); imported its \(ledgerDetail(counts)) and moved it under \(archive)/."
                )
            }
        }


        for url in transcripts where !leftInPlace.contains(url.path) {
            let key = nextSourceKey(for: url.path, existing: keys)
            keys.insert(key)
            try database.inTransaction(.write) {
                try record(key, status: "skipped", detail: reappearedTranscriptDetail, in: database)
            }
            emitWarning(
                "\(url.path) was written by an older transcribe after the state moved to \(database.databaseURL.path) and was not imported. Import it with transcribe transcripts import \(url.path); transcribe transcripts migration-status lists such files."
            )
        }

        if profilesPresent {
            if !leftInPlace.contains(profiles.path) {
                let key = nextSourceKey(for: profiles.path, existing: keys)
                try database.inTransaction(.write) {
                    try record(key, status: "skipped", detail: reappearedProfilesDetail, in: database)
                }
            }
            // Repeated on every run while the file exists: confirmations
            // recorded there are invisible to this binary until a person
            // reconciles the two stores.
            emitWarning(
                "SPEAKER PROFILES NOT MERGED: \(profiles.path) was recreated by an older transcribe after speaker profiles moved to \(database.databaseURL.path). This transcribe ignores it. Re-confirm any speakers confirmed there with transcribe speakers confirm, then move the file aside."
            )
        }
    }

    private static func nextSourceKey(for path: String, existing: Set<String>) -> String {
        guard existing.contains(path) else { return path }
        var counter = 1
        while existing.contains("\(path)\(reappearedKeyMarker)\(counter)") { counter += 1 }
        return "\(path)\(reappearedKeyMarker)\(counter)"
    }

    // MARK: - File helpers

    /// lstat-based: a dangling symlink still occupies the name.
    private static func pathExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// Creates `url` (and missing parents) owner-only; it holds voice
    /// embeddings. An existing directory is tightened too, since only this
    /// tool creates `migrated-v1/`.
    private static func ensurePrivateDirectory(_ url: URL) throws {
        if !pathExists(url.path) {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: privateDirectoryMode)]
            )
        }
        try tightenPermissions(ofPath: url.path, to: privateDirectoryMode)
    }
}
