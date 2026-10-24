import Foundation

/// One cache owns expiry, including short-lived failures. Concurrent callers share a lookup.
public actor GlobeLookupCache {
    private struct Cached { let expires: Date; let place: GlobePlace?; let inserted: Date }
    private var cached: [String: Cached] = [:]
    private var pending: [String: Task<GlobePlace?, Never>] = [:]
    private let lookup: @Sendable (String) async -> GlobePlace?
    private let now: @Sendable () -> Date
    private let successTTL: TimeInterval
    private let failureTTL: TimeInterval
    private let capacity: Int
    public init(capacity: Int = 512, successTTL: TimeInterval = 3600, failureTTL: TimeInterval = 30,
                now: @escaping @Sendable () -> Date = { Date() },
                lookup: @escaping @Sendable (String) async -> GlobePlace?) {
        self.capacity = max(1, capacity); self.successTTL = successTTL; self.failureTTL = failureTTL
        self.now = now; self.lookup = lookup
    }
    public func resolve(_ host: String) async -> GlobePlace? {
        if let entry = cached[host], now() < entry.expires { return entry.place }
        if let task = pending[host] { return await task.value }
        let task = Task { await lookup(host) }
        pending[host] = task
        let place = await task.value
        pending[host] = nil
        let date = now()
        cached = cached.filter { $0.value.expires > date }
        if cached[host] == nil, cached.count >= capacity,
           let oldest = cached.min(by: { $0.value.inserted < $1.value.inserted })?.key {
            cached[oldest] = nil
        }
        cached[host] = Cached(expires: date.addingTimeInterval(place == nil ? failureTTL : successTTL), place: place, inserted: date)
        return place
    }
}
