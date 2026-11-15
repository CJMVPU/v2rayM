import Foundation

public struct TrafficTrendSample: Equatable, Identifiable, Sendable {
    public var id: Date { date }
    public let date: Date
    public let upload: Double
    public let download: Double
    public let segment: Int
}

/// Stores the backend's rolling-average samples, not invented instantaneous rates.
public struct TrafficTrend: Equatable, Sendable {
    public static let duration: TimeInterval = 300
    // Normal sampling is every five seconds, but restarts/shorter intervals must
    // not truncate a five-minute chart to a fixed 61 observations.
    private static let maximumSamples = 1024
    public private(set) var samples: [TrafficTrendSample] = []
    public private(set) var pausedAt: Date?
    public func displayDate(at now: Date) -> Date { pausedAt ?? now }
    private var session: String?
    private var segment = 0
    private var interrupted = false

    public init() {}

    public mutating func record(_ state: RuntimeStatus, now: Date) {
        guard state.coreRunning, state.trafficEnabled == true,
              let start = state.coreStartedAt, let profile = state.runningProfileId else {
            if pausedAt == nil { pausedAt = now }
            interrupted = true
            return
        }
        pausedAt = nil
        let cutoff = now.addingTimeInterval(-Self.duration)
        if let first = samples.firstIndex(where: { $0.date >= cutoff }) {
            // Keep one predecessor for the curve crossing the left clip edge.
            samples.removeFirst(max(0, first - 1))
        } else { samples.removeAll(keepingCapacity: true) }
        let identity = profile + "|" + start
        if session != identity {
            // The chart belongs to the app, not an individual core session.
            // Retain recent history, but never join lines across restarts or nodes.
            session = identity
            interrupted = true
        }
        guard let traffic = state.traffic, let rates = traffic.rates(at: now),
              rates.allSatisfy({ $0.isFinite && $0 >= 0 }),
              let date = DashboardStatus.date(traffic.sampledAt),
              let started = DashboardStatus.date(start), date >= started else {
            interrupted = true
            return
        }
        if let last = samples.last {
            guard date > last.date else { return } // Polling is faster than sampling.
            if interrupted || date.timeIntervalSince(last.date) >= 12 { segment += 1 }
        }
        interrupted = false
        samples.append(TrafficTrendSample(date: date, upload: rates[0], download: rates[1], segment: segment))
        if samples.count > Self.maximumSamples { samples.removeFirst(samples.count - Self.maximumSamples) }
    }

    /// Directional maxima of the existing five-second samples in (now - 60s, now].
    public func peaks(at now: Date) -> [Double] {
        let now = displayDate(at: now)
        let recent = samples.filter { $0.date <= now && now.timeIntervalSince($0.date) < 60 }
        return [recent.map(\.upload).max() ?? 0, recent.map(\.download).max() ?? 0]
    }

    public func visible(at now: Date) -> [TrafficTrendSample] {
        let now = displayDate(at: now)
        return samples.filter { now.timeIntervalSince($0.date) <= Self.duration && $0.date <= now }
    }

    /// Geometry may start outside the clip rectangle. Statistics continue to use
    /// only in-window samples; never bridge a missing interval or another session.
    public func plotSamples(at now: Date) -> [TrafficTrendSample] {
        let points = visible(at: now)
        guard let first = points.first, let index = samples.firstIndex(where: { $0.id == first.id }), index > 0 else { return points }
        let predecessor = samples[index - 1]
        guard predecessor.segment == first.segment,
              first.date.timeIntervalSince(predecessor.date) < 12 else { return points }
        return [predecessor] + points
    }
}

/// A presentation-only snapshot: expired points never return to live statistics.
public struct TrafficTrendRetirement: Sendable {
    public static let duration: TimeInterval = 1.2
    public let samples: [TrafficTrendSample]
    public let displayDate: Date
    public let startedAt: Date
    public let ceiling: Double

    public init?(previous: TrafficTrend, resumedAt: Date) {
        guard let paused = previous.pausedAt else { return nil }
        let points = previous.plotSamples(at: paused)
        guard points.contains(where: { resumedAt.timeIntervalSince($0.date) > TrafficTrend.duration }) else { return nil }
        samples = points
        displayDate = paused
        startedAt = resumedAt
        ceiling = max(1, (points.map { max($0.upload, $0.download) }.max() ?? 0) * 1.12)
    }

    public func progress(at date: Date) -> Double {
        let t = min(1, max(0, date.timeIntervalSince(startedAt) / Self.duration))
        return t * t * (3 - 2 * t)
    }
}
