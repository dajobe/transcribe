import Foundation
import XCTest
@testable import transcribe

final class InputResolverTests: XCTestCase {
    func testResolveSingleFile() throws {
        let dir = try makeTempDir()
        let file = dir.appendingPathComponent("clip.m4a")
        try Data().write(to: file)

        let resolved = try InputResolver.resolve(file.path)
        guard case .file(let path) = resolved else {
            return XCTFail("Expected .file, got \(resolved)")
        }
        XCTAssertEqual(path, file.path)
    }

    func testResolveDirectoryFiltersAndSortsNaturally() throws {
        let dir = try makeTempDir()
        for name in [
            "Note 10.m4a",
            "Note 2.m4a",
            "Note 1.m4a",
            "notes.txt",
            ".DS_Store",
            "._foo.m4a",
        ] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        let subdir = dir.appendingPathComponent("subdir")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        try Data().write(to: subdir.appendingPathComponent("ignored.m4a"))

        let resolved = try InputResolver.resolve(dir.path)
        guard case .directory(let path, let files) = resolved else {
            return XCTFail("Expected .directory, got \(resolved)")
        }
        XCTAssertEqual(path, dir.path)
        XCTAssertEqual(
            files.map { ($0 as NSString).lastPathComponent },
            ["Note 1.m4a", "Note 2.m4a", "Note 10.m4a"]
        )
    }

    func testResolveDirectoryAcceptsCaseInsensitiveExtensions() throws {
        let dir = try makeTempDir()
        for name in ["A.M4A", "B.MP3", "C.wav"] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        let resolved = try InputResolver.resolve(dir.path)
        guard case .directory(_, let files) = resolved else {
            return XCTFail("Expected .directory")
        }
        XCTAssertEqual(files.count, 3)
    }

    func testResolveEmptyDirectoryThrowsInputFile() throws {
        let dir = try makeTempDir()
        XCTAssertThrowsError(try InputResolver.resolve(dir.path)) { err in
            guard let te = err as? TranscribeError else {
                return XCTFail("Unexpected error type: \(err)")
            }
            XCTAssertEqual(te.exitCode, .inputFile)
            XCTAssertTrue(te.message.contains("No audio files"))
        }
    }

    func testResolveDirectoryWithOnlyNonAudioThrowsInputFile() throws {
        let dir = try makeTempDir()
        try Data().write(to: dir.appendingPathComponent("notes.txt"))
        try Data().write(to: dir.appendingPathComponent("README.md"))

        XCTAssertThrowsError(try InputResolver.resolve(dir.path)) { err in
            guard let te = err as? TranscribeError else {
                return XCTFail("Unexpected error type: \(err)")
            }
            XCTAssertEqual(te.exitCode, .inputFile)
        }
    }

    func testResolveMissingPathThrowsInputFile() throws {
        XCTAssertThrowsError(try InputResolver.resolve("/nonexistent/path/voicenotes")) { err in
            guard let te = err as? TranscribeError else {
                return XCTFail("Unexpected error type: \(err)")
            }
            XCTAssertEqual(te.exitCode, .inputFile)
            XCTAssertTrue(te.message.contains("does not exist"))
        }
    }

    func testResolveDirectoryWithTrailingSlash() throws {
        let dir = try makeTempDir()
        try Data().write(to: dir.appendingPathComponent("a.m4a"))

        let resolved = try InputResolver.resolve(dir.path + "/")
        XCTAssertEqual(InputResolver.basename(for: resolved), dir.lastPathComponent)
    }

    func testBasenameForFileMatchesAudioPathBehaviour() throws {
        let resolved = ResolvedInput.file(path: "/some/where/meeting.mp3")
        XCTAssertEqual(InputResolver.basename(for: resolved), "meeting")
    }

    func testBasenameForDirectoryPreservesDots() throws {
        let resolved = ResolvedInput.directory(path: "/some/where/2026.04.notes", files: [])
        XCTAssertEqual(InputResolver.basename(for: resolved), "2026.04.notes")
    }

    func testBasenameForDirectoryStripsTrailingSlash() throws {
        let resolved = ResolvedInput.directory(path: "/some/where/voicenotes/", files: [])
        XCTAssertEqual(InputResolver.basename(for: resolved), "voicenotes")
    }

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
