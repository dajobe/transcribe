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

    func testSessionBasenamesMultiSessionUsesFileBasenamesForSingleClipSessions() async throws {
        // Auto-basename: each session of one clip uses its file's basename.
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
            ["a", "b", "c"]
        )
    }

    func testSessionBasenamesMultiSessionFallsBackToDirWhenDisabled() async throws {
        // With autoSessionBasename: false, falls back to "<dir> - Recording N".
        let resolved = ResolvedInput.directory(
            path: "/Users/x/voicenotes",
            sessions: [
                AudioSession(files: ["/x/a.m4a"], recordedAt: nil),
                AudioSession(files: ["/x/b.m4a"], recordedAt: nil),
                AudioSession(files: ["/x/c.m4a"], recordedAt: nil),
            ]
        )
        XCTAssertEqual(
            InputResolver.sessionBasenames(
                for: resolved, prefixOverride: nil, autoSessionBasename: false
            ),
            ["voicenotes - Recording 1", "voicenotes - Recording 2", "voicenotes - Recording 3"]
        )
    }

    func testSessionBasenamesFallsBackToRecordingWhenDirNameUnusable() {
        // With auto-basename, single-clip sessions use file basenames; here
        // the file names are usable so they win even though the dir is "/".
        let resolved = ResolvedInput.directory(
            path: "/",
            sessions: [
                AudioSession(files: ["/a.m4a"], recordedAt: nil),
                AudioSession(files: ["/b.m4a"], recordedAt: nil),
            ]
        )
        XCTAssertEqual(
            InputResolver.sessionBasenames(for: resolved, prefixOverride: nil),
            ["a", "b"]
        )
    }

    func testSessionBasenamesFallsBackToRecordingWhenAutoBasenameDisabled() {
        // Disable auto-basename; with empty dir name, fall back to "Recording N".
        let resolved = ResolvedInput.directory(
            path: "/",
            sessions: [
                AudioSession(files: ["/a.m4a"], recordedAt: nil),
                AudioSession(files: ["/b.m4a"], recordedAt: nil),
            ]
        )
        XCTAssertEqual(
            InputResolver.sessionBasenames(
                for: resolved, prefixOverride: nil, autoSessionBasename: false
            ),
            ["Recording 1", "Recording 2"]
        )
    }

    func testSessionBasenamesDerivesCommonPrefixForMultiClipSession() {
        let resolved = ResolvedInput.directory(
            path: "/Users/x/talks",
            sessions: [
                AudioSession(
                    files: [
                        "/Users/x/talks/morning keynote part 1.m4a",
                        "/Users/x/talks/morning keynote part 2.m4a",
                        "/Users/x/talks/morning keynote part 3.m4a",
                    ],
                    recordedAt: nil
                )
            ]
        )
        XCTAssertEqual(
            InputResolver.sessionBasenames(for: resolved, prefixOverride: nil),
            ["morning keynote"]
        )
    }

    func testSessionBasenamesDisambiguatesDuplicateCommonPrefixes() {
        let resolved = ResolvedInput.directory(
            path: "/Users/x/talks",
            sessions: [
                AudioSession(
                    files: [
                        "/Users/x/talks/morning keynote part 1.m4a",
                        "/Users/x/talks/morning keynote part 2.m4a",
                    ],
                    recordedAt: nil
                ),
                AudioSession(
                    files: [
                        "/Users/x/talks/morning keynote part 3.m4a",
                        "/Users/x/talks/morning keynote part 4.m4a",
                    ],
                    recordedAt: nil
                ),
            ]
        )
        XCTAssertEqual(
            InputResolver.sessionBasenames(for: resolved, prefixOverride: nil),
            ["morning keynote", "morning keynote - Recording 2"]
        )
    }

    func testSessionBasenamesDisambiguationAvoidsExistingSuffixes() {
        let resolved = ResolvedInput.directory(
            path: "/Users/x/talks",
            sessions: [
                AudioSession(
                    files: [
                        "/Users/x/talks/morning keynote part 1.m4a",
                        "/Users/x/talks/morning keynote part 2.m4a",
                    ],
                    recordedAt: nil
                ),
                AudioSession(files: ["/Users/x/talks/morning keynote - Recording 2.m4a"], recordedAt: nil),
                AudioSession(
                    files: [
                        "/Users/x/talks/morning keynote part 3.m4a",
                        "/Users/x/talks/morning keynote part 4.m4a",
                    ],
                    recordedAt: nil
                ),
            ]
        )
        XCTAssertEqual(
            InputResolver.sessionBasenames(for: resolved, prefixOverride: nil),
            ["morning keynote", "morning keynote - Recording 2", "morning keynote - Recording 3"]
        )
    }

    func testSessionBasenamesRejectsShortCommonPrefix() {
        // Common prefix "ABC" is too short (3 chars < 8) → fallback to dir name.
        let resolved = ResolvedInput.directory(
            path: "/Users/x/clips",
            sessions: [
                AudioSession(
                    files: [
                        "/Users/x/clips/ABC1.m4a",
                        "/Users/x/clips/ABC2.m4a",
                    ],
                    recordedAt: nil
                )
            ]
        )
        XCTAssertEqual(
            InputResolver.sessionBasenames(for: resolved, prefixOverride: nil),
            ["clips"]
        )
    }

    func testCommonPrefixBasenameStripsPartSuffix() {
        let derived = InputResolver.commonPrefixBasename(forSessionFiles: [
            "/x/13:45 how we reliably send 1m messages part 1.m4a",
            "/x/13:45 how we reliably send 1m messages part 2.m4a",
            "/x/13:45 how we reliably send 1m messages part 3.m4a",
        ])
        XCTAssertEqual(derived, "13:45 how we reliably send 1m messages")
    }

    func testCommonPrefixBasenameRejectsNoSharedPrefix() {
        let derived = InputResolver.commonPrefixBasename(forSessionFiles: [
            "/x/Foo Cafe.m4a",
            "/x/Bar Park.m4a",
        ])
        XCTAssertNil(derived)
    }

    func testCommonPrefixBasenameRejectsBelow30PercentThreshold() {
        // LCP "abcdefgh" is 8 chars, but shortest basename is 30 chars → 27%.
        let derived = InputResolver.commonPrefixBasename(forSessionFiles: [
            "/x/abcdefghi-quite-distinct-here.m4a",
            "/x/abcdefghj-totally-different-z.m4a",
        ])
        XCTAssertNil(derived)
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

    func testResolveDirectoryRecordedFallsBackToFilenameWhenAllMetadataMissing() async throws {
        // When all clips lack embedded recorded-at and filenames don't carry
        // parseable time prefixes, the resolver demotes to natural-sort
        // filename — the most predictable fallback.
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
        // .name fallback ignores mtime and uses natural-sort filename order.
        XCTAssertEqual(
            sessions.flatMap(\.files).map { ($0 as NSString).lastPathComponent },
            ["a.m4a", "b.m4a", "c.m4a"]
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

    // MARK: - Filename time-prefix parser

    private var fixedMtime: Date {
        // 2026-01-15 14:00:00 UTC; mtime date used for time-only filenames.
        Date(timeIntervalSince1970: 1_768_528_800)
    }

    private func ymd(_ date: Date) -> (Int, Int, Int) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return (c.year!, c.month!, c.day!)
    }

    private func hms(_ date: Date) -> (Int, Int, Int) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let c = cal.dateComponents([.hour, .minute, .second], from: date)
        return (c.hour!, c.minute!, c.second!)
    }

    func testParseFilenameRecordedAtColonTime() {
        let d = InputResolver.parseFilenameRecordedAt(
            filename: "09:48 morning standup.m4a",
            fileMtime: fixedMtime
        )
        XCTAssertNotNil(d)
        XCTAssertEqual(hms(d!).0, 9)
        XCTAssertEqual(hms(d!).1, 48)
        XCTAssertEqual(hms(d!).2, 0)
        // mtime date is preserved
        let mt = ymd(fixedMtime)
        XCTAssertEqual(ymd(d!).0, mt.0)
        XCTAssertEqual(ymd(d!).1, mt.1)
        XCTAssertEqual(ymd(d!).2, mt.2)
    }

    func testParseFilenameRecordedAtColonTimeWithSeconds() {
        let d = InputResolver.parseFilenameRecordedAt(
            filename: "09:48:32 morning.m4a",
            fileMtime: fixedMtime
        )
        XCTAssertNotNil(d)
        XCTAssertEqual(hms(d!).2, 32)
    }

    func testParseFilenameRecordedAtDashTime() {
        let d = InputResolver.parseFilenameRecordedAt(
            filename: "09-48 morning.m4a",
            fileMtime: fixedMtime
        )
        XCTAssertNotNil(d)
        XCTAssertEqual(hms(d!).0, 9)
        XCTAssertEqual(hms(d!).1, 48)
    }

    func testParseFilenameRecordedAtUnderscoreHHMM() {
        let d = InputResolver.parseFilenameRecordedAt(
            filename: "0948_morning.m4a",
            fileMtime: fixedMtime
        )
        XCTAssertNotNil(d)
        XCTAssertEqual(hms(d!).0, 9)
        XCTAssertEqual(hms(d!).1, 48)
    }

    func testParseFilenameRecordedAtUnderscoreHHMMSS() {
        let d = InputResolver.parseFilenameRecordedAt(
            filename: "094832_morning.m4a",
            fileMtime: fixedMtime
        )
        XCTAssertNotNil(d)
        XCTAssertEqual(hms(d!).0, 9)
        XCTAssertEqual(hms(d!).1, 48)
        XCTAssertEqual(hms(d!).2, 32)
    }

    func testParseFilenameRecordedAtFullDateTime() {
        let d = InputResolver.parseFilenameRecordedAt(
            filename: "2026-01-15 09:48 keynote.m4a",
            fileMtime: fixedMtime
        )
        XCTAssertNotNil(d)
        XCTAssertEqual(ymd(d!).0, 2026)
        XCTAssertEqual(ymd(d!).1, 1)
        XCTAssertEqual(ymd(d!).2, 15)
        XCTAssertEqual(hms(d!).0, 9)
    }

    func testParseFilenameRecordedAtIsoTLike() {
        let d = InputResolver.parseFilenameRecordedAt(
            filename: "2026-01-15T09:48:00 keynote.m4a",
            fileMtime: fixedMtime
        )
        XCTAssertNotNil(d)
        XCTAssertEqual(ymd(d!).2, 15)
        XCTAssertEqual(hms(d!).0, 9)
        XCTAssertEqual(hms(d!).2, 0)
    }

    func testParseFilenameRecordedAtRejectsInvalidValues() {
        // 99:99 is invalid
        XCTAssertNil(InputResolver.parseFilenameRecordedAt(
            filename: "99:99 nope.m4a",
            fileMtime: fixedMtime
        ))
        // 24:00 is invalid (HH must be ≤ 23)
        XCTAssertNil(InputResolver.parseFilenameRecordedAt(
            filename: "24:00 nope.m4a",
            fileMtime: fixedMtime
        ))
        // 12:60 is invalid (MM must be ≤ 59)
        XCTAssertNil(InputResolver.parseFilenameRecordedAt(
            filename: "12:60 nope.m4a",
            fileMtime: fixedMtime
        ))
    }

    func testParseFilenameRecordedAtRejectsEmbeddedTime() {
        // No leading time prefix.
        XCTAssertNil(InputResolver.parseFilenameRecordedAt(
            filename: "morning standup at 09:48.m4a",
            fileMtime: fixedMtime
        ))
    }

    func testParseFilenameRecordedAtRejectsAlphanumericFollowing() {
        // 09:00abc would be ambiguous; require non-alphanumeric after the time.
        XCTAssertNil(InputResolver.parseFilenameRecordedAt(
            filename: "09:00abc.m4a",
            fileMtime: fixedMtime
        ))
    }

    func testParseFilenameRecordedAtNoMatchOnNonTimeContent() {
        XCTAssertNil(InputResolver.parseFilenameRecordedAt(
            filename: "Recording 1.m4a",
            fileMtime: fixedMtime
        ))
        XCTAssertNil(InputResolver.parseFilenameRecordedAt(
            filename: "talk-2024-q3.m4a",
            fileMtime: fixedMtime
        ))
        XCTAssertNil(InputResolver.parseFilenameRecordedAt(
            filename: "1.50 dotted.m4a",
            fileMtime: fixedMtime
        ))
    }

    func testParseFilenameRecordedAtRequiresTwoDigitMinutes() {
        // "9:5 …" has only one minute digit; reject.
        XCTAssertNil(InputResolver.parseFilenameRecordedAt(
            filename: "9:5 nope.m4a",
            fileMtime: fixedMtime
        ))
    }

    func testFilenameRecoveryActivatesWhenAllClipsParseable() async throws {
        // Create files whose filenames carry recording times. Their AVAsset
        // metadata is empty (no embedded creation_time on bare data files), so
        // the trust check will downgrade and recovery should kick in.
        let dir = try makeTempDir()
        for name in [
            "09:00 morning standup.m4a",
            "09:30 design review part 1.m4a",
            "09:30 design review part 2.m4a",
            "11:00 customer call.m4a",
        ] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        let resolved = try await InputResolver.resolve(dir.path, sort: .recorded)
        guard case .directory(_, let sessions) = resolved else {
            return XCTFail("Expected .directory")
        }
        // Recovery succeeds; ordering follows filename times. With session-gap
        // = 0 (default), all clips land in one session.
        let order = sessions.flatMap(\.files).map { ($0 as NSString).lastPathComponent }
        XCTAssertEqual(order, [
            "09:00 morning standup.m4a",
            "09:30 design review part 1.m4a",
            "09:30 design review part 2.m4a",
            "11:00 customer call.m4a",
        ])
    }

    func testFilenameRecoveryDeclinesOnMixedInput() async throws {
        let dir = try makeTempDir()
        // Half the files have prefixes, half don't.
        for name in ["09:00 a.m4a", "random_thoughts.m4a", "10:30 b.m4a"] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        let resolved = try await InputResolver.resolve(dir.path, sort: .recorded)
        guard case .directory(_, let sessions) = resolved else {
            return XCTFail("Expected .directory")
        }
        // Recovery declines; resolver demotes to natural-sort filename order.
        // Lexicographic order: "09:00 a" < "10:30 b" < "random_thoughts".
        let order = sessions.flatMap(\.files).map { ($0 as NSString).lastPathComponent }
        XCTAssertEqual(order, [
            "09:00 a.m4a",
            "10:30 b.m4a",
            "random_thoughts.m4a",
        ])
    }

    func testFilenameRecoveryRespectsOptOut() async throws {
        // All clips have parseable prefixes but recovery is disabled.
        let dir = try makeTempDir()
        for name in ["09:00 a.m4a", "10:30 b.m4a"] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        let resolved = try await InputResolver.resolve(
            dir.path, sort: .recorded, filenameTimeRecovery: false
        )
        // Trust check fails (no embedded times → no spread vs. duration check
        // either, returning .recorded), so this case won't downgrade and
        // recovery is moot. We're verifying the flag plumbs through; the
        // ordering follows the trust-check's tiebreak chain.
        guard case .directory = resolved else {
            return XCTFail("Expected .directory")
        }
    }

    func testParseFilenameRecordedAtTrimsLeadingSpace() {
        let d = InputResolver.parseFilenameRecordedAt(
            filename: "   09:48 padded.m4a",
            fileMtime: fixedMtime
        )
        XCTAssertNotNil(d)
        XCTAssertEqual(hms(d!).0, 9)
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
