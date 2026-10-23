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
    public private(set) var samples: [TrafficTrendSample] = []
    private var session: String?
    private var segment = 0
    private var interrupted = false

    public init() {}

    public mutating func record(_ state: RuntimeStatus, now: Date) {
        samples.removeAll { now.timeIntervalSince($0.date) > Self.duration }
        guard state.coreRunning, state.trafficEnabled == true,
              let start = state.coreStartedAt, let profile = state.runningProfileId else {
            interrupted = true
            return
        }
        let identity = profile + "|" + start
        if session != identity {
            samples.removeAll(keepingCapacity: true)
            session = identity
            segment = 0
            interrupted = false
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
        if samples.count > 61 { samples.removeFirst(samples.count - 61) }
    }

    /// Directional maxima of the existing five-second samples in (now - 60s, now].
    public func peaks(at now: Date) -> [Double] {
        let recent = samples.filter { $0.date <= now && now.timeIntervalSince($0.date) < 60 }
        return [recent.map(\.upload).max() ?? 0, recent.map(\.download).max() ?? 0]
    }

    public func visible(at now: Date) -> [TrafficTrendSample] {
        samples.filter { now.timeIntervalSince($0.date) <= Self.duration && $0.date <= now }
    }
}
