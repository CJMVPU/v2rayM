import Foundation

import V2rayMDomain
import V2rayMApplication

public typealias RuntimeUpdateActivity = V2rayMDomain.RuntimeUpdateActivity
public typealias NativeModuleUpdateRuntime = V2rayMApplication.NativeModuleUpdateRuntime
public typealias NativeModuleUpdateService = V2rayMApplication.NativeModuleUpdateService

public struct ModuleUpdateProgress: Identifiable, Equatable, Sendable {
    public var id: String { coreType }
    public var coreType = "GeoFiles"
    public var phase: String
    public var isComplete = false
    public var success = false
    public var version: String?
    public var detail: String?
    public var batch = false
    public var downloadedBytes: Int64?
    public var totalBytes: Int64?
    public var completedFiles: Int?
    public var totalFiles: Int?
    public var awaitingCompatibilityValidation: Bool {
        isComplete && !success && (phase == "awaiting-validation" || detail?.hasPrefix("发现上游新版本 ") == true)
    }
    public var downloadFraction: Double? {
        let current = totalBytes.flatMap { total in
            total > 0 ? downloadedBytes.map { min(1, max(0, Double($0) / Double(total))) } : nil
        }
        guard let totalFiles, totalFiles > 0, let completedFiles else { return current }
        guard current != nil || completedFiles > 0 else { return nil }
        return min(1, (Double(max(0, completedFiles)) + (current ?? 0)) / Double(totalFiles))
    }
    public var phaseLabel: String {
        if isComplete && success, let detail,
           ["已安装同版本修复版，无需更新", "已安装较新修复版，无需更新"].contains(detail) { return detail }
        if awaitingCompatibilityValidation { return "等待验证后再替换内核" }
        if isComplete { return success ? "已完成" : "更新失败" }
        switch phase {
        case "queued", "waiting": return "等待更新"
        case "checking": return "检查版本"
        case "waiting-to-apply": return "等待应用规则"
        case "downloading":
            guard coreType == "GeoFiles", let completedFiles, let totalFiles, totalFiles > 0 else { return "下载中" }
            if completedFiles >= totalFiles { return "下载完成" }
            let file = "下载 \(max(0, completedFiles) + 1)/\(totalFiles)"
            guard totalBytes.map({ $0 <= 0 }) ?? true, let downloadedBytes else { return file }
            return file + " · " + ByteCountFormatter.string(fromByteCount: max(0, downloadedBytes), countStyle: .file)
        case "verifying": return coreType == "GeoFiles" ? "校验分流规则数据" : "校验文件与签名"
        case "staging-privileged": return "验证 TUN 官方发布包"
        case "stopping-core": return "停止旧内核"
        case "installing": return "替换内核文件"
        case "restarting-core": return "启动新内核"
        case "rolling-back": return "恢复旧版本"
        default: return "处理中"
        }
    }
}
