import Foundation
import XCTest
@testable import transcribe

final class FilePermissionsTests: XCTestCase {
    func testLockedAppendWriterCreatesOwnerOnlyFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-perms-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("history.jsonl")
        try LockedAppendWriter.append(Data("{\"ok\":true}\n".utf8), to: url)

        let mode = try XCTUnwrap(fileModeBits(atPath: url.path))
        XCTAssertEqual(mode & 0o777, 0o600, "expected owner-only mode, got \(String(mode, radix: 8))")
    }

    func testLockedAppendWriterTightensExistingWorldReadableFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-perms-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("history.jsonl")
        try Data("{\"old\":true}\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        try LockedAppendWriter.append(Data("{\"new\":true}\n".utf8), to: url)

        let mode = try XCTUnwrap(fileModeBits(atPath: url.path))
        XCTAssertEqual(mode & 0o777, 0o600)
    }
}
