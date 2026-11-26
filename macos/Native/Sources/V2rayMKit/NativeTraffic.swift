import Foundation

actor NativeTrafficSampler {
    let store: NativeConfigurationStore
    let nodeID: String
    private let counters: @Sendable () async -> [Int64]?
    private var task: Task<Void, Never>?
    private var enabled: Bool
    private var last = [Int64](repeating: 0, count: 4)
    private var lastRead = Date()
    private struct Sample { let at: Date; let seconds: Double; let amounts: [Int64] }
    private var window = [Sample]()
    private let timestamps: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(store: NativeConfigurationStore, nodeID: String, statistics: Bool,
         counters: @escaping @Sendable () async -> [Int64]?) {
        self.store = store
        self.nodeID = nodeID
        self.counters = counters
        enabled = statistics
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await self?.sample()
            }
        }
    }

    private func pause() async {
        task?.cancel()
        await task?.value
        task = nil
    }

    func stop(flush: Bool) async {
        await pause()
        if flush { await sample() }
    }

    func setStatistics(_ value: Bool) async {
        guard enabled != value else { return }
        await pause()
        // Close the previous accounting interval before changing whether its bytes are persisted.
        let sampled = await sample()
        if !sampled && value { discardBaseline = true }
        enabled = value
        start()
    }

    private var discardBaseline = false

    @discardableResult private func sample() async -> Bool {
        do {
            guard let current = await counters(), !Task.isCancelled else { return false }
            let now = Date(), seconds = now.timeIntervalSince(lastRead)
            let delta = zip(current, last).map(-)
            if delta.contains(where: { $0 < 0 }) || discardBaseline {
                discardBaseline = false
                window.removeAll()
            } else {
                if enabled && (delta[0] != 0 || delta[1] != 0) {
                    try await store.addTraffic(nodeID: nodeID, up: delta[0], down: delta[1], date: now)
                }
                window.removeAll { now.timeIntervalSince($0.at) >= 60 }
                if seconds > 0 && seconds <= 15 {
                    window.append(Sample(at: now, seconds: seconds, amounts: delta))
                } else { window.removeAll() }
            }
            lastRead = now
            last = current
            return true
        } catch { return false }
    }

    func snapshot(at now: Date) -> RuntimeTraffic? {
        guard let end = window.last?.at, (-2..<12).contains(now.timeIntervalSince(end)) else { return nil }
        let start = end.addingTimeInterval(-60)
        var totals = [Double](repeating: 0, count: 4)
        var duration = 0.0
        for sample in window {
            let overlap = min(sample.seconds, sample.at.timeIntervalSince(start))
            guard overlap > 0 else { continue }
            duration += overlap
            for index in totals.indices { totals[index] += Double(sample.amounts[index]) * overlap / sample.seconds }
        }
        guard duration > 0 else { return nil }
        return RuntimeTraffic(proxyUp: totals[0], proxyDown: totals[1], directUp: totals[2], directDown: totals[3],
                              sampleSeconds: duration, sampledAt: timestamps.string(from: end))
    }
}

extension NativeConfigurationStore {
    /// A node can stay idle for days. Scope its daily counters at read time without resetting its totals.
    static let datedTrafficRelation = """
        (SELECT IndexId, TotalUp, TotalDown,
                CASE WHEN DateNow=?1 THEN TodayUp ELSE 0 END AS TodayUp,
                CASE WHEN DateNow=?1 THEN TodayDown ELSE 0 END AS TodayDown
         FROM ServerStatItem)
        """

    static func statisticsDayTicks(_ date: Date) throws -> Int64 {
        // DateTime.Now.Date.Ticks in legacy ServerStatItem is a local Gregorian calendar date.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let localDay = calendar.dateComponents([.year, .month, .day], from: date)
        calendar.timeZone = .gmt
        guard let midnight = calendar.date(from: localDay) else { throw ClientFailure("statistics_date_invalid") }
        return Int64(midnight.timeIntervalSince1970) * 10_000_000 + 621355968000000000
    }

    func addTraffic(nodeID: String, up: Int64, down: Int64, date: Date) throws {
        let ticks = try Self.statisticsDayTicks(date)
        let db = try RuntimeDatabase(url: databaseURL, writable: true)
        _ = try db.query("""
            INSERT INTO ServerStatItem (IndexId, TotalUp, TotalDown, TodayUp, TodayDown, DateNow)
            SELECT IndexId, ?, ?, ?, ?, ? FROM ProfileItem WHERE IndexId=?
            ON CONFLICT(IndexId) DO UPDATE SET
                TotalUp=COALESCE(TotalUp,0)+excluded.TotalUp, TotalDown=COALESCE(TotalDown,0)+excluded.TotalDown,
                TodayUp=(CASE WHEN DateNow=excluded.DateNow THEN COALESCE(TodayUp,0) ELSE 0 END)+excluded.TodayUp,
                TodayDown=(CASE WHEN DateNow=excluded.DateNow THEN COALESCE(TodayDown,0) ELSE 0 END)+excluded.TodayDown,
                DateNow=excluded.DateNow
            """, [.integer(up), .integer(down), .integer(up), .integer(down), .integer(ticks), .text(nodeID)])
    }
}
