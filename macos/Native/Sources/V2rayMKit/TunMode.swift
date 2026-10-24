import Foundation

public struct MacTunStatus: Decodable, Sendable, Equatable {
    public var platformSupported: Bool
    public var helperAvailable: Bool
    public var helperCode: String
    public var helperState: String
    public var enabled: Bool
    public var supportedCores: [String]
    public var coreSource: String
    public var runtimeState: String
    public var privilegedCoreProcessIds: [Int]

    public var isRunning: Bool { enabled && runtimeState == "running" && !privilegedCoreProcessIds.isEmpty }
    public var modeDescription: String {
        if !enabled { return "已关闭" }
        if isRunning { return "运行中" }
        if runtimeState == "faulted" { return "连接失败，请查看日志" }
        return "已启用，未连接"
    }
    public var helperDescription: String {
        if helperAvailable { return "已就绪" }
        switch helperCode {
        case "apple_team_signature_required", "signing_identity_missing": return "需要签名安装包"
        case "helper_protocol_mismatch": return "版本不匹配，请重新安装应用"
        default: return "未就绪，请检查授权"
        }
    }
}

public protocol TunBackend: Sendable {
    func tunStatus() async throws -> MacTunStatus
    func setTunEnabled(_ enabled: Bool) async throws
    func startTunCore() async throws
}

extension APIClient: TunBackend {
    public func tunStatus() async throws -> MacTunStatus { try await value("/api/macos/tun") }
    public func setTunEnabled(_ enabled: Bool) async throws {
        try await send("/api/macos/tun", method: "PUT", body: ["enabled": enabled])
    }
    public func startTunCore() async throws { try await perform("/api/core/start") }
}

public enum TunModeChange {
    public static func checkBeforeConnecting(backend: any TunBackend,
                                             checkOtherTunnel: @Sendable () async throws -> Void = { try await TunnelConflict.check() }) async throws {
        let state = try await backend.tunStatus()
        guard state.enabled else { return }
        guard state.helperAvailable else { throw ClientFailure("mac_tun_helper_unavailable") }
        if state.privilegedCoreProcessIds.isEmpty { try await checkOtherTunnel() }
    }


}

public enum TunnelConflict {
    public static func check() async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/sbin/route")
            process.arguments = ["-n", "get", "1.1.1.1"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ClientFailure("tun_route_check_failed") }
            let route = String(decoding: data, as: UTF8.self)
            if route.split(separator: "\n").contains(where: { line in
                let parts = line.split(whereSeparator: \.isWhitespace)
                return parts.count == 2 && parts[0] == "interface:" && parts[1].hasPrefix("utun")
            }) { throw ClientFailure("tun_conflict") }
        }.value
    }
}
