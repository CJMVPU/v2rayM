import Foundation

public struct RuntimeTraffic: Decodable, Equatable {
    public var proxyUp: Double
    public var proxyDown: Double
    public var directUp: Double
    public var directDown: Double
    public var sampleSeconds: Double?
    public var sampledAt: String?
    public func rates(at now: Date) -> [Double]? {
        guard let date = DashboardStatus.date(sampledAt), now.timeIntervalSince(date) >= -2,
              now.timeIntervalSince(date) < 12, let seconds = sampleSeconds,
              seconds.isFinite, seconds > 0 else { return nil }
        let values = [proxyUp, proxyDown, directUp, directDown]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        return values.map { $0 / seconds }
    }
}

public enum DashboardStatus: Equatable {
    case recovering, offline, updating, changing, faulted, stale, tun, system, local, stopped
    public static func resolve(ready: Bool, updating: Bool, busy: Bool, recovery: Bool,
                               state: RuntimeStatus?, tunRunning: Bool, systemProxy: Bool,
                               lastRefresh: Date?, now: Date, reconnecting: Bool = false) -> Self {
        if !ready { return .offline }
        if updating { return .updating }
        if reconnecting { return .recovering }
        if busy { return .changing }
        if recovery || state?.runtimeState == "faulted" { return .faulted }
        guard let lastRefresh, now.timeIntervalSince(lastRefresh) < 8 else { return .stale }
        guard state?.coreRunning == true else { return .stopped }
        if tunRunning { return .tun }
        if systemProxy { return .system }
        return .local
    }
    public var title: String {
        switch self {
        case .recovering: return "尝试恢复代理"
        case .offline: return "本地服务离线"
        case .updating: return "正在更新模块"
        case .changing: return "正在应用操作"
        case .faulted: return "代理需要检查"
        case .stale: return "正在确认状态"
        case .tun, .system: return "代理运行中"
        case .local: return "本地内核运行中"
        case .stopped: return "代理已关闭"
        }
    }
    public var active: Bool { self == .tun || self == .system }
    public static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date.ISO8601FormatStyle().parse(value))
    }
    public static func duration(since value: String?, now: Date) -> String {
        guard let start = date(value) else { return "—" }
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    public static func trafficDescription(state: DashboardStatus, enabled: Bool?, hasSample: Bool) -> String {
        if state == .offline { return "本地服务离线" }
        if enabled == false { return "流量采集未开启" }
        if state == .stopped { return "采集已开启 · 等待连接" }
        if [.recovering, .stale, .faulted, .changing, .updating].contains(state) { return "等待状态恢复" }
        return hasSample ? "5 秒采样 · 1 分钟均速" : "等待有效采样"
    }
    public static func amountParts(_ kib: Double?) -> DashboardMetricValue {
        guard let kib, kib.isFinite, kib >= 0 else { return .unavailable }
        if kib >= 1048576 { return DashboardMetricValue(kib / 1048576, unit: "GiB") }
        if kib >= 1024 { return DashboardMetricValue(kib / 1024, unit: "MiB") }
        return DashboardMetricValue(kib, unit: "KiB")
    }
    public static func rateParts(_ kib: Double?) -> DashboardMetricValue {
        guard let kib, kib.isFinite, kib >= 0 else { return .unavailable }
        return kib >= 1024 ? DashboardMetricValue(kib / 1024, unit: "MiB/s") : DashboardMetricValue(kib, unit: "KiB/s")
    }
    public static func amount(_ kib: Double?) -> String { amountParts(kib).text }
    public static func rate(_ kib: Double?) -> String { rateParts(kib).text }
}

public struct DashboardMetricValue: Equatable, Sendable {
    public let number: String
    public let unit: String
    public var text: String { unit.isEmpty ? number : number + " " + unit }
    public static let unavailable = Self(number: "—", unit: "")
    private init(number: String, unit: String) { self.number = number; self.unit = unit }
    public init(_ value: Double, unit: String) {
        number = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
        self.unit = unit
    }
}
