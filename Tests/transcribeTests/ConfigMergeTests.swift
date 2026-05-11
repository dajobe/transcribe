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
