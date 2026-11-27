import Foundation
import V2rayMKit

extension NativeCheck {
    static func checkBackupFixture(_ api: NativeRuntimeHost, server: Int, proxy: Int) async throws {
        let destination: SettingsValue = .object(["url": .string("http://127.0.0.1:" + String(server) + "/dav"),
            "dirName": .string("fixture"), "userName": .string("fixture"), "password": .string("local-only")])
        try await api.saveSettings(.webDAV, destination)
        try await api.checkWebDAV()
        let rule: SettingsValue = .object(["remarks": .string("Backup fixture"), "ruleSet": .string("[{\"port\":\"1-65535\",\"outboundTag\":\"proxy\"}]")])
        let routeID = try await api.saveRoute(id: nil, rule)
        try await api.activateRoute(routeID)
        let before: RuntimeStatus = try await api.runtimeStatus()
        guard let nodeID = before.runningProfileId else { throw ClientFailure("fixture_node_missing") }
        let node = try await api.profileDocument(id: nodeID)
        try await api.uploadBackup()
        var edit = node
        edit["remarks"] = .string("after backup")
        try await api.saveProfile(id: nodeID, original: node, edited: edit)
        try await api.restoreWebDAVBackup()
        let restored = try await api.profileDocument(id: nodeID)
        let running: RuntimeStatus = try await api.runtimeStatus()
        try require(restored == node && running.runningProfileId == nodeID && running.coreRunning,
                    "Authenticated WebDAV restores the saved node and resumes Xray")
        try checkLoopbackHTTP(server: server, proxy: proxy, label: "Restored node forwards real HTTP through the loopback peer")
        do {
            try await api.restoreWebDAVBackup()
            throw ClientFailure("fixture_broken_restore_accepted")
        } catch let error as ClientFailure where error.code == "core_start_failed" || error.code == "core_config_invalid" {}
        let recovered: RuntimeStatus = try await api.runtimeStatus()
        let current = try await api.profileDocument(id: nodeID)
        try require(recovered.coreRunning && recovered.runningProxyPort == proxy && current == node,
                    "Restore rollback relaunches the original node when the archived inbound cannot bind")
    }

    static func checkLoopbackHTTP(server: Int, proxy: Int, label: String) throws {
        let request = Process()
        request.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        request.arguments = ["--silent", "--fail", "--max-time", "10", "--noproxy", "", "--proxy",
                             "http://127.0.0.1:" + String(proxy), "http://native-check.invalid:" + String(server) + "/traffic"]
        let out = Pipe()
        request.standardOutput = out
        request.standardError = FileHandle.nullDevice
        try request.run()
        let payload = out.fileHandleForReading.readDataToEndOfFile()
        request.waitUntilExit()
        try require(request.terminationStatus == 0 && String(decoding: payload, as: UTF8.self) == "v2rayM-local-traffic-ok",
                    label)
    }
}
