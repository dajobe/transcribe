import Foundation
import XCTest

final class MigrationScriptTests: XCTestCase {
    func testDryRunReportsCountsWithoutModifyingFile() throws {
        let temp = try makeTempDirectory()
        let history = temp.appendingPathComponent("timing_history.jsonl")
        let original = v1TimingRow(extra: #","unknown_field":"keep me""#) + "\n"
        try original.write(to: history, atomically: true, encoding: .utf8)

        let result = try runMigrationScript(["--path", history.path, "--dry-run"])
        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("Would migrate 1 row(s)"), result.stdout)
        XCTAssertEqual(try String(contentsOf: history, encoding: .utf8), original)
    }

    func testMigrationCreatesBackupAndRewritesV1RowsToV2() throws {
        let temp = try makeTempDirectory()
        let history = temp.appendingPathComponent("timing_history.jsonl")
        let original = v1TimingRow(extra: #","unknown_field":"keep me""#) + "\n"
        try original.write(to: history, atomically: true, encoding: .utf8)

        let result = try runMigrationScript(["--path", history.path])
        XCTAssertEqual(result.status, 0, "stderr: \(result.stderr)")
        XCTAssertTrue(result.stdout.contains("Migrated 1 row(s)"), result.stdout)

        let migratedText = try String(contentsOf: history, encoding: .utf8)
        let rows = try parseJSONLines(migratedText)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0]["schema_version"] as? Int, 2)
        XCTAssertEqual(rows[0]["whisper_encoding_ms"] as? Int, 0)
        XCTAssertEqual(rows[0]["speaker_total_chunks"] as? Int, 0)
        XCTAssertEqual(rows[0]["unknown_field"] as? String, "keep me")

        let backups = try FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("timing_history.jsonl.v1-backup-") }
        XCTAssertEqual(backups.count, 1)
        let backup = try XCTUnwrap(backups.first)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), original)

        let attrs = try FileManager.default.attributesOfItem(atPath: history.path)
        let permissions = (attrs[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(permissions.map { $0 & 0o777 }, 0o600)
    }

    func testInvalidJSONLAbortsWithoutRewriting() throws {
        let temp = try makeTempDirectory()
        let history = temp.appendingPathComponent("timing_history.jsonl")
        let original = v1TimingRow() + "\n[]\n"
        try original.write(to: history, atomically: true, encoding: .utf8)

        let result = try runMigrationScript(["--path", history.path])
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("line 2"), result.stderr)
        XCTAssertEqual(try String(contentsOf: history, encoding: .utf8), original)

        let backups = try FileManager.default.contentsOfDirectory(at: temp, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("timing_history.jsonl.v1-backup-") }
        XCTAssertTrue(backups.isEmpty)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func packageRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    private func runMigrationScript(_ args: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let script = packageRoot().appendingPathComponent("scripts/migrate-timing-history-v2.swift")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", script.path] + args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let stdoutText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderrText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdoutText, stderrText)
    }

    private func parseJSONLines(_ text: String) throws -> [[String: Any]] {
        try text.split(separator: "\n").map { line in
            let data = Data(String(line).utf8)
            guard let row = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                XCTFail("Expected JSON object row: \(line)")
                return [:]
            }
            return row
        }
    }

    private func v1TimingRow(extra: String = "") -> String {
        """
        {"schema_version":1,"ended_at":"2026-05-28T12:00:00.000Z","transcribe_version":"1.8.0","model":"model-a","diarization_enabled":false,"input_basename":"a.wav","file_bytes":1000,"audio_duration_s":10,"segment_count":1,"speakers_detected":null,"audio_load_ms":100,"whisper_init_ms":200,"speaker_init_ms":0,"parallel_ms":0,"transcribe_only_ms":3000,"merge_ms":0,"write_outputs_ms":10,"total_ms":3310,"decoding_windows":2\(extra)}
        """
    }
}
