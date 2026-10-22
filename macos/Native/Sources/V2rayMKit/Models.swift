import Foundation

public struct APIEnvelope<Value: Decodable>: Decodable {
    public var success: Bool
    public var code: String?
    public var messageKey: String?
    public var data: Value?
}
public struct EmptyValue: Decodable {}
public struct SessionToken: Decodable { public var token: String }
public struct Health: Decodable { public var status: String }
public struct RuntimeStatus: Decodable {
    public var coreRunning: Bool
    public var currentProfileId: String?
    public var currentProfileName: String?
    public var runningProfileName: String?
    public var runningProfileId: String?
    public var coreStartedAt: String?
    public var statisticsEnabled: Bool?
    public var installedXrayVersion: String?
    public var trafficEnabled: Bool?
    public var traffic: RuntimeTraffic?
    public var xrayAvailable: Bool
    public var runtimeState: String
    public var configuredProxyPort: Int?
    public var runningProxyPort: Int?
    public var runtimeFailure: String?
    public var capabilities: [String]?
    public var coreProcessIds: [Int32]?
}
public struct Profile: Decodable, Identifiable {
    public var id: String { indexId }
    public var indexId: String
    public var remarks: String
    public var `protocol`: String
    public var address: String
    public var port: Int
    public var network: String
    public var streamSecurity: String?
    public var subscriptionId: String?
    public var subscriptionName: String?
    public var coreType: String
    public var delay: Int
    public var isCurrent: Bool
    public var totalUp: Double?
    public var totalDown: Double?
    public var canTest: Bool
}
public struct Subscription: Codable, Identifiable {
    public var id: String
    public var remarks: String
    public var url: String
    public var enabled: Bool
    public var moreUrl: String?
    public var filter: String?
    public var autoUpdateInterval: Int
    public var updateTime: Int64
    public var userAgent: String
    public var requestHeaders: String?
    public var convertTarget: String?
    public var memo: String?
    public var sort: Int
    public var prevProfile: String?
    public var nextProfile: String?
    public var preSocksPort: Int?
    public var customCoreType: String?
}
/// Editing the basic fields retains the upstream subscription's advanced options.
public struct SubscriptionInput: Encodable {
    public var remarks: String
    public var url: String
    public var enabled: Bool
    public var moreUrl: String?
    public var filter: String?
    public var autoUpdateInterval: Int
    public var userAgent: String?
    public var requestHeaders: String?
    public var convertTarget: String?
    public var memo: String?
    public var sort: Int?
    public var prevProfile: String?
    public var nextProfile: String?
    public var preSocksPort: Int?
    public var customCoreType: String?
    public init(name: String, url: String, enabled: Bool = true, existing: Subscription? = nil) {
        remarks = name; self.url = url; self.enabled = enabled
        moreUrl = existing?.moreUrl; filter = existing?.filter
        autoUpdateInterval = existing?.autoUpdateInterval ?? 0
        userAgent = existing?.userAgent; requestHeaders = existing?.requestHeaders
        convertTarget = existing?.convertTarget; memo = existing?.memo; sort = existing?.sort
        prevProfile = existing?.prevProfile; nextProfile = existing?.nextProfile
        preSocksPort = existing?.preSocksPort; customCoreType = existing?.customCoreType
    }
}
public struct ImportInput: Encodable {
    public var content: String
    public var subscriptionId: String
    public init(content: String, subscriptionId: String = "") {
        self.content = content; self.subscriptionId = subscriptionId
    }
}
public struct ProfileIDs: Encodable {
    public var profileIds: [String]
    public init(_ ids: [String]) { profileIds = ids }
}
public struct LogEntry: Decodable, Identifiable {
    public var timestamp: String
    public var source: String
    public var message: String
    public var sequence: Int64?
    public var id: String { timestamp + "|" + (sequence.map(String.init) ?? "") + "|" + source + message }
    public var displayMessage: String { message.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") }
}
public struct LogTail: Decodable {
    public var items: [LogEntry]
    public var latestSequence: Int64
    public var generation: Int64
}
public struct RoutingProfile: Decodable, Identifiable {
    public var id: String
    public var remarks: String
    public var isActive: Bool
}
public struct ClientFailure: LocalizedError {
    public var code: String
    public var detail: String?
    public init(_ code: String, _ detail: String? = nil) { self.code = code; self.detail = detail }
    public var errorDescription: String? {
        let messages = [
            "inbound_lan_credentials_invalid": "独立局域网端口的用户名和密码需要同时填写，或同时留空。",
            "xray_only_profile_required": "此版本只支持 Xray，请选择 Xray 支持的节点。",
            "profile_validation_failed": "节点参数无效，请检查地址、端口和身份验证参数。",
            "profile_saved_core_restart_failed": "节点已保存，但重启代理失败。请修正配置后重新开启代理。",
            "core_binary_missing": "缺少代理内核，请在设置中安装 Xray。",
            "profile_not_selected": "请先导入或选择一个节点。",
            "profile_not_found": "节点已不存在，请刷新列表。",
            "profile_import_empty": "没有识别到有效节点，请检查分享链接或配置。",
            "proxy_port_in_use": "代理端口已被其他程序占用。",
            "core_start_failed": "代理内核启动失败，请查看日志。",
            "tun_not_supported": "当前配置启用了 TUN，请先关闭 TUN。",
            "mac_tun_helper_unavailable": "TUN 后台服务尚未就绪，请在“设置 → TUN”中安装并授权后台服务。",
            "tun_approval_required": "请在系统设置中允许 v2rayM 的后台服务，然后重新开启 TUN。",
            "tun_conflict": "检测到其他软件正在使用 TUN。请先暂停 v2rayN 或其他 VPN，再开启 v2rayM 的 TUN。",
            "tun_route_check_failed": "暂时无法确认当前网络路由，请检查网络连接后重试。",
            "tun_rollback_failed": "TUN 启动失败，且未能恢复原模式。请先关闭 TUN，再重试连接。",
            "tun_stop_unconfirmed": "尚未确认 TUN 内核已完全停止，请检查日志后重试退出。",
            "mac_tun_generated_core_required": "当前节点配置不支持 Xray 原生 TUN，请选择使用 Xray 的节点。",
            "mac_tun_apply_failed": "TUN 模式切换失败，请查看日志并检查当前连接状态。",
            "mac_tun_settings_invalid": "MTU 必须为 1280–65535，排除网段须为有效 CIDR，最多 128 项。",
            "subscription_update_busy": "已有订阅更新正在执行。",
            "subscription_invalid_url": "请输入有效的 HTTP 或 HTTPS 订阅地址。",
            "unauthorized": "本地服务会话失效，请重新连接。",
            "backend_missing": "应用内缺少后端，请使用打包脚本构建应用。",
            "backend_identity": "本地端口被其他实例占用，已停止连接。",
            "backend_exited": "本地服务已退出，请重新连接。",
            "backend_timeout": "本地服务启动超时。",
            "backend_stop_timeout": "本地服务尚未完成退出，请稍后重试。",
            "proxy_authorization": "未获得修改系统代理的授权。",
            "proxy_configuration": "系统代理设置未能保存，请重试。",
            "proxy_changed": "系统代理已被其他程序修改，已保留它的设置。",
            "proxy_no_services": "未找到可用的网络服务。",
            "proxy_recovery": "上次的系统代理设置需要恢复，请先关闭系统代理。",
        ]
        return messages[code] ?? detail ?? "操作失败（\(code)），请查看日志。"
    }
}
