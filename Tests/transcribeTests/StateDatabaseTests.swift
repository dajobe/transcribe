import Foundation
import SQLite3
import XCTest
@testable import transcribe

final class StateDatabaseTests: XCTestCase {
    private var directory: URL!
    private var previousState: String?

    override func setUpWithError() throws {
        previousState = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("state-database-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("XDG_STATE_HOME", directory.path, 1)
    }

    override func tearDownWithError() throws {
        if let previousState { setenv("XDG_STATE_HOME", previousState, 1) }
        else { unsetenv("XDG_STATE_HOME") }
        try? FileManager.default.removeItem(at: directory)
    }

    private struct Marker: Error {}

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func profileNames(_ database: StateDatabase) throws -> [String] {
        try database.query("SELECT name FROM profiles ORDER BY name") { $0.text(0) ?? "" }
    }

    // MARK: - Opening and schema

    func testFreshOpenCreatesSchemaVersionAndMarkers() throws {
        let database = try StateDatabase()
        XCTAssertEqual(try database.query("PRAGMA user_version") { $0.int(0) }, [1])
        XCTAssertEqual(try database.metaValue("schema_version"), "1")
        XCTAssertEqual(try database.metaValue("created_by"), Transcribe.version)
        XCTAssertEqual(try database.metaValue("import_complete"), "fresh")
        XCTAssertEqual(try database.metaValue("archive_complete"), "fresh")
        XCTAssertEqual(try database.query("PRAGMA journal_mode") { $0.text(0) }, ["wal"])
        XCTAssertEqual(try database.query("PRAGMA foreign_keys") { $0.int(0) }, [1])
        XCTAssertEqual(try database.query("PRAGMA synchronous") { $0.int(0) }, [2])

        let tables = try database.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
        ) { $0.text(0) ?? "" }
        XCTAssertEqual(tables, [
            "dismissed_speakers", "document_embeddings", "document_segments", "documents",
            "exports", "meta", "migration_sources", "processing_history", "profile_examples",
            "profiles", "speaker_matches", "timing_history",
        ])
        let indexes = try database.query(
            "SELECT name FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%' ORDER BY name"
        ) { $0.text(0) ?? "" }
        XCTAssertEqual(indexes, ["processing_history_source", "profile_examples_identity", "timing_history_key"])
    }

    func testFilesAreOwnerOnly() throws {
        let database = try StateDatabase()
        try database.inTransaction(.write) {
            try database.execute("INSERT INTO profiles (id, name) VALUES ('p1', 'Ada')")
        }
        XCTAssertEqual(try mode(of: StatePaths.stateDirectoryURL()), 0o700)
        XCTAssertEqual(try mode(of: StatePaths.stateDatabaseURL()), 0o600)
        XCTAssertEqual(try mode(of: StatePaths.initLockURL()), 0o600)
        // The connection is still open, so the WAL companions exist.
        let databasePath = try StatePaths.stateDatabaseURL().path
        for suffix in ["-wal", "-shm"] {
            XCTAssertEqual(try mode(of: URL(fileURLWithPath: databasePath + suffix)), 0o600, suffix)
        }
    }

    func testStatePathHelpers() throws {
        let state = try StatePaths.stateDirectoryURL()
        XCTAssertEqual(try StatePaths.stateDatabaseURL(), state.appendingPathComponent("state.db"))
        XCTAssertEqual(try StatePaths.initLockURL(), state.appendingPathComponent("init.lock"))
        XCTAssertEqual(try StatePaths.locksDirectoryURL().lastPathComponent, "locks")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try StatePaths.locksDirectoryURL().path))
    }

    func testNewerSchemaVersionIsRefusedAndKept() throws {
        do {
            let database = try StateDatabase()
            try database.exec("PRAGMA user_version = 99")
            database.close()
        }
        XCTAssertThrowsError(try StateDatabase()) { error in
            XCTAssertEqual(error as? StateDatabaseError, .newerSchema(found: 99, supported: 1))
            XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("newer transcribe is required") ?? false)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: try StatePaths.stateDatabaseURL().path))
    }

    func testDatabaseWithoutImportMarkerIsRebuilt() throws {
        do {
            let database = try StateDatabase()
            try database.inTransaction(.write) {
                try database.execute("INSERT INTO profiles (id, name) VALUES ('p1', 'Ada')")
                try database.execute("DELETE FROM meta WHERE key = 'import_complete'")
            }
            database.close()
        }
        let reopened = try StateDatabase()
        XCTAssertEqual(try reopened.metaValue("import_complete"), "fresh")
        XCTAssertEqual(try profileNames(reopened), [])
    }

    func testDatabaseWithoutMetaTableIsRebuilt() throws {
        // A crash after the file was pre-created but before the schema
        // committed leaves an empty file behind.
        let state = try StatePaths.stateDirectoryURL()
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: try StatePaths.stateDatabaseURL().path, contents: Data()))
        let database = try StateDatabase()
        XCTAssertEqual(try database.metaValue("import_complete"), "fresh")
    }

    func testSequentialInstancesShareData() throws {
        do {
            let first = try StateDatabase()
            try first.inTransaction(.write) {
                try first.execute("INSERT INTO profiles (id, name) VALUES (?, ?)", [.text("p1"), .text("Ada")])
            }
            first.close()
        }
        let second = try StateDatabase()
        XCTAssertEqual(try profileNames(second), ["Ada"])
        XCTAssertEqual(try second.metaValue("import_complete"), "fresh")
    }

    // MARK: - Transactions

    func testTransactionCommits() throws {
        let database = try StateDatabase()
        let value = try database.inTransaction(.write) { () -> Int in
            try database.execute("INSERT INTO profiles (id, name) VALUES ('p1', 'Ada')")
            return 7
        }
        XCTAssertEqual(value, 7)
        XCTAssertFalse(database.isInTransaction)
        XCTAssertEqual(try profileNames(database), ["Ada"])
    }

    func testTransactionRollsBackOnThrow() throws {
        let database = try StateDatabase()
        XCTAssertThrowsError(try database.inTransaction(.write) {
            try database.execute("INSERT INTO profiles (id, name) VALUES ('p1', 'Ada')")
            throw Marker()
        }) { XCTAssertTrue($0 is Marker) }
        XCTAssertFalse(database.isInTransaction)
        XCTAssertEqual(try profileNames(database), [])
    }

    func testNestedWriteJoinsAndInnerThrowRollsBackEverything() throws {
        let database = try StateDatabase()
        XCTAssertThrowsError(try database.inTransaction(.write) {
            try database.execute("INSERT INTO profiles (id, name) VALUES ('p1', 'Ada')")
            try database.inTransaction(.write) {
                // A second BEGIN would fail here; joining does not issue one.
                try database.execute("INSERT INTO profiles (id, name) VALUES ('p2', 'Grace')")
                throw Marker()
            }
        }) { XCTAssertTrue($0 is Marker) }
        XCTAssertEqual(try profileNames(database), [])

        try database.inTransaction(.write) {
            try database.execute("INSERT INTO profiles (id, name) VALUES ('p1', 'Ada')")
            try database.inTransaction(.write) {
                try database.execute("INSERT INTO profiles (id, name) VALUES ('p2', 'Grace')")
            }
        }
        XCTAssertEqual(try profileNames(database), ["Ada", "Grace"])
    }

    func testCaughtInnerThrowStillRollsBack() throws {
        let database = try StateDatabase()
        XCTAssertThrowsError(try database.inTransaction(.write) {
            try database.execute("INSERT INTO profiles (id, name) VALUES ('p1', 'Ada')")
            do {
                try database.inTransaction(.write) {
                    try database.execute("INSERT INTO profiles (id, name) VALUES ('p2', 'Grace')")
                    throw Marker()
                }
            } catch is Marker {}
        }) { XCTAssertEqual($0 as? StateDatabaseError, .transactionAborted) }
        XCTAssertEqual(try profileNames(database), [])
    }

    func testReadJoinsRead() throws {
        let database = try StateDatabase()
        try database.inTransaction(.write) {
            try database.execute("INSERT INTO profiles (id, name) VALUES ('p1', 'Ada')")
        }
        let names = try database.inTransaction(.read) {
            try database.inTransaction(.read) { try profileNames(database) }
        }
        XCTAssertEqual(names, ["Ada"])
        // A read joining a write is allowed; only the reverse is refused.
        try database.inTransaction(.write) {
            XCTAssertEqual(try database.inTransaction(.read) { try profileNames(database) }, ["Ada"])
        }
    }

    func testForeignKeysAreEnforced() throws {
        let database = try StateDatabase()
        XCTAssertThrowsError(try database.inTransaction(.write) {
            try database.execute(
                "INSERT INTO profile_examples (profile_id, transcript_id, speaker_id, model_id, vector, source_hashes) VALUES ('missing', 't', 's', 'm', ?, '[]')",
                [.blob(Data())]
            )
        })
    }

    // MARK: - Statements

    func testBindingsRoundTrip() throws {
        let database = try StateDatabase()
        try database.exec("CREATE TEMP TABLE sample (t TEXT, i INTEGER, r REAL, b BLOB, n TEXT)")
        let blob = Data([0, 1, 2, 255])
        try database.execute(
            "INSERT INTO sample VALUES (?, ?, ?, ?, ?)",
            [.text("caf\u{e9}\u{0}x"), .integer(Int64.max), .real(-0.125), .blob(blob), .null]
        )
        XCTAssertEqual(database.lastInsertRowID, 1)
        XCTAssertEqual(database.changes, 1)
        let rows = try database.query("SELECT length(CAST(t AS BLOB)), i, r, b, n FROM sample") {
            [$0.int(0) as Any, $0.int(1) as Any, $0.double(2) as Any, $0.blob(3) as Any, $0.isNull(4)]
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0][0] as? Int64, 7)
        XCTAssertEqual(rows[0][1] as? Int64, Int64.max)
        XCTAssertEqual(rows[0][2] as? Double, -0.125)
        XCTAssertEqual(rows[0][3] as? Data, blob)
        XCTAssertEqual(rows[0][4] as? Bool, true)

        try database.execute("INSERT INTO sample (b) VALUES (?)", [.blob(Data())])
        XCTAssertEqual(try database.query("SELECT b IS NULL, length(b) FROM sample WHERE rowid = 2") {
            [$0.int(0), $0.int(1)]
        }, [[0, 0]])
    }

    func testSQLErrorsCarrySQLiteMessage() throws {
        let database = try StateDatabase()
        XCTAssertThrowsError(try database.execute("SELECT * FROM no_such_table")) { error in
            guard case .sqlite(_, let message)? = error as? StateDatabaseError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertTrue(message.contains("no_such_table"), message)
        }
    }

    func testBusyWriterSurfacesTypedError() throws {
        let holder = try StateDatabase()
        let waiter = try StateDatabase(busyTimeoutMilliseconds: 50)
        try holder.inTransaction(.write) {
            try holder.execute("INSERT INTO profiles (id, name) VALUES ('p1', 'Ada')")
            XCTAssertThrowsError(try waiter.inTransaction(.write) {
                try waiter.execute("INSERT INTO profiles (id, name) VALUES ('p2', 'Grace')")
            }) { error in
                XCTAssertEqual(error as? StateDatabaseError, .busy)
                XCTAssertTrue(
                    (error as? LocalizedError)?.errorDescription?.contains("Another transcribe process is writing") ?? false
                )
            }
            XCTAssertFalse(waiter.isInTransaction)
            // WAL readers see the last committed state while a writer holds
            // its transaction open.
            XCTAssertEqual(try waiter.inTransaction(.read) { try profileNames(waiter) }, [])
        }
        try waiter.inTransaction(.write) {
            try waiter.execute("INSERT INTO profiles (id, name) VALUES ('p2', 'Grace')")
        }
        XCTAssertEqual(try profileNames(holder), ["Ada", "Grace"])
    }

    func testCheckpointTruncatesWALAndToleratesReaders() throws {
        let database = try StateDatabase()
        try database.inTransaction(.write) {
            try database.execute("INSERT INTO profiles (id, name) VALUES ('p1', 'Ada')")
        }
        let reader = try StateDatabase()
        // A reader holding a snapshot makes TRUNCATE return SQLITE_BUSY; the
        // checkpoint must swallow that rather than throw, trap, or wait out
        // the 30 s busy timeout.
        try reader.inTransaction(.read) {
            _ = try profileNames(reader)
            let started = Date()
            database.checkpoint()
            XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        }
        reader.close()
        database.checkpoint()
        let wal = try StatePaths.stateDatabaseURL().path + "-wal"
        let size = (try FileManager.default.attributesOfItem(atPath: wal)[.size] as? NSNumber)?.intValue
        XCTAssertEqual(size, 0)
    }

    // MARK: - Float32 blobs

    func testFloat32BlobRoundTripIsExact() throws {
        let vectors: [[Float]] = [
            [],
            [0],
            [-0.0],
            [1, -1, 0.1, -0.333_333_34, 3.402_823_5e38, -3.402_823_5e38],
            [Float.leastNonzeroMagnitude, -Float.leastNormalMagnitude, Float.ulpOfOne, 1 + Float.ulpOfOne],
            (0..<256).map { Float($0) * 0.017 - 2.1 },
        ]
        for vector in vectors {
            let data = Float32Blob.encode(vector)
            XCTAssertEqual(data.count, vector.count * 4)
            let decoded = try Float32Blob.decode(data)
            XCTAssertEqual(decoded.map(\.bitPattern), vector.map(\.bitPattern))
        }
    }

    func testFloat32BlobIsLittleEndian() throws {
        XCTAssertEqual(Float32Blob.encode([1.0]), Data([0x00, 0x00, 0x80, 0x3F]))
        XCTAssertEqual(try Float32Blob.decode(Data([0x00, 0x00, 0x80, 0x3F])), [1.0])
    }

    func testFloat32BlobRejectsPartialValues() {
        XCTAssertThrowsError(try Float32Blob.decode(Data([1, 2, 3]))) {
            XCTAssertEqual($0 as? StateDatabaseError, .invalidVectorBlob(byteCount: 3))
        }
    }

    func testFloat32BlobRoundTripsThroughDatabase() throws {
        let database = try StateDatabase()
        let vector: [Float] = [0.1, -2.5, 1e-7, 123_456.78]
        try database.inTransaction(.write) {
            try database.execute("INSERT INTO profiles (id, name) VALUES ('p1', 'Ada')")
            try database.execute(
                "INSERT INTO profile_examples (profile_id, transcript_id, speaker_id, model_id, vector, source_hashes) VALUES ('p1', 't', 'SPEAKER_0', 'm', ?, '[]')",
                [.blob(Float32Blob.encode(vector))]
            )
        }
        let stored = try database.query("SELECT vector FROM profile_examples") { $0.blob(0) ?? Data() }
        XCTAssertEqual(try stored.map(Float32Blob.decode).first?.map(\.bitPattern), vector.map(\.bitPattern))
    }

    // MARK: - Review regressions

    func testAutomaticRollbackDoomsTheRestOfTheTransaction() throws {
        let database = try StateDatabase()
        // ON CONFLICT ROLLBACK makes SQLite roll the whole transaction back by
        // itself; a body that swallows that error must not be able to commit
        // later statements in autocommit mode behind the wrapper's back.
        XCTAssertThrowsError(try database.inTransaction(.write) {
            try database.execute("INSERT INTO profiles (id, name) VALUES ('p1', 'Ada')")
            do {
                try database.execute(
                    "INSERT OR ROLLBACK INTO meta (key, value) VALUES ('schema_version', 'dup')"
                )
                XCTFail("duplicate key must fail")
            } catch {
                // Swallowed on purpose; the transaction is already gone.
            }
            XCTAssertThrowsError(try database.execute(
                "INSERT INTO profiles (id, name) VALUES ('p2', 'Grace')"
            )) {
                XCTAssertEqual($0 as? StateDatabaseError, .transactionAborted)
            }
        }) {
            XCTAssertEqual($0 as? StateDatabaseError, .transactionAborted)
        }
        XCTAssertEqual(try profileNames(database), [], "nothing from the doomed transaction may survive")
    }

    func testSymlinkedDatabaseFileIsRefused() throws {
        _ = try StateDatabase()
        let real = try StatePaths.stateDatabaseURL()
        let moved = directory.appendingPathComponent("moved.db")
        try FileManager.default.moveItem(at: real, to: moved)
        try FileManager.default.createSymbolicLink(at: real, withDestinationURL: moved)
        XCTAssertThrowsError(try StateDatabase()) {
            XCTAssertEqual($0 as? StateDatabaseError, .insecurePath(real.path))
        }
        XCTAssertNotNil(try? Data(contentsOf: moved), "the link target is left untouched")
    }

    func testLoosePermissionsAreTightenedOnReopen() throws {
        try StateDatabase().close()
        let databaseURL = try StatePaths.stateDatabaseURL()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: databaseURL.path)

        let reopened = try StateDatabase()
        try reopened.inTransaction(.write) {
            try reopened.execute("INSERT INTO profiles (id, name) VALUES ('p1', 'Ada')")
        }
        XCTAssertEqual(try mode(of: databaseURL), 0o600, "a restored backup's loose mode is repaired")
        XCTAssertEqual(try mode(of: URL(fileURLWithPath: databaseURL.path + "-wal")), 0o600)
    }

    /// Every 2.x store is superseded by the database — both ledgers, the
    /// profile store, and the managed transcripts directory — so any one of
    /// them makes creation migrate instead of recording 'fresh' markers that
    /// would hide it. StateMigrationTests covers what the migration does.
    func testAnyLegacyStateLocationTriggersMigration() throws {
        let state = try StatePaths.stateDirectoryURL()
        let candidates: [(URL, isDirectory: Bool)] = [
            (try StatePaths.processingHistoryURL(), false),
            (try StatePaths.timingHistoryURL(), false),
            (try StatePaths.legacySpeakerProfilesURL(), false),
            (try StatePaths.legacyTranscriptsDirectoryURL(), true),
        ]
        for (legacy, isDirectory) in candidates {
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            if isDirectory {
                try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
            } else if legacy.lastPathComponent == "speaker_profiles.json" {
                try Data("{\"schema_version\": 1, \"profiles\": []}\n".utf8).write(to: legacy)
            } else {
                try Data("{}\n".utf8).write(to: legacy)
            }
            let database = try StateDatabase()
            XCTAssertEqual(try database.metaValue("import_complete"), "migrated", legacy.lastPathComponent)
            XCTAssertEqual(try database.metaValue("archive_complete"), "migrated", legacy.lastPathComponent)
            XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), legacy.lastPathComponent)
            database.close()
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: try StatePaths.stateDatabaseURL().path + suffix)
            }
            try FileManager.default.removeItem(at: StateMigration.archiveDirectoryURL())
        }
        let database = try StateDatabase()
        XCTAssertEqual(try database.metaValue("import_complete"), "fresh", "with no legacy state left, a fresh database is created")
    }

    func testTextWithEmbeddedNulRoundTrips() throws {
        let database = try StateDatabase()
        let value = "abc\u{0}def"
        try database.inTransaction(.write) {
            try database.setMeta("nul_test", value)
        }
        XCTAssertEqual(try database.metaValue("nul_test"), value)
    }
}
