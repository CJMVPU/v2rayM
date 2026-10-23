import Foundation

public enum RuntimeUpdateActivity {
    public static func isActive(_ operations: [String]) -> Bool {
        operations.contains { $0.hasPrefix("core-update") || $0 == "geo-update" }
    }
}

public struct ModuleUpdateProgress: Decodable, Identifiable {
    public var id: String { coreType }
    public var coreType: String
    public var phase: String
    public var isComplete: Bool
    public var success: Bool
    public var version: String?
    public var detail: String?
    public var batch: Bool
    public var downloadedBytes: Int64?
    public var totalBytes: Int64?
    public var completedFiles: Int?
    public var totalFiles: Int?
    public var awaitingCompatibilityValidation: Bool {
        isComplete && !success && detail?.hasPrefix("发现上游新版本 ") == true
    }
    public var downloadFraction: Double? {
        guard let totalBytes, totalBytes > 0, let downloadedBytes else { return nil }
        return min(1, max(0, Double(downloadedBytes) / Double(totalBytes)))
    }
    public var phaseLabel: String {
        if isComplete && success, let detail,
           ["已安装同版本修复版，无需更新", "已安装较新修复版，无需更新"].contains(detail) { return detail }
        if awaitingCompatibilityValidation { return "等待兼容验证" }
        if isComplete { return success ? "已完成" : "更新失败" }
        switch phase {
        case "queued", "waiting": return "等待更新"
        case "checking": return "检查版本"
        case "downloading": return "下载中"
        case "verifying": return "校验文件与签名"
        case "staging-privileged": return "验证 TUN 官方发布包"
        case "stopping-core": return "停止旧内核"
        case "installing": return "替换内核文件"
        case "restarting-core": return "启动新内核"
        case "rolling-back": return "恢复旧版本"
        default: return "处理中"
        }
    }
}

public struct ModuleUpdateSettings: Codable {
    public struct Target: Codable {
        public var coreType: String
        public var canInstall: Bool
    }
    public var targets: [Target]
    public var preRelease: Bool
    public var useProxy: Bool
    public var checkPreReleaseCoreTypes: [String]?
    public var nativeTargets: [String] {
        targets.filter { $0.canInstall && ["Xray"].contains($0.coreType) }.map(\.coreType) + ["GeoFiles"]
    }
    public var input: Input { Input(selectedCoreTypes: nativeTargets, preRelease: true, useProxy: useProxy,
                                    checkPreReleaseCoreTypes: Array(Set(nativeTargets.filter { $0 != "GeoFiles" })).sorted()) }
    public struct Input: Encodable {
        public var selectedCoreTypes: [String]
        public var preRelease: Bool
        public var useProxy: Bool
        public var checkPreReleaseCoreTypes: [String]?
    }
}

public enum ModuleUpdateScope: String, CaseIterable, Identifiable {
    case xray, geo, all
    public var id: String { rawValue }
    public var coreType: String? {
        switch self { case .xray: return "Xray"; default: return nil }
    }
    public var targets: [String] { coreType.map { [$0] } ?? (self == .all ? ["Xray", "GeoFiles"] : ["GeoFiles"]) }
    public var buttonLabel: String {
        switch self { case .xray: return "更新 Xray"
        case .geo: return "更新 GeoIP/Site"; case .all: return "更新全部模块" }
    }
}

public enum ModuleUpdateNames {
    public static func label(_ id: String) -> String {
        switch id {
        case "GeoFiles": return "GeoIP / GeoSite"; default: return id }
    }
}
