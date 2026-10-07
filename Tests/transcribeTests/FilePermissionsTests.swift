import Foundation
import XCTest
@testable import transcribe

final class FilePermissionsTests: XCTestCase {
    /// The ledgers used to be owner-only JSONL files; their rows now live in
    /// the state database, which must be just as private.
    func testLedgerAppendsCreateOwnerOnlyStateDatabase() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-perms-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let previous = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        setenv("XDG_STATE_HOME", dir.path, 1)
        defer {
            if let previous { setenv("XDG_STATE_HOME", previous, 1) } else { unsetenv("XDG_STATE_HOME") }
        }

        try ProcessingStore.appendVerbatim(line: "{\"ok\":true}")
        try TimingStore.appendVerbatim(line: "{\"ok\":true}")

        let state = try StatePaths.stateDirectoryURL()
        XCTAssertEqual(try XCTUnwrap(fileModeBits(atPath: state.path)) & 0o777, 0o700)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try StatePaths.stateDatabaseURL().path))
        for name in ["state.db", "state.db-wal", "state.db-shm", "init.lock"] {
            let path = state.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let mode = try XCTUnwrap(fileModeBits(atPath: path))
            XCTAssertEqual(mode & 0o777, 0o600, "\(name): expected owner-only mode, got \(String(mode, radix: 8))")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: try StatePaths.processingHistoryURL().path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try StatePaths.timingHistoryURL().path))
    }

    /// Render locks live in `<state>/locks/`, created owner-only on first
    /// use, one owner-only file per managed document.
    func testRenderLocksAreOwnerOnly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-perms-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let previous = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        setenv("XDG_STATE_HOME", dir.path, 1)
        defer {
            if let previous { setenv("XDG_STATE_HOME", previous, 1) } else { unsetenv("XDG_STATE_HOME") }
        }
        try FileManager.default.createDirectory(at: try StatePaths.stateDirectoryURL(), withIntermediateDirectories: true)
        let id = UUID()

        var ran = false
        try SpeakerCommands.withRenderLock(id: id) { ran = true }
        XCTAssertTrue(ran)
        // Reuse of an existing directory and lock file must work too.
        try SpeakerCommands.withRenderLock(id: id) {}

        let locks = try StatePaths.locksDirectoryURL()
        XCTAssertEqual(try XCTUnwrap(fileModeBits(atPath: locks.path)) & 0o777, 0o700)
        let lock = locks.appendingPathComponent("\(id.uuidString.lowercased()).lock")
        XCTAssertEqual(try XCTUnwrap(fileModeBits(atPath: lock.path)) & 0o777, 0o600)
    }

    func testTightenPermissionsAppliesOwnerOnlyMode() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-perms-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("state.json")
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        try tightenPermissions(ofPath: url.path, to: privateFileMode)
        XCTAssertEqual(try XCTUnwrap(fileModeBits(atPath: url.path)) & 0o777, 0o600)

        // A second call is a no-op rather than a repeated chmod.
        try tightenPermissions(ofPath: url.path, to: privateFileMode)
        XCTAssertEqual(try XCTUnwrap(fileModeBits(atPath: url.path)) & 0o777, 0o600)
    }

    func testTightenPermissionsReportsTheRealErrno() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-absent-\(UUID().uuidString)").path

        XCTAssertThrowsError(try tightenPermissions(ofPath: missing, to: privateFileMode)) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .ENOENT)
        }
    }

    func testUnsupportedPermissionErrnosWarnInsteadOfFailing() throws {
        // Network and FUSE mounts reject chmod; the operation must continue.
        for code in [ENOTSUP, EPERM] {
            XCTAssertNoThrow(try handlePermissionFailure(code: code, path: "/mnt/share/state.json"))
        }
        for code in [EACCES, EROFS] {
            XCTAssertThrowsError(try handlePermissionFailure(code: code, path: "/state.json")) { error in
                XCTAssertEqual((error as? POSIXError)?.code.rawValue, code)
            }
        }
    }
}
