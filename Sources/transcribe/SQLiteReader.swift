import Foundation
import SQLite3

/// Minimal in-process, read-only SQLite reader used in place of shelling out
/// to `/usr/bin/sqlite3`. Designed for short-lived single-threaded use; we
/// intentionally avoid mutexes (`SQLITE_OPEN_NOMUTEX`).
final class ReadOnlyDatabase {
    private var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let status = sqlite3_open_v2(path, &handle, flags, nil)
        if status != SQLITE_OK {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "code \(status)"
            sqlite3_close_v2(handle)
            handle = nil
            throw ReadOnlyDatabase.openError(status: status, detail: message, path: path)
        }
    }

    deinit {
        if handle != nil {
            sqlite3_close_v2(handle)
        }
    }

    /// Prepare `sql`, step every row, and return values produced by `map`.
    /// The statement is finalized regardless of success or failure.
    func query<T>(_ sql: String, map: (Statement) throws -> T) throws -> [T] {
        var stmt: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard prepareStatus == SQLITE_OK, let stmt else {
            let detail = lastErrorMessage()
            sqlite3_finalize(stmt)
            throw ReadOnlyDatabase.queryError(detail: detail)
        }
        defer { sqlite3_finalize(stmt) }

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
                throw ReadOnlyDatabase.queryError(detail: lastErrorMessage())
            }
        }
    }

    private func lastErrorMessage() -> String {
        guard let handle else { return "unknown error" }
        return String(cString: sqlite3_errmsg(handle))
    }

    private static func openError(status: Int32, detail: String, path: String) -> TranscribeError {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = trimmed.isEmpty ? "" : ": \(trimmed)"
        return TranscribeError(
            message: "Cannot open SQLite database at \(path)\(suffix). Grant Full Disk Access if macOS denies the recordings directory.",
            exitCode: .inputFile
        )
    }

    private static func queryError(detail: String) -> TranscribeError {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = trimmed.isEmpty ? "" : ": \(trimmed)"
        return TranscribeError(
            message: "SQLite query failed\(suffix). Grant Full Disk Access if macOS denies the recordings directory.",
            exitCode: .inputFile
        )
    }
}

/// Thin wrapper around a stepped `sqlite3_stmt` exposing typed column access.
struct Statement {
    let handle: OpaquePointer

    var columnCount: Int32 { sqlite3_column_count(handle) }

    func columnName(_ index: Int32) -> String {
        guard let cString = sqlite3_column_name(handle, index) else { return "" }
        return String(cString: cString)
    }

    func isNull(_ index: Int32) -> Bool {
        sqlite3_column_type(handle, index) == SQLITE_NULL
    }

    func int(_ index: Int32) -> Int64? {
        isNull(index) ? nil : sqlite3_column_int64(handle, index)
    }

    func double(_ index: Int32) -> Double? {
        isNull(index) ? nil : sqlite3_column_double(handle, index)
    }

    func text(_ index: Int32) -> String? {
        guard !isNull(index), let cString = sqlite3_column_text(handle, index) else {
            return nil
        }
        return String(cString: cString)
    }

    func blob(_ index: Int32) -> Data? {
        guard !isNull(index) else { return nil }
        let byteCount = Int(sqlite3_column_bytes(handle, index))
        guard byteCount > 0, let pointer = sqlite3_column_blob(handle, index) else {
            return byteCount == 0 ? Data() : nil
        }
        return Data(bytes: pointer, count: byteCount)
    }
}

extension Data {
    /// Uppercase hex matching what SQLite's `hex()` SQL function used to emit
    /// for `ZAUDIODIGEST`.
    var hexEncodedString: String {
        var output = String()
        output.reserveCapacity(count * 2)
        for byte in self {
            output.append(String(format: "%02X", byte))
        }
        return output
    }
}
