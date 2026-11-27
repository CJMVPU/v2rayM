import Foundation
import V2rayMKit

extension NativeCheck {
    static func serveGroupEditFixture(bundle: URL, data: URL) async throws {
        let host = NativeRuntimeHost(bundle: bundle, dataDirectory: data, mayContactHelper: false, automaticMaintenance: false)
        try await host.start()
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
                    case "select": try await host.selectProfile(id, connect: true)
                    case "edit":
                        let current = try await host.profileDocument(id: id)
                        var edited = current
                        let field = command["field"].text
                        edited[field] = command["value"]
                        try await host.saveProfile(id: id, original: current, edited: edited)
                    case "move":
                        try await host.moveProfiles([id], to: command["value"].text)
                    case "refreshSubscription":
                        try await host.updateSubscriptions(id: id, useProxy: false)
                        let deadline = ContinuousClock.now + .seconds(8)
                        while true {
                            let operations = try await host.activeOperations()
                            if !operations.contains("subscription-update") { break }
                            guard ContinuousClock.now < deadline else { throw ClientFailure("fixture_refresh_timeout") }
                            try await Task.sleep(for: .milliseconds(20))
                        }
                    case "clean":
                        try await host.cleanProfiles(group: "sub", duplicates: false)
                    case "delete":
                        try await host.deleteProfiles([id])
                    default: throw ClientFailure("fixture_command_invalid")
                    }
                } catch let error as ClientFailure { errorCode = .string(error.code) }
                let state = try await host.runtimeStatus()
                try emit(.object(["session": .string(state.coreSessionID?.uuidString ?? ""), "error": errorCode,
                                  "running": .string(state.runningProfileId ?? "")]))
            }
            try await host.stop()
        } catch { try await host.stop(); throw error }
    }
}
