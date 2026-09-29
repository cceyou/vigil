import Foundation

/// How well past estimates matched reality. A turn is scored on the earliest checkpoint that had an estimate
/// (25 %, else 50 %, else 75 %): the early estimate is the one that matters and the hardest to get right.
public enum EtaAccuracy {
    public enum Verdict: Equatable, Sendable {
        /// The actual active duration fell inside the range.
        case hit
        /// Took longer than the top of the range, by this much.
        case over(TimeInterval)
        /// Finished before the bottom of the range, by this much.
        case under(TimeInterval)
        /// No estimate was shown during the turn.
        case noEstimate
    }

    public enum Trend: Equatable, Sendable {
        case improving(previous: TimeInterval)
        case worsening(previous: TimeInterval)
        case steady(previous: TimeInterval)
        case notEnoughData
    }

    public struct Summary: Equatable, Sendable {
        /// Mean |actual − likely| over the last `scored` turns with an estimate.
        public var meanError: TimeInterval?
        public var hits: Int
        public var scored: Int
        public var trend: Trend
    }

    public static let window = 20
    /// Turns per week needed before a trend is shown.
    public static let minimumPerWeek = 3

    public static func checkpoint(_ r: TurnRecord) -> EtaCheckpoint? {
        r.checkpoints.sorted { $0.fraction < $1.fraction }.first
    }

    public static func verdict(_ r: TurnRecord) -> Verdict {
        guard let c = checkpoint(r) else { return .noEstimate }
        if r.activeDuration > c.high { return .over(r.activeDuration - c.high) }
        if r.activeDuration < c.low { return .under(c.low - r.activeDuration) }
        return .hit
    }

    public static func error(_ r: TurnRecord) -> TimeInterval? {
        checkpoint(r).map { abs(r.activeDuration - $0.likely) }
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// `records` newest first (as stored).
    public static func summary(_ records: [TurnRecord], now: Date) -> Summary {
        let scored = records.filter { checkpoint($0) != nil }
        let recent = Array(scored.prefix(window))
        let hits = recent.filter { verdict($0) == .hit }.count

        let week: TimeInterval = 7 * 24 * 3600
        let thisWeek = scored.filter { now.timeIntervalSince($0.startedAt) < week }.compactMap(error)
        let lastWeek = scored.filter { (week..<(2 * week)).contains(now.timeIntervalSince($0.startedAt)) }.compactMap(error)
        let trend: Trend
        if thisWeek.count >= minimumPerWeek, lastWeek.count >= minimumPerWeek,
           let now = mean(thisWeek), let before = mean(lastWeek) {
            if now < before * 0.85 { trend = .improving(previous: before) }
            else if now > before * 1.15 { trend = .worsening(previous: before) }
            else { trend = .steady(previous: before) }
        } else {
            trend = .notEnoughData
        }
        return Summary(meanError: mean(recent.compactMap(error)), hits: hits, scored: recent.count, trend: trend)
    }
}
