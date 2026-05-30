import XCTest
@testable import transcribe

final class ConfigMergeTests: XCTestCase {
    func testMergeSharedUsesFileWhenCliOmitted() throws {
        var file = UserConfigFile()
        file.format = "md,json"
        let cli = try SharedTranscriptionOptions.parse([])
        let merged = try ConfigMerge.mergeShared(cli: cli, file: file)
        XCTAssertEqual(merged.format, "md,json")
    }

    func testMergeSharedCliOverridesFile() throws {
        var file = UserConfigFile()
        file.format = "md,json"
        var cli = try SharedTranscriptionOptions.parse([])
        cli.format = "txt"
        let merged = try ConfigMerge.mergeShared(cli: cli, file: file)
        XCTAssertEqual(merged.format, "txt")
    }

    func testTriStateVerboseFromFile() throws {
        var file = UserConfigFile()
        file.logging = UserConfigFile.LoggingSection(verbose: true, etaHints: nil, progressLog: nil)
        let cli = try SharedTranscriptionOptions.parse([])
        let merged = try ConfigMerge.mergeShared(cli: cli, file: file)
        XCTAssertTrue(merged.verbose)
        XCTAssertEqual(merged.logLevel, .debug)
    }

    func testLogLevelFromCliAndShorthands() throws {
        var merged = try ConfigMerge.mergeShared(
            cli: try SharedTranscriptionOptions.parse(["--log-level", "error"]),
            file: UserConfigFile()
        )
        XCTAssertEqual(merged.logLevel, .error)
        XCTAssertFalse(merged.verbose)

        merged = try ConfigMerge.mergeShared(
            cli: try SharedTranscriptionOptions.parse(["--verbose"]),
            file: UserConfigFile()
        )
        XCTAssertEqual(merged.logLevel, .debug)
        XCTAssertTrue(merged.verbose)

        merged = try ConfigMerge.mergeShared(
            cli: try SharedTranscriptionOptions.parse(["--quiet"]),
            file: UserConfigFile()
        )
        XCTAssertEqual(merged.logLevel, .warn)
        XCTAssertFalse(merged.verbose)
    }

    func testLoggingLevelOverridesLegacyVerbose() throws {
        var file = UserConfigFile()
        file.logging = UserConfigFile.LoggingSection(verbose: true, level: "warn")

        let merged = try ConfigMerge.mergeShared(cli: try SharedTranscriptionOptions.parse([]), file: file)

        XCTAssertEqual(merged.logLevel, .warn)
        XCTAssertFalse(merged.verbose)
    }

    func testConflictingCliLogLevelSelectorsThrow() throws {
        XCTAssertThrowsError(
            try ConfigMerge.mergeShared(
                cli: try SharedTranscriptionOptions.parse(["--verbose", "--log-level", "info"]),
                file: UserConfigFile()
            )
        )
        XCTAssertThrowsError(
            try ConfigMerge.mergeShared(
                cli: try SharedTranscriptionOptions.parse(["--quiet", "--log-level", "error"]),
                file: UserConfigFile()
            )
        )
    }

    func testMergeDirectoryUsesDefaultsWhenEmpty() throws {
        let cli = try DirectoryInputOptions.parse([])
        let merged = try ConfigMerge.mergeDirectory(cli: cli, file: UserConfigFile())
        XCTAssertEqual(merged.sort, TranscriptionDefaults.dirSort)
        XCTAssertEqual(merged.sessionGap, TranscriptionDefaults.dirSessionGapMinutes)
        XCTAssertEqual(merged.filenameTimeRecovery, TranscriptionDefaults.dirInputTimeSource.filenameRecoveryEnabled)
        XCTAssertEqual(merged.autoSessionBasename, TranscriptionDefaults.dirSessionNaming.autoSessionBasenameEnabled)
    }

    func testMergeVoiceMemosDefaults() throws {
        let cli = try VoiceMemosSourceArguments.parse([])
        let merged = ConfigMerge.mergeVoiceMemos(cli: cli, file: UserConfigFile())
        XCTAssertEqual(merged.recordingsDir, TranscriptionDefaults.voiceMemosRecordingsDir)
        XCTAssertEqual(merged.sessionGap, TranscriptionDefaults.voiceMemosSessionGapMinutes)
    }
}
