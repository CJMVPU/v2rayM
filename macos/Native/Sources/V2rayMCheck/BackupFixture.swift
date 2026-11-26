import Foundation
import V2rayMKit

extension NativeCheck {
    static func checkBackupFixture(_ api: any NativeAPI, server: Int, proxy: Int) async throws {
        let destination: SettingsValue = .object(["url": .string("http://127.0.0.1:" + String(server) + "/dav"),
            "dirName": .string("fixture"), "userName": .string("fixture"), "password": .string("local-only")])
        try await api.send("/api/settings/webdav", method: "PUT", body: destination)
        try await api.perform("/api/backup/webdav/check")
        let rule: SettingsValue = .object(["remarks": .string("Backup fixture"), "ruleSet": .string("[{\"port\":\"1-65535\",\"outboundTag\":\"proxy\"}]")])
        let bytes = try await api.encodedResponse("/api/settings/routing-profiles", method: "POST", body: JSONEncoder().encode(rule))
        let routeID = try JSONDecoder().decode(SettingsValue.self, from: bytes)["data"]["routingId"].text
        try await api.perform("/api/settings/routing-profiles/" + routeID + "/activate")
        let before: RuntimeStatus = try await api.value("/api/status")
        guard let nodeID = before.runningProfileId else { throw ClientFailure("fixture_node_missing") }
        let node = try await api.profileDocument(id: nodeID)
        try await api.perform("/api/backup/webdav")
        var edit = node
        edit["remarks"] = .string("after backup")
        try await api.saveProfile(id: nodeID, original: node, edited: edit)
        try await api.perform("/api/backup/webdav/restore")
        let restored = try await api.profileDocument(id: nodeID)
        let running: RuntimeStatus = try await api.value("/api/status")
        try require(restored == node && running.runningProfileId == nodeID && running.coreRunning,
                    "Authenticated WebDAV restores the saved node and resumes Xray")
        try checkLoopbackHTTP(server: server, proxy: proxy, label: "Restored node forwards real HTTP through the loopback peer")
        do {
            try await api.perform("/api/backup/webdav/restore")
            throw ClientFailure("fixture_broken_restore_accepted")
        } catch let error as ClientFailure where error.code == "core_start_failed" || error.code == "core_config_invalid" {}
        let recovered: RuntimeStatus = try await api.value("/api/status")
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
