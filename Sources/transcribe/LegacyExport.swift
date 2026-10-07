import Darwin
import Foundation

/// `transcribe transcripts export-legacy`: dumps the complete state database
/// as the 2.x JSON files — one portable `.transcript.json` per managed
/// document under `transcripts/`, `speaker_profiles.json`, and both JSONL
/// ledgers — into a new or empty directory. The output shapes are frozen at
/// 2.x; state those shapes cannot represent makes the command fail and name
/// it, never drop it. This is the lossless rollback path and the migration
/// tests' comparison harness (migrate, export, compare against the sources).
///
/// Everything is read in one read transaction and encoded in memory before
/// the destination is touched, so unrepresentable state writes nothing. A
/// write failure after that removes the files and directories the command
/// created (and only those; see `write`), so a failed run never leaves a
/// dump that looks complete.
enum LegacyExport {
    static let transcriptsDirectoryName = "transcripts"
    static let profilesFileName = "speaker_profiles.json"
    static let processingFileName = "processing_history.jsonl"
    static let timingFileName = "timing_history.jsonl"

    /// The complete state, encoded in the 2.x formats.
    struct Snapshot {
        /// Lowercased document ID and its portable JSON bytes, by ID.
        var documents: [(id: String, data: Data)] = []
        var profiles = Data()
        var profileCount = 0
        var processingLines: [String] = []
        var timingLines: [String] = []

        /// JSONL bytes: one verbatim line each, newline-terminated; empty
        /// when there are no rows.
        static func ledgerData(_ lines: [String]) -> Data {
            Data(lines.map { $0 + "\n" }.joined().utf8)
        }
    }

    /// Reads and encodes the whole state. Throws `TranscribeError` listing
    /// every item the 2.x formats cannot represent (or that cannot be read),
    /// rather than leaving any of it out.
    static func snapshot() throws -> Snapshot {
        try StateStore.withDatabase { database in
            try database.inTransaction(.read) {
                var snapshot = Snapshot()
                var problems: [String] = []

                let version = try database.metaValue("schema_version")
                if version != String(StateDatabase.schemaVersion) {
                    problems.append("the state database has schema version \(version ?? "(none)"); this build writes 2.x files only from version \(StateDatabase.schemaVersion)")
                }

                let ids = try database.query("SELECT id FROM documents ORDER BY id") { $0.text(0) ?? "" }
                for raw in ids {
                    guard let id = UUID(uuidString: raw) else {
                        problems.append("document \(raw): stored document ID is not a UUID")
                        continue
                    }
                    let key = id.uuidString.lowercased()
                    do {
                        // Read rows directly: a joined store call that throws
                        // would doom the whole read and hide the other problems.
                        let document = try CanonicalTranscriptStore.materialize(id: id, in: database)
                        guard document.schemaVersion == CanonicalTranscript.currentSchemaVersion else {
                            problems.append("document \(key): schema version \(document.schemaVersion) has no 2.x representation")
                            continue
                        }
                        snapshot.documents.append((key, try CanonicalTranscriptStore.portableData(document)))
                    } catch {
                        problems.append("document \(key): \(SpeakerCommands.errorText(error))")
                    }
                }

                do {
                    (snapshot.profiles, snapshot.profileCount) = try SpeakerProfileStore.legacyStoreData(in: database)
                } catch {
                    problems.append("speaker profiles: \(SpeakerCommands.errorText(error))")
                }

                snapshot.processingLines = try database.query(
                    "SELECT record FROM processing_history ORDER BY rowid"
                ) { $0.text(0) ?? "" }
                snapshot.timingLines = try database.query(
                    "SELECT record FROM timing_history ORDER BY rowid"
                ) { $0.text(0) ?? "" }
                for (name, lines) in [(processingFileName, snapshot.processingLines), (timingFileName, snapshot.timingLines)] {
                    for (index, line) in lines.enumerated() where line.utf8.contains(0x0A) {
                        problems.append("\(name) row \(index + 1): contains a line break, which one JSONL line cannot hold")
                    }
                }

                // Rows whose parent is gone (possible only through outside
                // edits with foreign keys off) are invisible to every
                // reader above, so the dump would silently omit them.
                let orphans = try database.query("PRAGMA foreign_key_check") {
                    ($0.text(0) ?? "", $0.int(1), $0.text(2) ?? "")
                }
                for (table, rowid, parent) in orphans {
                    let row = rowid.map { "row \($0)" } ?? "a row"
                    problems.append("\(table) \(row): refers to a missing \(parent) row")
                }

                guard problems.isEmpty else {
                    throw TranscribeError(
                        message: "Cannot export the state as 2.x files; they cannot represent:\n"
                            + problems.map { "  - " + $0 }.joined(separator: "\n")
                            + "\nNothing was written.",
                        exitCode: .inputFile
                    )
                }
                return snapshot
            }
        }
    }

    /// Refuses a destination that exists and is not an empty directory.
    static func checkDestination(_ directory: URL) throws {
        var info = stat()
        guard lstat(directory.path, &info) == 0 else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw TranscribeError(
                message: "\(directory.path) exists and is not a directory. Choose a new or empty directory.",
                exitCode: .outputWrite
            )
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard entries.isEmpty else {
            throw TranscribeError(
                message: "\(directory.path) is not empty. export-legacy writes only into a new or empty directory.",
                exitCode: .outputWrite
            )
        }
    }

    /// Test seam: runs just before each file is published, with its path,
    /// so tests can race a concurrent writer or inject a failure.
    static var beforePublish: ((String) throws -> Void)?

    /// A file or directory this export created: where (relative to an open
    /// parent descriptor) and which inode, so cleanup removes exactly it.
    private struct Owned {
        let parentFD: Int32
        let name: String
        let id: FileID
        let isDirectory: Bool
        let path: String
    }

    /// Writes `snapshot` into `directory`, creating it and any missing
    /// ancestors: the export directory and `transcripts/` 0700, files 0600,
    /// each written atomically. Every ledger and the profile store are
    /// written even when empty, so the dump always has the same four
    /// entries.
    ///
    /// Every write is relative to descriptors of directories opened once, so
    /// a path component replaced meanwhile cannot redirect it, and no file
    /// is published over a name that appeared after the emptiness check
    /// (`RENAME_EXCL`). On failure, cleanup removes only what this call
    /// created — each entry by name under its parent descriptor and only
    /// while it is still the same inode; directories non-recursively, newest
    /// first — so files another process added survive, and so do the
    /// directories holding them.
    static func write(_ snapshot: Snapshot, to directory: URL) throws {
        try checkDestination(directory)
        var descriptors: [Int32] = []
        defer { descriptors.forEach { _ = Darwin.close($0) } }
        var owned: [Owned] = []

        func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        func openDirectory(_ fd: Int32) throws -> Int32 {
            guard fd >= 0 else { throw posixError() }
            descriptors.append(fd)
            return fd
        }
        func makeDirectory(in parentFD: Int32, _ name: String, path: String, mode: mode_t) throws -> Int32 {
            guard mkdirat(parentFD, name, mode) == 0 else { throw posixError() }
            let fd = try openDirectory(openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW))
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw posixError() }
            owned.append(Owned(parentFD: parentFD, name: name, id: FileID(info), isDirectory: true, path: path))
            return fd
        }
        func publish(_ data: Data, as name: String, in directoryFD: Int32, path: String) throws {
            try beforePublish?(path)
            let id = try publishPrivateFile(
                data: data, named: name, inDirectory: directoryFD, displayPath: path, replace: false
            )
            owned.append(Owned(parentFD: directoryFD, name: name, id: id, isDirectory: false, path: path))
        }

        do {
            // Create missing ancestors one level at a time, each recorded,
            // under the nearest one that exists.
            let components = (directory.standardizedFileURL.path as NSString).pathComponents
            var existing = components.count
            while existing > 1 {
                var info = stat()
                if lstat(NSString.path(withComponents: Array(components[..<existing])), &info) == 0 { break }
                existing -= 1
            }
            var currentFD = try openDirectory(open(NSString.path(withComponents: Array(components[..<existing])), O_RDONLY | O_DIRECTORY))
            for index in existing..<components.count {
                let isRoot = index == components.count - 1
                currentFD = try makeDirectory(
                    in: currentFD, components[index],
                    path: NSString.path(withComponents: Array(components[...index])),
                    mode: isRoot ? privateDirectoryMode : 0o777
                )
            }
            let rootFD = currentFD
            try tightenPermissions(ofFileDescriptor: rootFD, at: directory.path, to: privateDirectoryMode)

            let transcriptsPath = directory.appendingPathComponent(transcriptsDirectoryName).path
            let transcriptsFD = try makeDirectory(
                in: rootFD, transcriptsDirectoryName, path: transcriptsPath, mode: privateDirectoryMode
            )
            try tightenPermissions(ofFileDescriptor: transcriptsFD, at: transcriptsPath, to: privateDirectoryMode)
            for (id, data) in snapshot.documents {
                let name = id + StateMigration.transcriptSuffix
                try publish(data, as: name, in: transcriptsFD, path: transcriptsPath + "/" + name)
            }
            let files: [(String, Data)] = [
                (profilesFileName, snapshot.profiles),
                (processingFileName, Snapshot.ledgerData(snapshot.processingLines)),
                (timingFileName, Snapshot.ledgerData(snapshot.timingLines)),
            ]
            for (name, data) in files {
                try publish(data, as: name, in: rootFD, path: directory.appendingPathComponent(name).path)
            }
        } catch {
            var leftBehind: [String] = []
            for entry in owned.reversed() {
                var info = stat()
                guard fstatat(entry.parentFD, entry.name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                      FileID(info) == entry.id else { continue }
                if unlinkat(entry.parentFD, entry.name, entry.isDirectory ? AT_REMOVEDIR : 0) != 0 {
                    leftBehind.append(entry.path)
                }
            }
            let reason: String
            if let exists = error as? DestinationExistsError {
                reason = "\(exists.path) was created by something else during the export and was left alone"
            } else if let error = error as? TranscribeError {
                reason = error.message
            } else {
                reason = error.localizedDescription
            }
            let outcome = leftBehind.isEmpty
                ? "Everything the export created was removed."
                : "Removed what the export created except these, which now hold other files: \(leftBehind.joined(separator: ", "))."
            throw TranscribeError(
                message: "Cannot write the 2.x export to \(directory.path): \(reason). \(outcome)",
                exitCode: .outputWrite
            )
        }
    }
}
