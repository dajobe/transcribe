import Foundation
#if canImport(Darwin)
import Darwin
#endif
import XCTest
@testable import transcribe

final class UserConfigFileTests: XCTestCase {
    func testSaveCreatesOwnerOnlyConfigFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("config.json")
        var config = UserConfigFile()
        config.model = "large-v3"
        try UserConfigFile.save(config, to: url)

        let mode = try XCTUnwrap(fileModeBits(atPath: url.path))
        XCTAssertEqual(mode & 0o777, 0o600)
    }

    func testLoadWarnsWhenConfigIsWorldReadable() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        let pipe = Pipe()
        let savedStderr = dup(STDERR_FILENO)
        XCTAssertGreaterThanOrEqual(savedStderr, 0)

        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        try pipe.fileHandleForWriting.close()

        _ = try UserConfigFile.load(from: url)
        fflush(stderr)

        dup2(savedStderr, STDERR_FILENO)
        close(savedStderr)

        let stderr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertTrue(stderr.contains("world-readable"), "stderr: \(stderr)")
    }
}
