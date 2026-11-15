import Foundation

import V2rayMDomain
import V2rayMApplication

public typealias RuntimeUpdateActivity = V2rayMDomain.RuntimeUpdateActivity
public typealias ModuleUpdateScope = V2rayMDomain.ModuleUpdateScope
public typealias NativeModuleUpdatePlan = V2rayMDomain.NativeModuleUpdatePlan
public typealias NativeModuleUpdateRuntime = V2rayMApplication.NativeModuleUpdateRuntime
public typealias NativeModuleUpdateService = V2rayMApplication.NativeModuleUpdateService

public struct ModuleUpdateProgress: Decodable, Identifiable, Equatable {
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
        isComplete && !success && (phase == "awaiting-validation" || detail?.hasPrefix("发现上游新版本 ") == true)
    }
    public var downloadFraction: Double? {
        guard let totalBytes, totalBytes > 0, let downloadedBytes else { return nil }
        return min(1, max(0, Double(downloadedBytes) / Double(totalBytes)))
    }
    public var phaseLabel: String {
        if isComplete && success, let detail,
           ["已安装同版本修复版，无需更新", "已安装较新修复版，无需更新"].contains(detail) { return detail }
        if awaitingCompatibilityValidation { return "等待验证后再替换内核" }
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
    public var plan: NativeModuleUpdatePlan {
        NativeModuleUpdatePlan(installableTargets: targets.filter(\.canInstall).map(\.coreType), useProxy: useProxy)
    }
    public var nativeTargets: [String] { plan.targets }
    public var input: Input { Input(plan) }
    public struct Input: Encodable {
        public init(_ plan: NativeModuleUpdatePlan) {
            selectedCoreTypes = plan.targets; preRelease = plan.preRelease
            useProxy = plan.useProxy; checkPreReleaseCoreTypes = plan.preReleaseTargets
        }
        public var selectedCoreTypes: [String]
        public var preRelease: Bool
        public var useProxy: Bool
        public var checkPreReleaseCoreTypes: [String]?
    }
}

extension ModuleUpdateScope {
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
