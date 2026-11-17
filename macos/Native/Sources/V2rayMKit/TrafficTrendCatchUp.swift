import Foundation

/// Presentation-only history. Stored samples and live statistics are never changed.
public struct TrafficTrendCatchUp: Equatable, Sendable {
    public let startedAt: Date
    public let from: Date
    public let target: Date
    public let duration: TimeInterval
    public let samples: [TrafficTrendSample]
    public let initialCeiling: Double
    private let followsClock: Bool

    public init?(previous: TrafficTrend, displayedAt: Date, latest: TrafficTrend,
                 resumedAt: Date, retained: [TrafficTrendSample] = []) {
        let from = previous.displayDate(at: displayedAt)
        let target = latest.displayDate(at: resumedAt)
        self.from = from; self.target = target
        guard target.timeIntervalSince(from) > 0.15 else { return nil }
        startedAt = resumedAt
        followsClock = latest.pausedAt == nil
        samples = Self.merge(retained + previous.samples, latest.samples)
        let missed = samples.filter { $0.date > from && $0.date <= target }.count
        // A long absence must not create minutes of replay or unbounded work.
        duration = min(2.4, max(0.65, 0.55 + Double(missed) * 0.045))
        initialCeiling = max(1, (previous.plotSamples(at: from).map(\.maximum).max() ?? 0) * 1.12)
    }

    public func progress(at wallDate: Date) -> Double {
        let t = min(1, max(0, wallDate.timeIntervalSince(startedAt) / duration))
        return t * t * (3 - 2 * t)
    }

    public func displayDate(at wallDate: Date) -> Date {
        let elapsed = max(0, wallDate.timeIntervalSince(startedAt))
        return from.addingTimeInterval(target.timeIntervalSince(from) * progress(at: wallDate)
                                      + (followsClock ? elapsed : 0))
    }

    public func merged(with latest: TrafficTrend) -> [TrafficTrendSample] {
        Self.merge(samples, latest.samples)
    }

    private static func merge(_ previous: [TrafficTrendSample], _ latest: [TrafficTrendSample]) -> [TrafficTrendSample] {
        var unique: [Date: TrafficTrendSample] = [:]
        for sample in previous + latest { unique[sample.date] = sample }
        // At most the frozen five-minute window plus the newest retained window.
        return Array(unique.values.sorted { $0.date < $1.date }.suffix(2048))
    }

    /// Keep the two clip-edge neighbours so curves scroll/reveal continuously.
    /// Segment IDs and gap limits prevent fabricated lines across missing data.
    public static func plotSamples(_ samples: [TrafficTrendSample], at date: Date) -> [TrafficTrendSample] {
        let cutoff = date.addingTimeInterval(-TrafficTrend.duration)
        let first = samples.firstIndex { $0.date >= cutoff } ?? samples.endIndex
        let end = samples.firstIndex { $0.date > date } ?? samples.endIndex
        guard first < end else { return [] }
        var lower = first, upper = end
        if first > 0, samples[first - 1].segment == samples[first].segment,
           samples[first].date.timeIntervalSince(samples[first - 1].date) < 12 { lower -= 1 }
        if end < samples.endIndex, samples[end - 1].segment == samples[end].segment,
           samples[end].date.timeIntervalSince(samples[end - 1].date) < 12 { upper += 1 }
        return Array(samples[lower..<upper])
    }
}
