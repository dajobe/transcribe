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
        guard case .directory(let path, let sessions) = resolved else {
            return XCTFail("Expected .directory, got \(resolved)")
        }
        XCTAssertEqual(path, dir.standardizedFileURL.path)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(
            sessions[0].files.map { ($0 as NSString).lastPathComponent },
            ["Note 1.m4a", "Note 2.m4a", "Note 10.m4a"]
        )
    }

    func testResolveDirectoryAcceptsCaseInsensitiveExtensions() async throws {
        let dir = try makeTempDir()
        for name in ["A.M4A", "B.MP3", "C.wav"] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        let resolved = try await InputResolver.resolve(dir.path, sort: .name)
        guard case .directory(_, let sessions) = resolved else {
            return XCTFail("Expected .directory")
        }
        XCTAssertEqual(sessions.flatMap(\.files).count, 3)
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
        XCTAssertEqual(InputResolver.sessionBasenames(for: resolved, prefixOverride: nil), [dir.lastPathComponent])
    }

    func testResolveCwdResolvesToAbsoluteBasename() async throws {
        // Create a temp dir, chdir into it, run resolve(".") — sessionBasenames
        // should produce the cwd's actual last component, not literal "." or "Recording 1".
        let dir = try makeTempDir()
        try Data().write(to: dir.appendingPathComponent("a.m4a"))

        let originalCwd = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(originalCwd) }
        let cwdSet = FileManager.default.changeCurrentDirectoryPath(dir.path)
        XCTAssertTrue(cwdSet)

        let resolved = try await InputResolver.resolve(".", sort: .name)
        let basenames = InputResolver.sessionBasenames(for: resolved, prefixOverride: nil)
        // The temp directory name (e.g. UUID) is what should appear, not "." or empty.
        XCTAssertEqual(basenames, [dir.lastPathComponent])
    }

    func testSessionBasenamesSingleSessionDirectoryUsesDirName() async throws {
        let resolved = ResolvedInput.directory(
            path: "/Users/x/voicenotes",
            sessions: [AudioSession(files: ["/Users/x/voicenotes/a.m4a"], recordedAt: nil)]
        )
        XCTAssertEqual(InputResolver.sessionBasenames(for: resolved, prefixOverride: nil), ["voicenotes"])
    }

    func testSessionBasenamesMultiSessionAppendsRecordingN() async throws {
        let resolved = ResolvedInput.directory(
            path: "/Users/x/voicenotes",
            sessions: [
                AudioSession(files: ["/x/a.m4a"], recordedAt: nil),
                AudioSession(files: ["/x/b.m4a"], recordedAt: nil),
                AudioSession(files: ["/x/c.m4a"], recordedAt: nil),
            ]
        )
        XCTAssertEqual(
            InputResolver.sessionBasenames(for: resolved, prefixOverride: nil),
            ["voicenotes - Recording 1", "voicenotes - Recording 2", "voicenotes - Recording 3"]
        )
    }

    func testSessionBasenamesFallsBackToRecordingWhenDirNameUnusable() {
        // Standardising "/" or empty stays "/" with last component "/" → empty.
        // outputBasename returns "" for that case; sessionBasenames falls back.
        let resolved = ResolvedInput.directory(
            path: "/",
            sessions: [
                AudioSession(files: ["/a.m4a"], recordedAt: nil),
                AudioSession(files: ["/b.m4a"], recordedAt: nil),
            ]
        )
        XCTAssertEqual(
            InputResolver.sessionBasenames(for: resolved, prefixOverride: nil),
            ["Recording 1", "Recording 2"]
        )
    }

    func testSessionBasenamesHonoursPrefixOverride() {
        let resolved = ResolvedInput.directory(
            path: "/Users/x/voicenotes",
            sessions: [
                AudioSession(files: ["/x/a.m4a"], recordedAt: nil),
                AudioSession(files: ["/x/b.m4a"], recordedAt: nil),
            ]
        )
        XCTAssertEqual(
            InputResolver.sessionBasenames(for: resolved, prefixOverride: "meeting"),
            ["meeting - Recording 1", "meeting - Recording 2"]
        )
    }

    func testSessionBasenamesPrefixOverrideOnFile() {
        let resolved = ResolvedInput.file(path: "/x/clip.m4a")
        XCTAssertEqual(
            InputResolver.sessionBasenames(for: resolved, prefixOverride: "renamed"),
            ["renamed"]
        )
    }

    func testSessionBasenamesFileFallsBackToFileBasename() {
        let resolved = ResolvedInput.file(path: "/x/clip.m4a")
        XCTAssertEqual(
            InputResolver.sessionBasenames(for: resolved, prefixOverride: nil),
            ["clip"]
        )
    }

    func testResolveDirectorySortsByMTime() async throws {
        let dir = try makeTempDir()
        let files = ["c.m4a", "a.m4a", "b.m4a"]
        for name in files {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let mtimes: [String: Date] = [
            "a.m4a": baseDate,
            "b.m4a": baseDate.addingTimeInterval(60),
            "c.m4a": baseDate.addingTimeInterval(120),
        ]
        for (name, date) in mtimes {
            try FileManager.default.setAttributes(
                [.modificationDate: date],
                ofItemAtPath: dir.appendingPathComponent(name).path
            )
        }

        let resolved = try await InputResolver.resolve(dir.path, sort: .mtime)
        guard case .directory(_, let sessions) = resolved else {
            return XCTFail("Expected .directory")
        }
        XCTAssertEqual(
            sessions.flatMap(\.files).map { ($0 as NSString).lastPathComponent },
            ["a.m4a", "b.m4a", "c.m4a"]
        )
    }

    func testResolveDirectoryRecordedFallsBackToMTimeWhenMetadataMissing() async throws {
        let dir = try makeTempDir()
        for name in ["c.m4a", "a.m4a", "b.m4a"] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let mtimes: [String: Date] = [
            "a.m4a": baseDate.addingTimeInterval(120),
            "b.m4a": baseDate.addingTimeInterval(60),
            "c.m4a": baseDate,
        ]
        for (name, date) in mtimes {
            try FileManager.default.setAttributes(
                [.modificationDate: date],
                ofItemAtPath: dir.appendingPathComponent(name).path
            )
        }

        let resolved = try await InputResolver.resolve(dir.path, sort: .recorded)
        guard case .directory(_, let sessions) = resolved else {
            return XCTFail("Expected .directory")
        }
        XCTAssertEqual(
            sessions.flatMap(\.files).map { ($0 as NSString).lastPathComponent },
            ["c.m4a", "b.m4a", "a.m4a"]
        )
    }

    func testRecordedTrustCheckPassesWhenSpreadCoversDurations() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let clips = [
            AudioClip(path: "/a.m4a", recordedAt: base, durationSeconds: 60),
            AudioClip(path: "/b.m4a", recordedAt: base.addingTimeInterval(120), durationSeconds: 60),
            AudioClip(path: "/c.m4a", recordedAt: base.addingTimeInterval(240), durationSeconds: 60),
        ]
        // spread=240s, max duration=60s. Trust passes.
        XCTAssertEqual(InputResolver.recordedTrustCheck(clips, requested: .recorded), .recorded)
    }

    func testRecordedTrustCheckFallsBackWhenSpreadTooSmall() {
        // Voice Memos export pattern: all clips clustered at sync time.
        // Real-world data from a user dir.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let clips = [
            AudioClip(path: "/a.m4a", recordedAt: base, durationSeconds: 87),
            AudioClip(path: "/b.m4a", recordedAt: base.addingTimeInterval(2), durationSeconds: 1362),
            AudioClip(path: "/c.m4a", recordedAt: base.addingTimeInterval(3), durationSeconds: 775),
            AudioClip(path: "/d.m4a", recordedAt: base.addingTimeInterval(4), durationSeconds: 0.5),
        ]
        // spread = 4s, max(durations) = 1362s -> trust fails.
        XCTAssertEqual(InputResolver.recordedTrustCheck(clips, requested: .recorded), .name)
    }

    func testRecordedTrustCheckCatchesShortMaxClip() {
        // Even with a very short longest clip, if the spread is below it the
        // timestamps cannot reflect real sequential recording.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let clips = [
            AudioClip(path: "/a.m4a", recordedAt: base, durationSeconds: 30),
            AudioClip(path: "/b.m4a", recordedAt: base.addingTimeInterval(5), durationSeconds: 30),
        ]
        // spread = 5s, max = 30s -> fails.
        XCTAssertEqual(InputResolver.recordedTrustCheck(clips, requested: .recorded), .name)
    }

    func testRecordedTrustCheckPassesWhenAllRecordedAtNil() {
        let clips = [
            AudioClip(path: "/a.m4a", recordedAt: nil, durationSeconds: 60),
            AudioClip(path: "/b.m4a", recordedAt: nil, durationSeconds: 60),
        ]
        // Insufficient data; sortClips will fall back via the existing chain.
        // The trust check stays "recorded" — the absence of dates isn't grounds for demotion.
        XCTAssertEqual(InputResolver.recordedTrustCheck(clips, requested: .recorded), .recorded)
    }

    func testRecordedTrustCheckIgnoresWhenRequestedSortIsNotRecorded() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let clips = [
            AudioClip(path: "/a.m4a", recordedAt: base, durationSeconds: 60),
            AudioClip(path: "/b.m4a", recordedAt: base.addingTimeInterval(1), durationSeconds: 60),
        ]
        // spread < duration but the user explicitly asked for .name — leave it alone.
        XCTAssertEqual(InputResolver.recordedTrustCheck(clips, requested: .name), .name)
        XCTAssertEqual(InputResolver.recordedTrustCheck(clips, requested: .mtime), .mtime)
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
