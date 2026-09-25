import Foundation

/// Fraction-complete samples for one phase, kept so the remaining-time
/// estimate counts down smoothly between progress advances.
///
/// The pace estimate is taken only at the instant the fraction last advanced.
/// Recomputing `elapsed / fraction` on every redraw would make the ETA climb
/// while waiting for the next advance and drop back when it arrives, which is
/// what WhisperKit's batched chunk completions would otherwise produce.
struct PhaseProgressTracker: Equatable {
    /// Units processed concurrently in one batch (WhisperKit's
    /// `concurrentWorkerCount`), or 0 when units complete independently.
    ///
    /// A batch finishes together, so a count that is a multiple of the batch
    /// size is a clean throughput sample; counts in between lag the real work
    /// done and would make the estimate jump up whenever one unit completes.
    var batchSize: Int64 = 0

    private(set) var fraction: Double = 0
    private(set) var completedUnits: Int64 = 0
    private(set) var totalUnits: Int64 = 0
    /// Elapsed seconds since the phase started when the fraction last advanced.
    private(set) var elapsedAtLastAdvance: TimeInterval?
    private(set) var fractionAtLastAdvance: Double = 0
    /// Most recent advance that landed on a batch boundary (or completion).
    private(set) var elapsedAtLastBatchAdvance: TimeInterval?
    private(set) var fractionAtLastBatchAdvance: Double = 0

    init(batchSize: Int64 = 0) {
        self.batchSize = batchSize
    }

    var hasUnits: Bool { totalUnits > 0 }

    /// Record a fraction sample; samples that do not advance are ignored.
    mutating func record(fraction sample: Double, elapsed: TimeInterval) {
        let clamped = min(max(sample, 0), 1)
        guard clamped > fraction else { return }
        fraction = clamped
        elapsedAtLastAdvance = max(0, elapsed)
        fractionAtLastAdvance = clamped
    }

    /// Record completed/total work units (for example WhisperKit decoding
    /// windows). Counts never move backwards so a reset upstream cannot
    /// rewind the display.
    mutating func record(completed: Int64, total: Int64, elapsed: TimeInterval) {
        guard total > 0 else { return }
        totalUnits = max(totalUnits, total)
        let previousCompleted = completedUnits
        completedUnits = max(completedUnits, min(completed, totalUnits))
        record(fraction: Double(completedUnits) / Double(totalUnits), elapsed: elapsed)
        guard completedUnits > previousCompleted, batchSize > 0 else { return }
        if completedUnits == totalUnits || completedUnits % batchSize == 0 {
            elapsedAtLastBatchAdvance = max(0, elapsed)
            fractionAtLastBatchAdvance = fraction
        }
    }

    /// Mark every known unit done; the upstream `Progress` resets before the
    /// final count can be sampled.
    mutating func markComplete() {
        guard totalUnits > 0 else { return }
        completedUnits = totalUnits
        fraction = 1
    }

    /// Pace sample fit to blend with history: the last batch boundary when
    /// units complete in batches, otherwise the last advance. Nil until one exists.
    var trustedPace: (total: TimeInterval, fraction: Double)? {
        if batchSize > 0 {
            guard let elapsedAtLastBatchAdvance, fractionAtLastBatchAdvance > 0 else { return nil }
            return (elapsedAtLastBatchAdvance / fractionAtLastBatchAdvance, fractionAtLastBatchAdvance)
        }
        return provisionalPace
    }

    /// Pace from the most recent advance, even mid-batch. Pessimistic while a
    /// batch is in flight, but better than nothing when there is no history.
    var provisionalPace: (total: TimeInterval, fraction: Double)? {
        guard let elapsedAtLastAdvance, fractionAtLastAdvance > 0 else { return nil }
        return (elapsedAtLastAdvance / fractionAtLastAdvance, fractionAtLastAdvance)
    }

    /// Whole-phase duration implied by the best available pace sample.
    var paceEstimatedTotal: TimeInterval? {
        (trustedPace ?? provisionalPace)?.total
    }
}

/// Remaining-time estimate for a running phase that blends a history-based
/// prediction with the live pace observed so far.
enum PhaseETA {
    /// Completed fraction at which the live pace fully replaces history.
    static let fullTrustFraction = 0.2

    /// - Parameters:
    ///   - elapsed: Seconds since the phase started.
    ///   - historyTotal: Predicted whole-phase duration from prior runs, if any.
    ///   - progress: Live progress samples for the phase.
    /// - Returns: Estimated remaining seconds, or nil when nothing is known.
    static func remaining(
        elapsed: TimeInterval,
        historyTotal: TimeInterval?,
        progress: PhaseProgressTracker
    ) -> TimeInterval? {
        let total: TimeInterval
        switch (historyTotal, progress.trustedPace) {
        case (nil, nil):
            guard let provisional = progress.provisionalPace else { return nil }
            total = provisional.total
        case (let history?, nil):
            total = history
        case (nil, let live?):
            total = live.total
        case (let history?, let live?):
            let weight = min(1, live.fraction / fullTrustFraction)
            total = (1 - weight) * history + weight * live.total
        }

        let remaining = total - elapsed
        if remaining > 0 {
            return remaining
        }
        // Overdue: extrapolate from the current pace so the ETA keeps moving
        // instead of sticking at zero until the phase finishes.
        if progress.fraction > 0, progress.fraction < 1 {
            return max(0, elapsed / progress.fraction - elapsed)
        }
        return 0
    }
}
