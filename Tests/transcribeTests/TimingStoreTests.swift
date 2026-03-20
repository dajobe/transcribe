import Foundation
import XCTest
@testable import transcribe

final class TimingStoreTests: XCTestCase {
    func testMedianWallSecondsPerAudioSecond() {
        let p = PhaseTimings()
        let r1 = RunTimingRecord(
            endedAt: Date(),
            transcribeVersion: "1.1.0",
            model: "model-a",
            diarizationEnabled: true,
            inputBasename: "a.wav",
            fileBytes: 1000,
            audioDurationS: 10,
            segmentCount: 5,
            speakersDetected: 2,
            phases: p,
            writeOutputsMs: 10,
            totalMs: 10_000
        )
        let r2 = RunTimingRecord(
            endedAt: Date(),
            transcribeVersion: "1.1.0",
            model: "model-a",
            diarizationEnabled: true,
            inputBasename: "b.wav",
            fileBytes: 2000,
            audioDurationS: 10,
            segmentCount: 3,
            speakersDetected: 1,
            phases: p,
            writeOutputsMs: 10,
            totalMs: 20_000
        )
        let m = TimingStore.medianWallSecondsPerAudioSecond(records: [r1, r2])
        XCTAssertNotNil(m)
        XCTAssertEqual(m!, 1.5, accuracy: 0.0001)
    }

    func testMedianEmptyReturnsNil() {
        XCTAssertNil(TimingStore.medianWallSecondsPerAudioSecond(records: []))
    }

    func testStateDirectoryUnderXDGStateHome() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let prev = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        setenv("XDG_STATE_HOME", temp.path, 1)
        defer {
            if let prev {
                setenv("XDG_STATE_HOME", prev, 1)
            } else {
                unsetenv("XDG_STATE_HOME")
            }
        }
        let dir = try StatePaths.stateDirectoryURL()
        XCTAssertTrue(dir.path.hasSuffix("/transcribe"), "got \(dir.path)")
        XCTAssertEqual(dir.deletingLastPathComponent().path, temp.path)
    }

    func testAppendAndLoadRecentFiltersByModel() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-jsonl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let prev = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        setenv("XDG_STATE_HOME", temp.path, 1)
        defer {
            if let prev {
                setenv("XDG_STATE_HOME", prev, 1)
            } else {
                unsetenv("XDG_STATE_HOME")
            }
        }

        let p = PhaseTimings()
        let recA = RunTimingRecord(
            endedAt: Date(),
            transcribeVersion: "1.1.0",
            model: "alpha",
            diarizationEnabled: false,
            inputBasename: "x.wav",
            fileBytes: 100,
            audioDurationS: 60,
            segmentCount: 1,
            speakersDetected: nil,
            phases: p,
            writeOutputsMs: 1,
            totalMs: 6000
        )
        let recB = RunTimingRecord(
            endedAt: Date(),
            transcribeVersion: "1.1.0",
            model: "beta",
            diarizationEnabled: false,
            inputBasename: "y.wav",
            fileBytes: 100,
            audioDurationS: 60,
            segmentCount: 1,
            speakersDetected: nil,
            phases: p,
            writeOutputsMs: 1,
            totalMs: 6000
        )
        try TimingStore.append(recA)
        try TimingStore.append(recB)

        let loaded = try TimingStore.loadRecent(model: "alpha", diarizationEnabled: false, limit: 10)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].model, "alpha")
    }
}
