import Foundation
import XCTest
@testable import transcribe

final class VoiceMemosImportTests: XCTestCase {
    func testLoadsConfirmedCloudRecordingSchema() throws {
        let dir = try makeTempDir()
        try createVoiceMemosDB(in: dir)
        let audio = dir.appendingPathComponent("A.m4a")
        try Data("audio".utf8).write(to: audio)
        let dateSeconds = 789_000_000.0
        try sqlite(dir, """
            INSERT INTO ZCLOUDRECORDING
              (Z_PK, ZDATE, ZDURATION, ZLOCALDURATION, ZCUSTOMLABEL, ZCUSTOMLABELFORSORTING, ZENCRYPTEDTITLE, ZPATH, ZUNIQUEID, ZFLAGS, ZFOLDER, ZAUDIOFUTUREFLAGS, ZSHAREDFLAGS, ZSILENCEREMOVERENABLED, ZSKIPSILENCEENABLED, ZSTUDIOMIXENABLED, ZSTUDIOMIXLEVEL)
            VALUES
              (1, \(dateSeconds), 12.5, 10.0, 'Custom Title', 'custom title', 'Encrypted Title', 'A.m4a', 'unique-a', 7, 3, 11, 13, 1, 0, 1, 0.75);
            """)

        let recordings = try VoiceMemosImport.loadRecordings(recordingsDirectory: dir.path)
        let enhancements = try XCTUnwrap(recordings[0].enhancements)

        XCTAssertEqual(recordings.count, 1)
        XCTAssertEqual(recordings[0].primaryKey, 1)
        XCTAssertEqual(recordings[0].uniqueID, "unique-a")
        XCTAssertEqual(recordings[0].path, audio.path)
        XCTAssertEqual(recordings[0].durationSeconds, 12.5)
        XCTAssertEqual(recordings[0].title, "Custom Title")
        XCTAssertEqual(recordings[0].titleSource, .customLabel)
        XCTAssertEqual(recordings[0].titleForSorting, "custom title")
        XCTAssertEqual(recordings[0].flags, 7)
        XCTAssertEqual(recordings[0].folderID, 3)
        XCTAssertEqual(enhancements.audioFutureFlags, 11)
        XCTAssertEqual(enhancements.sharedFlags, 13)
        XCTAssertEqual(enhancements.silenceRemoverEnabled, true)
        XCTAssertEqual(enhancements.skipSilenceEnabled, false)
        XCTAssertEqual(enhancements.studioMixEnabled, true)
        XCTAssertEqual(enhancements.studioMixLevel, 0.75)
        XCTAssertEqual(recordings[0].recordedAt, Date(timeIntervalSinceReferenceDate: dateSeconds))
    }

    func testTitleFallbackAndUniqueIDFallback() throws {
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
        XCTAssertEqual(recording.titleSource, .encryptedTitle)
        XCTAssertEqual(recording.durationSeconds, 5.0)
        XCTAssertTrue(recording.sourceID.hasPrefix("voice_memos:"))
        XCTAssertTrue(recording.sourceID.contains("B.m4a"))
    }

    func testSortingTitleBeatsEncryptedTimestampFallback() throws {
        let dir = try makeTempDir()
        try createVoiceMemosDB(in: dir)
        let audio = dir.appendingPathComponent("F.m4a")
        try Data("audio".utf8).write(to: audio)
        try sqlite(dir, """
            INSERT INTO ZCLOUDRECORDING
              (Z_PK, ZDATE, ZLOCALDURATION, ZCUSTOMLABELFORSORTING, ZENCRYPTEDTITLE, ZPATH)
            VALUES
              (12, 789000012, 5.0, 'Project Update', '2026-05-27T15:29:31Z', 'F.m4a');
            """)

        let recording = try XCTUnwrap(VoiceMemosImport.loadRecordings(recordingsDirectory: dir.path).first)

        XCTAssertEqual(recording.title, "Project Update")
        XCTAssertEqual(recording.titleSource, .sortingLabel)
        XCTAssertEqual(recording.titleForSorting, "Project Update")
    }

    func testTimestampCustomLabelYieldsToSortedTitle() throws {
        let dir = try makeTempDir()
        try createVoiceMemosDB(in: dir)
        let audio = dir.appendingPathComponent("G.m4a")
        try Data("audio".utf8).write(to: audio)
        try sqlite(dir, """
            INSERT INTO ZCLOUDRECORDING
              (Z_PK, ZDATE, ZLOCALDURATION, ZCUSTOMLABEL, ZCUSTOMLABELFORSORTING, ZENCRYPTEDTITLE, ZPATH)
            VALUES
              (13, 789000013, 5.0, '2026-05-27T18:27:58Z', 'Crusoe Cody hill reliability capacity 2026-05-27', 'Crusoe Cody hill reliability capacity 2026-05-27', 'G.m4a');
            """)

        let recording = try XCTUnwrap(VoiceMemosImport.loadRecordings(recordingsDirectory: dir.path).first)

        XCTAssertEqual(recording.title, "Crusoe Cody hill reliability capacity 2026-05-27")
        XCTAssertEqual(recording.titleSource, .sortingLabel)
        XCTAssertEqual(recording.titleForSorting, "Crusoe Cody hill reliability capacity 2026-05-27")
    }

    func testMissingOptionalColumnsStillLoadsRecording() throws {
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
        XCTAssertEqual(recording.titleSource, .fallback)
        XCTAssertNil(recording.uniqueID)
        XCTAssertNil(recording.durationSeconds)
        XCTAssertNil(recording.enhancements)
        XCTAssertEqual(recording.path, audio.path)
    }

    func testMissingRequiredColumnThrowsInputError() throws {
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

    func testVoiceMemoSessionBasenamesUseCommonTitlePrefixForGroupedRecordings() {
        let date = Date(timeIntervalSinceReferenceDate: 789_000_000)
        let first = makeRecording(id: "a", title: "Design Review part 1", recordedAt: date)
        let second = makeRecording(
            id: "b",
            title: "Design Review part 2",
            recordedAt: date.addingTimeInterval(60)
        )

        let basenames = VoiceMemosImport.sessionBasenames(for: [[first, second]])

        XCTAssertEqual(basenames.count, 1)
        XCTAssertTrue(basenames[0].contains("Design Review +2 memos"), "basename: \(basenames[0])")
        XCTAssertFalse(basenames[0].contains("Voice Memos Session"))
    }

    func testVoiceMemoSessionBasenamesUseFirstEditedTitleForDistinctGroupedRecordings() {
        let date = Date(timeIntervalSinceReferenceDate: 789_000_000)
        let first = makeRecording(id: "a", title: "Coffee Shop Notes", recordedAt: date)
        let second = makeRecording(
            id: "b",
            title: "New Recording",
            recordedAt: date.addingTimeInterval(60),
            titleSource: .fallback
        )

        let basenames = VoiceMemosImport.sessionBasenames(for: [[first, second]])

        XCTAssertEqual(basenames.count, 1)
        XCTAssertTrue(basenames[0].contains("Coffee Shop Notes +2 memos"), "basename: \(basenames[0])")
        XCTAssertFalse(basenames[0].contains("New Recording"))
    }

    func testDefaultRecordingsDirectoryUsesTildeForLaterExpansion() {
        XCTAssertTrue(VoiceMemosImport.defaultRecordingsDirectory.hasPrefix("~/Library/"))
        XCTAssertFalse((VoiceMemosImport.defaultRecordingsDirectory as NSString).expandingTildeInPath.hasPrefix("~"))
    }

    func testAudioDigestBlobIsHexEncodedInSwift() throws {
        let dir = try makeTempDir()
        try createVoiceMemosDB(in: dir)
        let audio = dir.appendingPathComponent("D.m4a")
        try Data("audio".utf8).write(to: audio)

        // Insert the blob via sqlite hex literal so the byte content is exact
        // (0xDE 0xAD 0xBE 0xEF). The reader must decode this from the BLOB
        // column directly via sqlite3_column_blob/bytes (no SQL hex() wrapper).
        try sqlite(dir, """
            INSERT INTO ZCLOUDRECORDING
              (Z_PK, ZDATE, ZPATH, ZUNIQUEID, ZAUDIODIGEST)
            VALUES
              (10, 789000010, 'D.m4a', 'unique-d', x'DEADBEEF');
            """)

        let recording = try XCTUnwrap(VoiceMemosImport.loadRecordings(recordingsDirectory: dir.path).first)

        XCTAssertEqual(recording.audioDigestHex, "DEADBEEF")
    }

    func testAudioDigestNullBlobYieldsNil() throws {
        let dir = try makeTempDir()
        try createVoiceMemosDB(in: dir)
        let audio = dir.appendingPathComponent("E.m4a")
        try Data("audio".utf8).write(to: audio)
        try sqlite(dir, """
            INSERT INTO ZCLOUDRECORDING
              (Z_PK, ZDATE, ZPATH, ZUNIQUEID)
            VALUES
              (11, 789000011, 'E.m4a', 'unique-e');
            """)

        let recording = try XCTUnwrap(VoiceMemosImport.loadRecordings(recordingsDirectory: dir.path).first)

        XCTAssertNil(recording.audioDigestHex)
    }

    func testUnsafeColumnNameThrowsInputError() throws {
        let dir = try makeTempDir()
        try sqlite(dir, """
            CREATE TABLE ZCLOUDRECORDING (
                Z_PK INTEGER PRIMARY KEY,
                ZDATE TIMESTAMP,
                ZPATH VARCHAR,
                "Z-BAD" VARCHAR
            );
            """)

        do {
            _ = try VoiceMemosImport.loadRecordings(recordingsDirectory: dir.path)
            XCTFail("Expected unsafe column name failure")
        } catch let error as TranscribeError {
            XCTAssertEqual(error.exitCode, .inputFile)
            XCTAssertTrue(error.message.contains("unexpected column name"))
        }
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

    private func sqlite(_ dir: URL, _ sql: String, file: StaticString = #file, line: UInt = #line) throws {
        SQLiteTestHelpers.executeScript(
            at: dir.appendingPathComponent("CloudRecordings.db"),
            sql,
            file: file,
            line: line
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

    private func makeRecording(
        id: String,
        title: String,
        recordedAt: Date,
        titleSource: VoiceMemoTitleSource = .customLabel
    ) -> VoiceMemoRecording {
        VoiceMemoRecording(
            primaryKey: 1,
            uniqueID: id,
            path: "/tmp/\(id).m4a",
            recordedAt: recordedAt,
            durationSeconds: nil,
            title: title,
            audioDigestHex: nil,
            flags: nil,
            folderID: nil,
            titleSource: titleSource
        )
    }
}
