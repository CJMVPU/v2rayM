import Foundation

/// A frozen viewport for returning to the dashboard. Its dates stay fixed while
/// the renderer blends directly to the latest viewport on its own time axis.
public struct TrafficTrendCatchUp: Equatable, Sendable {
    public static let duration: TimeInterval = 0.45
    public let startedAt: Date
    public let displayDate: Date
    public let samples: [TrafficTrendSample]
    public let ceiling: Double

    public init(previous: TrafficTrend, displayedAt: Date, resumedAt: Date) {
        startedAt = resumedAt
        displayDate = previous.displayDate(at: displayedAt)
        samples = previous.plotSamples(at: displayDate)
        ceiling = max(1, (samples.map(\.maximum).max() ?? 0) * 1.12)
    }

    public init(holding previous: Self, resumedAt: Date) {
        startedAt = resumedAt
        displayDate = previous.displayDate
        samples = previous.samples
        ceiling = previous.ceiling
    }

    public static func progress(after seconds: TimeInterval) -> Double {
        let value = min(1, max(0, seconds / duration))
        return value * value * (3 - 2 * value)
    }
}
