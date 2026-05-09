import Foundation
import XCTest
@testable import transcribe

final class VoiceMemosImportTests: XCTestCase {
    func testLoadsConfirmedCloudRecordingSchema() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3"))
        let dir = try makeTempDir()
        try createVoiceMemosDB(in: dir)
        let audio = dir.appendingPathComponent("A.m4a")
        try Data("audio".utf8).write(to: audio)
        let dateSeconds = 789_000_000.0
        try sqlite(dir, """
            INSERT INTO ZCLOUDRECORDING
              (Z_PK, ZDATE, ZDURATION, ZLOCALDURATION, ZCUSTOMLABEL, ZENCRYPTEDTITLE, ZPATH, ZUNIQUEID, ZFLAGS, ZFOLDER)
            VALUES
              (1, \(dateSeconds), 12.5, 10.0, 'Custom Title', 'Encrypted Title', 'A.m4a', 'unique-a', 7, 3);
            """)

        let recordings = try VoiceMemosImport.loadRecordings(recordingsDirectory: dir.path)

        XCTAssertEqual(recordings.count, 1)
        XCTAssertEqual(recordings[0].primaryKey, 1)
        XCTAssertEqual(recordings[0].uniqueID, "unique-a")
        XCTAssertEqual(recordings[0].path, audio.path)
        XCTAssertEqual(recordings[0].durationSeconds, 12.5)
        XCTAssertEqual(recordings[0].title, "Custom Title")
        XCTAssertEqual(recordings[0].flags, 7)
        XCTAssertEqual(recordings[0].folderID, 3)
        XCTAssertEqual(recordings[0].recordedAt, Date(timeIntervalSinceReferenceDate: dateSeconds))
    }

    func testTitleFallbackAndUniqueIDFallback() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3"))
        let dir = try makeTempDir()
        try createVoiceMemosDB(in: dir)
        let audio = dir.appendingPathComponent("B.m4a")
        try Data("audio".utf8).write(to: audio)
        try sqlite(dir, """
            INSERT INTO ZCLOUDRECORDING
              (Z_PK, ZDATE, ZLOCALDURATION, ZENCRYPTEDTITLE, ZPATH)
            VALUES
              (2, 789000001, 5.0, 'Fallback Title', 'B.m4a');
            """)

        let recording = try XCTUnwrap(VoiceMemosImport.loadRecordings(recordingsDirectory: dir.path).first)

        XCTAssertNil(recording.uniqueID)
        XCTAssertEqual(recording.title, "Fallback Title")
        XCTAssertEqual(recording.durationSeconds, 5.0)
        XCTAssertTrue(recording.sourceID.hasPrefix("voice_memos:"))
        XCTAssertTrue(recording.sourceID.contains("B.m4a"))
    }

    func testMissingOptionalColumnsStillLoadsRecording() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3"))
        let dir = try makeTempDir()
        try sqlite(dir, """
            CREATE TABLE ZCLOUDRECORDING (
                Z_PK INTEGER PRIMARY KEY,
                ZDATE TIMESTAMP,
                ZPATH VARCHAR
            );
            INSERT INTO ZCLOUDRECORDING (Z_PK, ZDATE, ZPATH)
            VALUES (4, 789000003, 'C.m4a');
            """)
        let audio = dir.appendingPathComponent("C.m4a")
        try Data("audio".utf8).write(to: audio)

        let recording = try XCTUnwrap(VoiceMemosImport.loadRecordings(recordingsDirectory: dir.path).first)

        XCTAssertEqual(recording.title, "New Recording")
        XCTAssertNil(recording.uniqueID)
        XCTAssertNil(recording.durationSeconds)
        XCTAssertEqual(recording.path, audio.path)
    }

    func testMissingRequiredColumnThrowsInputError() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3"))
        let dir = try makeTempDir()
        try sqlite(dir, """
            CREATE TABLE ZCLOUDRECORDING (
                Z_PK INTEGER PRIMARY KEY,
                ZPATH VARCHAR
            );
            """)

        do {
            _ = try VoiceMemosImport.loadRecordings(recordingsDirectory: dir.path)
            XCTFail("Expected required-column failure")
        } catch let error as TranscribeError {
            XCTAssertEqual(error.exitCode, .inputFile)
            XCTAssertTrue(error.message.contains("ZDATE"))
        }
    }

    func testMissingAudioFileIsSkipped() throws {
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3"))
        let dir = try makeTempDir()
        try createVoiceMemosDB(in: dir)
        try sqlite(dir, """
            INSERT INTO ZCLOUDRECORDING
              (Z_PK, ZDATE, ZPATH, ZUNIQUEID)
            VALUES
              (3, 789000002, 'missing.m4a', 'missing');
            """)

        do {
            _ = try VoiceMemosImport.loadRecordings(recordingsDirectory: dir.path)
            XCTFail("Expected no usable recordings")
        } catch let error as TranscribeError {
            XCTAssertEqual(error.exitCode, .inputFile)
            XCTAssertTrue(error.message.contains("No usable Voice Memos"))
        }
    }

    func testVoiceMemoBasenamesUseDateTitleAndCollisionSuffix() throws {
        let date = Date(timeIntervalSinceReferenceDate: 789_000_000)
        let first = VoiceMemoRecording(
            primaryKey: 1,
            uniqueID: "a",
            path: "/tmp/a.m4a",
            recordedAt: date,
            durationSeconds: nil,
            title: "Title / With: Bad\nChars",
            audioDigestHex: nil,
            flags: nil,
            folderID: nil
        )
        let second = VoiceMemoRecording(
            primaryKey: 2,
            uniqueID: "b",
            path: "/tmp/b.m4a",
            recordedAt: date,
            durationSeconds: nil,
            title: "Title / With: Bad\nChars",
            audioDigestHex: nil,
            flags: nil,
            folderID: nil
        )

        let basenames = VoiceMemosImport.basenames(for: [first, second])

        XCTAssertEqual(basenames.count, 2)
        XCTAssertTrue(basenames[0].contains("Title With Bad Chars"))
        XCTAssertEqual(basenames[1], "\(basenames[0]) - 2")
        XCTAssertFalse(basenames[0].contains("/"))
        XCTAssertFalse(basenames[0].contains(":"))
    }

    func testDefaultRecordingsDirectoryUsesTildeForLaterExpansion() {
        XCTAssertTrue(VoiceMemosImport.defaultRecordingsDirectory.hasPrefix("~/Library/"))
        XCTAssertFalse((VoiceMemosImport.defaultRecordingsDirectory as NSString).expandingTildeInPath.hasPrefix("~"))
    }

    private func createVoiceMemosDB(in dir: URL) throws {
        try sqlite(dir, """
            CREATE TABLE ZCLOUDRECORDING (
                Z_PK INTEGER PRIMARY KEY,
                Z_ENT INTEGER,
                Z_OPT INTEGER,
                ZAUDIOFUTUREFLAGS INTEGER,
                ZFLAGS INTEGER,
                ZSHAREDFLAGS INTEGER,
                ZSILENCEREMOVERENABLED INTEGER,
                ZSKIPSILENCEENABLED INTEGER,
                ZSTUDIOMIXENABLED INTEGER,
                ZFOLDER INTEGER,
                ZDATE TIMESTAMP,
                ZDURATION FLOAT,
                ZEVICTIONDATE TIMESTAMP,
                ZLOCALDURATION FLOAT,
                ZMTLAYERMIX FLOAT,
                ZPLAYBACKPOSITION FLOAT,
                ZPLAYBACKRATE FLOAT,
                ZPLAYBACKSPEED FLOAT,
                ZSTUDIOMIXLEVEL FLOAT,
                ZCUSTOMLABEL VARCHAR,
                ZCUSTOMLABELFORSORTING VARCHAR,
                ZENCRYPTEDTITLE VARCHAR,
                ZPATH VARCHAR,
                ZUNIQUEID VARCHAR,
                ZAUDIOFUTUREUUIDS BLOB,
                ZAUDIODIGEST BLOB,
                ZAUDIOFUTURE BLOB,
                ZMTAUDIOFUTURE BLOB,
                ZVERSIONEDAUDIOFUTURE BLOB
            );
            """)
    }

    private func sqlite(_ dir: URL, _ sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-init", "/dev/null", dir.appendingPathComponent("CloudRecordings.db").path, sql]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let text = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTFail("sqlite failed: \(text)")
        }
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
