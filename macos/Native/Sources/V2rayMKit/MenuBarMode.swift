import Foundation

public enum MenuBarMode: Equatable {
    case inactive, system, tun, attention
    public init(_ state: DashboardStatus) {
        switch state {
        case .stopped: self = .inactive
        case .system: self = .system
        case .tun: self = .tun
        default: self = .attention
        }
    }
    public var label: String {
        switch self {
        case .inactive: return "代理未开启"
        case .system: return "系统代理运行中"
        case .tun: return "原生 TUN 运行中"
        case .attention: return "代理状态待确认"
        }
    }
}
