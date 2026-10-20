import Foundation
import Darwin
import V2rayMKit

/// This development executable is not shipped in the .app. It exercises the same native
/// controller/client as SwiftUI using a disposable data directory and loopback-only fixtures.
@main struct NativeCheck {
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data(("Native check failed: " + error.localizedDescription + "\n").utf8)); exit(1) }
    }
    static func run() async throws {
        let args = CommandLine.arguments
        guard args.count == 7, let apiPort = Int(args[3]), let fixturePort = Int(args[4]),
              let proxyPort = Int(args[5]), let socksPort = Int(args[6]) else {
            fatalError("V2rayMCheck <app> <temporary-data> <api-port> <http-fixture-port> <proxy-port> <socks-fixture-port>")
        }
        let bundle = URL(fileURLWithPath: args[1]), data = URL(fileURLWithPath: args[2])
        let backend = BackendController(bundle: bundle, dataDirectory: data, port: apiPort)
        do {
            let api = try await backend.start()
            async let initial: RuntimeStatus = api.value("/api/status")
            async let nodes: [Profile] = api.value("/api/profiles")
            async let subscriptions: [Subscription] = api.value("/api/subscriptions")
            let baseline = try await (initial, nodes, subscriptions)
            try require(!baseline.0.coreRunning && baseline.1.isEmpty && baseline.2.isEmpty, "Fresh data isolation")
            // Verify loopback collision detection never authenticates against or stops another owner.
            let collision = BackendController(bundle: bundle, dataDirectory: data.appendingPathComponent("collision"), port: apiPort)
            do { _ = try await collision.start(); throw ClientFailure("collision_not_rejected") }
            catch let failure as ClientFailure { try require(failure.code == "backend_identity" || failure.code == "backend_exited", "Collision rejected") }
            let stillHealthy: RuntimeStatus = try await api.value("/api/status")
            try require(!stillHealthy.coreRunning, "Original backend survives collision")
            try await api.send("/api/subscriptions", body: SubscriptionInput(name: "Local fixture", url: "http://127.0.0.1:\(fixturePort)/subscription"))
            let groups: [Subscription] = try await api.value("/api/subscriptions")
            try require(groups.count == 1, "Create subscription")
            let group = groups[0]
            try await api.send("/api/subscriptions/\(group.id)", method: "PUT",
                               body: SubscriptionInput(name: "Edited fixture", url: group.url, existing: group))
            try await api.perform("/api/subscriptions/\(group.id)/update?useProxy=false")
            var imported: [Profile] = []
            for _ in 0..<100 {
                imported = try await api.value("/api/profiles?subscriptionId=")
                if !imported.isEmpty { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            try require(imported.count == 1 && imported[0].subscriptionName == "Edited fixture", "Subscription downloads nodes")
            try await api.send("/api/profiles/import", body: ImportInput(content: "socks://127.0.0.1:\(socksPort)#Manual%20fixture"))
            let profiles: [Profile] = try await api.value("/api/profiles?subscriptionId=")
            try require(profiles.count == 2, "Import manual node")
            // Set an isolated local port and route local test traffic through the selected outbound.
            try await api.send("/api/settings/inbound", method: "PUT", body: Inbound(localPort: proxyPort))
            try await api.send("/api/settings/routing-profiles", body: [
                "remarks": "Native loopback fixture route", "ruleSet": "[{\"port\":\"0-65535\",\"outboundTag\":\"proxy\"}]"])
            let routes: [RoutingProfile] = try await api.value("/api/settings/routing-profiles")
            guard let fixtureRoute = routes.first(where: { $0.remarks == "Native loopback fixture route" }) else {
                throw ClientFailure("fixture_route_missing")
            }
            try await api.perform("/api/settings/routing-profiles/\(fixtureRoute.id)/activate")
            for item in profiles {
                try await api.perform("/api/profiles/\(item.id)/select")
                let status: RuntimeStatus = try await api.value("/api/status")
                try require(status.coreRunning && status.currentProfileId == item.id && status.runningProxyPort == proxyPort, "Select and start node")
                let curl = Process(); curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                curl.arguments = ["--fail", "--silent", "--show-error", "--max-time", "10", "--noproxy", "", "--proxy", "http://127.0.0.1:\(proxyPort)", "http://native-check.invalid:\(fixturePort)/traffic"]
                let output = Pipe(); curl.standardOutput = output; curl.standardError = FileHandle.nullDevice
                try curl.run()
                let result = output.fileHandleForReading.readDataToEndOfFile(); curl.waitUntilExit()
                try require(curl.terminationStatus == 0 && String(data: result, encoding: .utf8) == "v2rayM-local-traffic-ok", "Real core HTTP proxy traffic")
            }
            try await api.perform("/api/core/stop")
            let stopped: RuntimeStatus = try await api.value("/api/status")
            try require(!stopped.coreRunning, "Disconnect core")
            if let manual = profiles.first(where: { $0.subscriptionId?.isEmpty != false }) {
                try await api.send("/api/profiles", method: "DELETE", body: ProfileIDs([manual.id]))
            }
            try await api.perform("/api/subscriptions/\(group.id)", method: "DELETE")
            let remaining: [Subscription] = try await api.value("/api/subscriptions")
            try require(remaining.isEmpty, "Delete subscription")
            let remainingNodes: [Profile] = try await api.value("/api/profiles?subscriptionId=")
            try require(remainingNodes.isEmpty, "Delete manual and subscription nodes")
            await api.logout()
            let renewed: RuntimeStatus = try await api.value("/api/status")
            try require(!renewed.coreRunning, "Session reauthentication")
            try await backend.stop()
            let alive = await backend.isRunning; try require(!alive, "Owned backend graceful exit")
            print("Native integration passed: process ownership, authenticated API, subscriptions CRUD/update, node import/select/delete, real Xray traffic, stop and logout.")
        } catch {
            try? await backend.stop(); throw error
        }
    }
    static func require(_ condition: Bool, _ label: String) throws {
        guard condition else { throw ClientFailure("check_failed", label) }
        print("PASS: \(label)")
    }
}
private struct Inbound: Encodable {
    var localPort: Int
    let secondLocalPortEnabled = false, udpEnabled = true, sniffingEnabled = false
    let destOverride = ["http", "tls"], routeOnly = false, allowLANConn = false, newPort4LAN = false
}
