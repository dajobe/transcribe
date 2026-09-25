import XCTest
@testable import transcribe

final class PhaseETATests: XCTestCase {
    func testHistoryOnlyCountsDown() {
        let tracker = PhaseProgressTracker()
        XCTAssertEqual(
            try XCTUnwrap(PhaseETA.remaining(elapsed: 30, historyTotal: 100, progress: tracker)),
            70,
            accuracy: 0.0001
        )
        XCTAssertNil(PhaseETA.remaining(elapsed: 30, historyTotal: nil, progress: tracker))
    }

    func testLivePaceReplacesHistoryOnceEnoughIsDone() {
        var tracker = PhaseProgressTracker()
        // History says 1000s; the run is actually on pace for 200s.
        tracker.record(completed: 25, total: 100, elapsed: 50)
        let remaining = try? XCTUnwrap(PhaseETA.remaining(elapsed: 50, historyTotal: 1000, progress: tracker))
        XCTAssertEqual(try XCTUnwrap(remaining), 150, accuracy: 0.0001)
    }

    func testEarlyProgressBlendsTowardHistory() {
        var tracker = PhaseProgressTracker()
        // One of 100 units done after 10s: pace says 1000s, history says 200s.
        tracker.record(completed: 1, total: 100, elapsed: 10)
        let remaining = try? XCTUnwrap(PhaseETA.remaining(elapsed: 10, historyTotal: 200, progress: tracker))
        // weight = 0.01 / 0.2 = 0.05 -> total = 0.95 * 200 + 0.05 * 1000 = 240
        XCTAssertEqual(try XCTUnwrap(remaining), 230, accuracy: 0.0001)
    }

    func testEstimateCountsDownBetweenAdvancesInsteadOfSawtoothing() {
        var tracker = PhaseProgressTracker()
        tracker.record(completed: 20, total: 100, elapsed: 40) // pace: 200s total
        let atAdvance = try? XCTUnwrap(PhaseETA.remaining(elapsed: 40, historyTotal: nil, progress: tracker))
        let later = try? XCTUnwrap(PhaseETA.remaining(elapsed: 70, historyTotal: nil, progress: tracker))
        XCTAssertEqual(try XCTUnwrap(atAdvance), 160, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(later), 130, accuracy: 0.0001)
    }

    func testOverdueFallsBackToCurrentPaceRatherThanZero() {
        var tracker = PhaseProgressTracker()
        tracker.record(completed: 50, total: 100, elapsed: 50) // pace: 100s total
        // 120s in with nothing new: at the current pace the run needs 240s in all.
        let remaining = try? XCTUnwrap(PhaseETA.remaining(elapsed: 120, historyTotal: nil, progress: tracker))
        XCTAssertEqual(try XCTUnwrap(remaining), 120, accuracy: 0.0001)

        // No live progress and history exhausted: nothing better than "now".
        XCTAssertEqual(PhaseETA.remaining(elapsed: 120, historyTotal: 100, progress: PhaseProgressTracker()), 0)
    }

    func testMidBatchCompletionsDoNotDisturbHistoryEstimate() {
        // 39 chunks, 16 per batch, history predicts 190s. The first chunk of a
        // batch finishing early says nothing about throughput yet.
        var tracker = PhaseProgressTracker(batchSize: 16)
        tracker.record(completed: 1, total: 39, elapsed: 54)
        XCTAssertEqual(
            try XCTUnwrap(PhaseETA.remaining(elapsed: 54, historyTotal: 190, progress: tracker)),
            136,
            accuracy: 0.0001
        )
        // With no history at all the provisional pace is still used.
        XCTAssertEqual(
            try XCTUnwrap(PhaseETA.remaining(elapsed: 54, historyTotal: nil, progress: tracker)),
            54 * 39 - 54,
            accuracy: 0.0001
        )
        // The batch boundary is a real sample and takes over (fraction 16/39 > 0.2).
        tracker.record(completed: 16, total: 39, elapsed: 77)
        let total = 77.0 / (16.0 / 39.0)
        XCTAssertEqual(
            try XCTUnwrap(PhaseETA.remaining(elapsed: 77, historyTotal: 190, progress: tracker)),
            total - 77,
            accuracy: 0.0001
        )
    }

    func testBatchBoundarySampleIsKeptOverMidBatchCompletions() {
        // 24 chunks decoded 16 at a time: the first batch lands together at 78s.
        var tracker = PhaseProgressTracker(batchSize: 16)
        tracker.record(completed: 1, total: 24, elapsed: 46)
        XCTAssertEqual(try XCTUnwrap(tracker.paceEstimatedTotal), 46 * 24, accuracy: 0.0001)
        tracker.record(completed: 16, total: 24, elapsed: 78)
        XCTAssertEqual(try XCTUnwrap(tracker.paceEstimatedTotal), 117, accuracy: 0.0001)
        // A single early finisher from the second batch must not push the estimate back up.
        tracker.record(completed: 17, total: 24, elapsed: 103)
        XCTAssertEqual(try XCTUnwrap(tracker.paceEstimatedTotal), 117, accuracy: 0.0001)
        XCTAssertEqual(tracker.completedUnits, 17)
        // Completion always counts as a boundary.
        tracker.record(completed: 24, total: 24, elapsed: 120)
        XCTAssertEqual(try XCTUnwrap(tracker.paceEstimatedTotal), 120, accuracy: 0.0001)
    }

    func testTrackerIgnoresRegressionsAndKeepsTotals() {
        var tracker = PhaseProgressTracker()
        tracker.record(completed: 10, total: 100, elapsed: 20)
        tracker.record(completed: 0, total: 0, elapsed: 25) // upstream reset
        tracker.record(completed: 5, total: 100, elapsed: 30) // stale sample
        XCTAssertEqual(tracker.completedUnits, 10)
        XCTAssertEqual(tracker.totalUnits, 100)
        XCTAssertEqual(tracker.elapsedAtLastAdvance, 20)
        XCTAssertEqual(tracker.fraction, 0.1, accuracy: 0.0001)

        tracker.record(fraction: 0.5, elapsed: 40)
        XCTAssertEqual(tracker.fraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(tracker.paceEstimatedTotal), 80, accuracy: 0.0001)
    }
}
