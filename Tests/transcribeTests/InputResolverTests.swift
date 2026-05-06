import Foundation
import XCTest
@testable import transcribe

final class InputResolverTests: XCTestCase {
    func testResolveSingleFile() async throws {
        let dir = try makeTempDir()
        let file = dir.appendingPathComponent("clip.m4a")
        try Data().write(to: file)

        let resolved = try await InputResolver.resolve(file.path)
        guard case .file(let path) = resolved else {
            return XCTFail("Expected .file, got \(resolved)")
        }
        XCTAssertEqual(path, file.path)
    }

    func testResolveDirectoryFiltersAndSortsByName() async throws {
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

        let resolved = try await InputResolver.resolve(dir.path, sort: .name)
        guard case .directory(let path, let files) = resolved else {
            return XCTFail("Expected .directory, got \(resolved)")
        }
        XCTAssertEqual(path, dir.path)
        XCTAssertEqual(
            files.map { ($0 as NSString).lastPathComponent },
            ["Note 1.m4a", "Note 2.m4a", "Note 10.m4a"]
        )
    }

    func testResolveDirectoryAcceptsCaseInsensitiveExtensions() async throws {
        let dir = try makeTempDir()
        for name in ["A.M4A", "B.MP3", "C.wav"] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        let resolved = try await InputResolver.resolve(dir.path, sort: .name)
        guard case .directory(_, let files) = resolved else {
            return XCTFail("Expected .directory")
        }
        XCTAssertEqual(files.count, 3)
    }

    func testResolveEmptyDirectoryThrowsInputFile() async throws {
        let dir = try makeTempDir()
        do {
            _ = try await InputResolver.resolve(dir.path)
            XCTFail("Expected throw")
        } catch let te as TranscribeError {
            XCTAssertEqual(te.exitCode, .inputFile)
            XCTAssertTrue(te.message.contains("No audio files"))
        }
    }

    func testResolveDirectoryWithOnlyNonAudioThrowsInputFile() async throws {
        let dir = try makeTempDir()
        try Data().write(to: dir.appendingPathComponent("notes.txt"))
        try Data().write(to: dir.appendingPathComponent("README.md"))

        do {
            _ = try await InputResolver.resolve(dir.path)
            XCTFail("Expected throw")
        } catch let te as TranscribeError {
            XCTAssertEqual(te.exitCode, .inputFile)
        }
    }

    func testResolveMissingPathThrowsInputFile() async throws {
        do {
            _ = try await InputResolver.resolve("/nonexistent/path/voicenotes")
            XCTFail("Expected throw")
        } catch let te as TranscribeError {
            XCTAssertEqual(te.exitCode, .inputFile)
            XCTAssertTrue(te.message.contains("does not exist"))
        }
    }

    func testResolveDirectoryWithTrailingSlash() async throws {
        let dir = try makeTempDir()
        try Data().write(to: dir.appendingPathComponent("a.m4a"))

        let resolved = try await InputResolver.resolve(dir.path + "/", sort: .name)
        XCTAssertEqual(InputResolver.basename(for: resolved), dir.lastPathComponent)
    }

    func testBasenameForFileMatchesAudioPathBehaviour() {
        let resolved = ResolvedInput.file(path: "/some/where/meeting.mp3")
        XCTAssertEqual(InputResolver.basename(for: resolved), "meeting")
    }

    func testBasenameForDirectoryPreservesDots() {
        let resolved = ResolvedInput.directory(path: "/some/where/2026.04.notes", files: [])
        XCTAssertEqual(InputResolver.basename(for: resolved), "2026.04.notes")
    }

    func testBasenameForDirectoryStripsTrailingSlash() {
        let resolved = ResolvedInput.directory(path: "/some/where/voicenotes/", files: [])
        XCTAssertEqual(InputResolver.basename(for: resolved), "voicenotes")
    }

    func testResolveDirectorySortsByMTime() async throws {
        let dir = try makeTempDir()
        // Create files in a non-mtime-friendly filename order so sort=mtime
        // produces a different order than sort=name.
        let files = ["c.m4a", "a.m4a", "b.m4a"]
        for name in files {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        // Set explicit mtimes: a -> oldest, b -> middle, c -> newest.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let mtimes: [String: Date] = [
            "a.m4a": base,
            "b.m4a": base.addingTimeInterval(60),
            "c.m4a": base.addingTimeInterval(120),
        ]
        for (name, date) in mtimes {
            try FileManager.default.setAttributes(
                [.modificationDate: date],
                ofItemAtPath: dir.appendingPathComponent(name).path
            )
        }

        let resolved = try await InputResolver.resolve(dir.path, sort: .mtime)
        guard case .directory(_, let sorted) = resolved else {
            return XCTFail("Expected .directory")
        }
        XCTAssertEqual(
            sorted.map { ($0 as NSString).lastPathComponent },
            ["a.m4a", "b.m4a", "c.m4a"]
        )
    }

    func testResolveDirectoryRecordedFallsBackToMTimeWhenMetadataMissing() async throws {
        // Empty .m4a stubs have no AVAsset creationDate, so recorded mode
        // should fall back to mtime ordering (then natural-sort on tie).
        let dir = try makeTempDir()
        for name in ["c.m4a", "a.m4a", "b.m4a"] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let mtimes: [String: Date] = [
            "a.m4a": base.addingTimeInterval(120),
            "b.m4a": base.addingTimeInterval(60),
            "c.m4a": base,
        ]
        for (name, date) in mtimes {
            try FileManager.default.setAttributes(
                [.modificationDate: date],
                ofItemAtPath: dir.appendingPathComponent(name).path
            )
        }

        let resolved = try await InputResolver.resolve(dir.path, sort: .recorded)
        guard case .directory(_, let sorted) = resolved else {
            return XCTFail("Expected .directory")
        }
        XCTAssertEqual(
            sorted.map { ($0 as NSString).lastPathComponent },
            ["c.m4a", "b.m4a", "a.m4a"]
        )
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
