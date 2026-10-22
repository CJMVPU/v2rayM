import Foundation

public struct RuntimeTraffic: Decodable {
    public var proxyUp: Double
    public var proxyDown: Double
    public var directUp: Double
    public var directDown: Double
    public var sampleSeconds: Double?
    public var sampledAt: String?
    public func rates(at now: Date) -> [Double]? {
        guard let date = DashboardStatus.date(sampledAt), now.timeIntervalSince(date) >= -2,
              now.timeIntervalSince(date) < 6, let seconds = sampleSeconds,
              seconds.isFinite, seconds > 0 else { return nil }
        let values = [proxyUp, proxyDown, directUp, directDown]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        return values.map { $0 / seconds }
    }
}

public enum DashboardStatus: Equatable {
    case offline, updating, changing, faulted, stale, tun, system, local, stopped
    public static func resolve(ready: Bool, updating: Bool, busy: Bool, recovery: Bool,
                               state: RuntimeStatus?, tunRunning: Bool, systemProxy: Bool,
                               lastRefresh: Date?, now: Date) -> Self {
        if !ready { return .offline }
        if updating { return .updating }
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
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
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
        if [.stale, .faulted, .changing, .updating].contains(state) { return "等待状态恢复" }
        return hasSample ? "正在采集 · 每秒刷新" : "等待有效采样"
    }
    public static func amount(_ kib: Double?) -> String {
        guard let kib, kib.isFinite, kib >= 0 else { return "—" }
        if kib >= 1048576 { return String(format: "%.2f GiB", kib / 1048576) }
        if kib >= 1024 { return String(format: "%.1f MiB", kib / 1024) }
        return String(format: "%.1f KiB", kib)
    }
    public static func rate(_ kib: Double?) -> String {
        guard let kib, kib.isFinite, kib >= 0 else { return "—" }
        return kib >= 1024 ? String(format: "%.1f MiB/s", kib / 1024) : String(format: "%.1f KiB/s", kib)
    }
}
