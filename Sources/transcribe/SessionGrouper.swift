import Foundation

/// One audio file's metadata, used as input to gap-based session grouping.
/// `recordedAt` is the embedded recording timestamp (e.g. M4A creation_time);
/// `durationSeconds` is the AVAsset-probed duration. Either may be nil when
/// the container lacks the metadata or AVFoundation rejects the file —
/// missing data is treated conservatively (no session split at that boundary).
struct AudioClip: Equatable {
    let path: String
    let recordedAt: Date?
    let durationSeconds: Double?
}

/// One session of consecutive clips that the user likely recorded as a single
/// logical recording. Adjacent clips with a recorded-at gap larger than the
/// configured threshold land in separate sessions.
struct AudioSession: Equatable {
    let files: [String]
    /// Recorded-at of the first clip with metadata, for verbose logging.
    let recordedAt: Date?
}

enum SessionGrouper {
    /// Groups `clips` (in input order) into sessions, splitting at gaps
    /// greater than `maxGapSeconds` between (clip i end, clip i+1 start)
    /// where both `recordedAt` values and clip i's `durationSeconds` are
    /// available. Set `maxGapSeconds <= 0` to disable splitting.
    /// - Parameter logger: when supplied (verbose), emits one line per
    ///   adjacent pair with the gap and split decision.
    static func groupIntoSessions(
        _ clips: [AudioClip],
        maxGapSeconds: Double,
        logger: VerboseLogger? = nil
    ) -> [AudioSession] {
        guard !clips.isEmpty else { return [] }

        var sessions: [AudioSession] = []
        var current: [AudioClip] = [clips[0]]
        let splitDisabled = maxGapSeconds <= 0

        for i in 1..<clips.count {
            let prev = clips[i - 1]
            let curr = clips[i]
            let prevName = (prev.path as NSString).lastPathComponent
            let currName = (curr.path as NSString).lastPathComponent

            var split = false
            if !splitDisabled,
               let prevStart = prev.recordedAt,
               let prevDur = prev.durationSeconds,
               let currStart = curr.recordedAt {
                let prevEnd = prevStart.addingTimeInterval(prevDur)
                let gap = currStart.timeIntervalSince(prevEnd)
                if gap > maxGapSeconds {
                    split = true
                    logger?.log(
                        "gap: \(prevName) -> \(currName) = \(formatGap(gap))"
                        + " (>\(formatGap(maxGapSeconds)) threshold) -> new session"
                    )
                } else {
                    logger?.log("gap: \(prevName) -> \(currName) = \(formatGap(gap))")
                }
            } else {
                logger?.log(
                    "gap: \(prevName) -> \(currName) = unknown (missing metadata; same session)"
                )
            }

            if split {
                sessions.append(AudioSession(files: current.map(\.path), recordedAt: firstRecordedAt(current)))
                current = [curr]
            } else {
                current.append(curr)
            }
        }
        sessions.append(AudioSession(files: current.map(\.path), recordedAt: firstRecordedAt(current)))

        if let logger {
            let counts = sessions.map { String($0.files.count) }.joined(separator: ", ")
            logger.log("sessions: \(sessions.count) (\(counts) clip\(sessions.count == 1 ? "" : "s each"))")
        }

        return sessions
    }

    private static func firstRecordedAt(_ clips: [AudioClip]) -> Date? {
        clips.lazy.compactMap(\.recordedAt).first
    }

    private static func formatGap(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let absTotal = abs(total)
        let h = absTotal / 3600
        let m = (absTotal % 3600) / 60
        let s = absTotal % 60
        let sign = total < 0 ? "-" : ""
        if h > 0 {
            return "\(sign)\(h)h \(m)m \(s)s"
        }
        if m > 0 {
            return "\(sign)\(m)m \(s)s"
        }
        return "\(sign)\(s)s"
    }
}
