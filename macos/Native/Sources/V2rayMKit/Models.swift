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
    public var xrayAvailable: Bool
    public var runtimeState: String
    public var configuredProxyPort: Int?
    public var runningProxyPort: Int?
    public var runtimeFailure: String?
    public var capabilities: [String]?
}
public struct Profile: Decodable, Identifiable {
    public var id: String { indexId }
    public var indexId: String
    public var remarks: String
    public var `protocol`: String
    public var address: String
    public var port: Int
    public var network: String
    public var subscriptionId: String?
    public var subscriptionName: String?
    public var coreType: String
    public var delay: Int
    public var isCurrent: Bool
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
    public var id: String { timestamp + source + message }
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
            "core_binary_missing": "缺少代理内核，请在设置中安装 Xray。",
            "profile_not_selected": "请先导入或选择一个节点。",
            "profile_not_found": "节点已不存在，请刷新列表。",
            "profile_import_empty": "没有识别到有效节点，请检查分享链接或配置。",
            "proxy_port_in_use": "代理端口已被其他程序占用。",
            "core_start_failed": "代理内核启动失败，请查看日志。",
            "tun_not_supported": "当前配置启用了 TUN，请先关闭 TUN。",
            "mac_tun_helper_unavailable": "TUN 尚未授权，请使用普通代理模式。",
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
