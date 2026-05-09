import Foundation
import SQLite3
import XCTest

/// Test-only fixture helper. Opens a SQLite file read/write (creating it if
/// missing) and executes a multi-statement SQL script via `sqlite3_exec`.
/// This replaces the previous `/usr/bin/sqlite3` subprocess in tests so the
/// suite no longer depends on the system CLI being installed.
enum SQLiteTestHelpers {
    static func executeScript(at url: URL, _ sql: String, file: StaticString = #file, line: UInt = #line) {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let openStatus = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard openStatus == SQLITE_OK, let handle else {
            let detail = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "code \(openStatus)"
            sqlite3_close_v2(handle)
            XCTFail("sqlite open failed at \(url.path): \(detail)", file: file, line: line)
            return
        }
        defer { sqlite3_close_v2(handle) }

        var errorPointer: UnsafeMutablePointer<CChar>?
        let execStatus = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        if execStatus != SQLITE_OK {
            let detail = errorPointer.map { String(cString: $0) } ?? "code \(execStatus)"
            sqlite3_free(errorPointer)
            XCTFail("sqlite exec failed: \(detail)", file: file, line: line)
            return
        }
        sqlite3_free(errorPointer)
    }
}
