// Operator acceptance runs in the signed application so XPC authenticates the real caller.
import AppKit
import Foundation
import V2rayMKit

enum TunAcceptance {
    private static func reply<T: Encodable>(_ value: T) throws {
        let json = try JSONEncoder().encode(value)
        FileHandle.standardOutput.write(Data("V2M-CHECK ".utf8) + json + Data([10]))
    }

    @MainActor private static func confirmNetworkTest() -> Bool {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "开始本机 TUN 验收？"
        alert.informativeText = "签名的 v2rayM 将用节点副本临时接管系统路由和 DNS，并测试重新连接。请先退出其他 VPN。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "开始验收")
        return alert.runModal() == .alertSecondButtonReturn
    }

    static func run() async -> Int32 {
        // Create our own empty directory. The operator's driver can populate it only after this handshake.
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("v2raym-acceptance-" + UUID().uuidString)
        do {
            guard getuid() != 0, isatty(STDIN_FILENO) == 0 else {
                throw ClientFailure("acceptance_requires_user_and_pipe")
            }
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: data) }
            let allowTun = Array(CommandLine.arguments.dropFirst()) == ["--tun-acceptance", "--allow-tun"]
            let host = NativeRuntimeHost(dataDirectory: data, mayContactHelper: allowTun, automaticMaintenance: false)
            if allowTun {
                guard await confirmNetworkTest() else { throw ClientFailure("acceptance_cancelled") }
            }
            try reply(["directory": data.path])
            do {
                for try await command in FileHandle.standardInput.bytes.lines {
                    do {
                        if command == "quit" { break }
                        if command == "open" {
                            _ = try await host.startClient()
                            try reply(["pid": getpid()])
                            continue
                        }
                        guard await host.isRunning else { throw ClientFailure("backend_exited") }
                        switch command {
                        case "status": try await reply(host.runtimeStatus())
                        case "helper":
                            let status: MacTunStatus = try await host.value("/api/macos/tun?fresh=true&verifyHelper=true")
                            try reply(status)
                        case "logs": try await reply(host.logTail(after: 0, limit: 10000))
                        case "start-tun":
                            guard allowTun else { throw ClientFailure("acceptance_network_disabled") }
                            try await host.setTunEnabled(true)
                            try await host.startTunCore()
                            try reply(true)
                        case "stop":
                            try await host.stopProxyCore()
                            try await host.setTunEnabled(false)
                            try reply(true)
                        default: throw ClientFailure("unknown_acceptance_command")
                        }
                    } catch { try reply(["error": error.localizedDescription]) }
                }
            } catch {
                try await host.stop()
                throw error
            }
            try await host.stop()
            return 0
        } catch {
            try? reply(["error": error.localizedDescription])
            return 1
        }
    }
}
