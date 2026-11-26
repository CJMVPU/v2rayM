import Foundation
import V2rayMKit

extension NativeCheck {
    static func serveGroupEditFixture(bundle: URL, data: URL) async throws {
        let host = NativeRuntimeHost(bundle: bundle, dataDirectory: data, mayContactHelper: false, automaticMaintenance: false)
        let api = try await host.startClient()
        func emit(_ value: SettingsValue) throws {
            FileHandle.standardOutput.write(try JSONEncoder().encode(value) + Data([10]))
        }
        do {
            try emit(.string("ready"))
            while let line = readLine() {
                let command = try SettingsValue.parse(line)
                let id = command["id"].text
                var errorCode: SettingsValue = .null
                do {
                    switch command["action"].text {
                    case "select": try await api.perform("/api/profiles/\(id)/select?connect=true")
                    case "edit":
                        let current = try await api.profileDocument(id: id)
                        var edited = current
                        let field = command["field"].text
                        edited[field] = command["value"]
                        try await api.saveProfile(id: id, original: current, edited: edited)
                    case "move":
                        try await api.send("/api/profiles/move-to-group", body: SettingsValue.object([
                            "profileIds": .array([.string(id)]), "subscriptionId": command["value"]]))
                    case "refreshSubscription":
                        try await api.send("/api/subscriptions/update", body: SettingsValue.object([
                            "subscriptionId": .string(id), "useProxy": .bool(false)]))
                        let deadline = ContinuousClock.now + .seconds(8)
                        while true {
                            let operations: [String] = try await api.value("/api/operations")
                            if !operations.contains("subscription-update") { break }
                            guard ContinuousClock.now < deadline else { throw ClientFailure("fixture_refresh_timeout") }
                            try await Task.sleep(for: .milliseconds(20))
                        }
                    case "clean":
                        try await api.perform("/api/profiles/invalid-test-results?subscriptionId=sub", method: "DELETE")
                    case "delete":
                        try await api.send("/api/profiles", method: "DELETE", body: ProfileIDs([id]))
                    default: throw ClientFailure("fixture_command_invalid")
                    }
                } catch let error as ClientFailure { errorCode = .string(error.code) }
                let state = try await api.runtimeStatus()
                try emit(.object(["session": .string(state.coreSessionID?.uuidString ?? ""), "error": errorCode,
                                  "running": .string(state.runningProfileId ?? "")]))
            }
            try await host.stop()
        } catch { try await host.stop(); throw error }
    }
}
