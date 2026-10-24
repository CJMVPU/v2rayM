import Foundation
import Darwin
import V2rayMKit
import CryptoKit

/// This development executable is not shipped in the .app. It exercises the same native
/// controller/client as SwiftUI using a disposable data directory and loopback-only fixtures.
@main struct NativeCheck {
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data(("Native check failed: " + error.localizedDescription + "\n").utf8)); exit(1) }
    }
    static func checkSettings(_ api: APIClient, running: Bool) async throws {
        var draft: SettingsValue = try await api.value("/api/settings")
        let oldHidden = draft["core"]["enableFinalFragment"]
        draft["application"] = draft["app"]
        draft["application"]["enableStatistics"] = .bool(false)
        draft["application"]["displayRealTimeSpeed"] = .bool(true)
        let oldLevel = draft["core"]["loglevel"].text
        draft["core"]["loglevel"] = .string(oldLevel == "info" ? "warning" : "info")
        let tun: SettingsValue = try await api.value("/api/macos/tun/settings")
        draft["nativeTun"] = tun
        draft["nativeTun"]["mtu"] = .number(1500)
        try await api.send("/api/settings/apply", method: "PUT", body: draft)
        let after: SettingsValue = try await api.value("/api/settings")
        try require(after["core"]["loglevel"] == draft["core"]["loglevel"] && after["core"]["enableFinalFragment"] == oldHidden, "Parameters save and preserve hidden upstream options")
        let savedTun: SettingsValue = try await api.value("/api/macos/tun/settings")
        try require(savedTun["mtu"] == .number(1500), "Native TUN settings persist in the same parameter transaction")
        if !running {
            for mtu in [1280, 1408, 1500, 4064, 9000, 65535, 1420] {
                draft["nativeTun"]["mtu"] = .number(Double(mtu))
                try await api.send("/api/settings/apply", method: "PUT", body: draft)
                let saved: SettingsValue = try await api.value("/api/macos/tun/settings")
                try require(saved["mtu"] == .number(Double(mtu)), "MTU preset/custom value round-trips: \(mtu)")
            }
        }
        var invalid = draft; invalid["nativeTun"]["mtu"] = .number(0)
        do {
            try await api.send("/api/settings/apply", method: "PUT", body: invalid)
            throw ClientFailure("invalid_tun_settings_accepted")
        } catch let error as ClientFailure {
            try require(error.code == "mac_tun_settings_invalid", "Invalid native TUN settings rejected")
        }
        invalid["nativeTun"]["mtu"] = .number(65536)
        do {
            try await api.send("/api/settings/apply", method: "PUT", body: invalid)
            throw ClientFailure("invalid_tun_settings_accepted")
        } catch let error as ClientFailure {
            try require(error.code == "mac_tun_settings_invalid", "MTU above 65535 rejected")
        }
        var simple: SettingsValue = try await api.value("/api/settings/dns/simple")
        simple["useSystemHosts"] = .bool(!simple["useSystemHosts"].flag)
        try await api.send("/api/settings/dns/simple", method: "PUT", body: simple)
        let simpleAfter: SettingsValue = try await api.value("/api/settings/dns/simple")
        try require(simpleAfter == simple, "Simple DNS options survive round trip")
        let profiles: SettingsValue = try await api.value("/api/settings/dns/profiles")
        guard var xray = profiles.items.first(where: { $0["coreType"].text.lowercased() == "xray" }) else { throw ClientFailure("dns_profile_not_found") }
        xray["normalDNS"] = .string("{\"servers\":[\"1.1.1.1\"]}")
        xray["tunDNS"] = .string("{\"servers\":[\"1.0.0.1\"]}")
        try await api.send("/api/settings/dns/profiles/Xray", method: "PUT", body: xray)
        let dnsAfter: SettingsValue = try await api.value("/api/settings/dns/profiles")
        let saved = dnsAfter.items.first(where: { $0["coreType"].text.lowercased() == "xray" })!
        try require(saved["normalDNS"] == xray["normalDNS"] && saved["tunDNS"] == xray["tunDNS"], "Normal and native TUN DNS are stored independently")
        let beforeRoutes: SettingsValue = try await api.value("/api/settings/routing-profiles")
        let draftRoute = RoutingDraft.newProfile()
        try await api.send("/api/settings/routing-profiles", method: "POST", body: draftRoute)
        let createdRoutes: SettingsValue = try await api.value("/api/settings/routing-profiles")
        try require(createdRoutes.items.count == beforeRoutes.items.count + 1, "New route creates a separate record")
        for old in beforeRoutes.items {
            try require(createdRoutes.items.first(where: { $0["id"] == old["id"] }) == old, "Creating a route preserves every original route")
        }
        let routes: SettingsValue = try await api.value("/api/settings/routing-profiles")
        if var route = routes.items.first(where: { $0["isActive"].flag }) {
            let id = route["id"].text
            let rules: SettingsValue = try await api.value("/api/settings/routing-profiles/\(id)/rules")
            route["ruleSet"] = .string(try rules.json())
            route["remarks"] = .string(route["remarks"].text + " checked")
            try await api.send("/api/settings/routing-profiles/\(id)", method: "PUT", body: route)
            let savedRules: SettingsValue = try await api.value("/api/settings/routing-profiles/\(id)/rules")
            try require(savedRules.items.count == rules.items.count, "Routing editor preserves ordered rules")
        }
        let status: RuntimeStatus = try await api.value("/api/status")
        try require(status.coreRunning == running, "Settings preserve stopped/running core intent")
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
            let tunnel = try await api.tunStatus()
            try require(tunnel.platformSupported && !tunnel.enabled && !tunnel.isRunning,
                        "TUN status distinguishes saved mode from a running tunnel")
            try await api.setTunEnabled(false)
            let disabled = try await api.tunStatus()
            try require(!disabled.enabled && disabled.privilegedCoreProcessIds.isEmpty,
                        "TUN can be disabled through the native API without starting a core")
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
            if let item = profiles.first {
                try await api.perform("/api/profiles/\(item.id)/select?connect=false")
                let selected: RuntimeStatus = try await api.value("/api/status")
                try require(!selected.coreRunning && selected.currentProfileId == item.id,
                            "Selecting a node while off does not start a proxy core")
            }
            if let item = profiles.first {
                let path = "/api/profiles/\(item.id)"
                let original: SettingsValue = try await api.value(path)
                var draft = ProfileDocument(original)
                draft.value["remarks"] = .string("Edited node fixture")
                draft.value["transportExtra"] = .string("{\"Path\":\"/preserved-path\",\"Host\":\"example.invalid\"}")
                try await api.send(path, method: "PUT", body: try draft.validated())
                let saved: SettingsValue = try await api.value(path)
                try require(saved["remarks"].text == "Edited node fixture" && saved["transportExtra"] == draft.value["transportExtra"], "Node editor saves identity and transport fields")
                var retired = saved; retired["coreType"] = .number(24)
                do {
                    try await api.send(path, method: "PUT", body: retired)
                    throw ClientFailure("retired_engine_accepted")
                } catch let failure as ClientFailure {
                    try require(failure.code == "xray_only_profile_required", "Backend rejects retired engine without overwriting node")
                }
                let unchanged: SettingsValue = try await api.value(path)
                try require(unchanged == saved, "Rejected node edit preserves stored data")
            }
            try await checkSettings(api, running: false)
            var firstCoreLog: LogEntry?
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
                if firstCoreLog == nil {
                    let tail: LogTail = try await api.value("/api/logs/tail?after=0&limit=10000")
                    firstCoreLog = tail.items.first(where: { $0.source == "core" })
                }
            }
            try await checkSettings(api, running: true)
            var hasTrafficSample = false
            for _ in 0..<40 {
                let sampled: RuntimeStatus = try await api.value("/api/status")
                if sampled.trafficEnabled == true, let rates = sampled.traffic?.rates(at: Date()), rates.allSatisfy({ $0 >= 0 }) {
                    hasTrafficSample = true; break
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            try require(hasTrafficSample, "Dashboard receives fresh nonnegative Xray traffic rates with sampling interval")
            let versionStatus: RuntimeStatus = try await api.value("/api/status")
            try require(versionStatus.installedXrayVersion?.isEmpty == false, "Dashboard reads installed Xray version from actual binary")
            var statisticsDraft: SettingsValue = try await api.value("/api/settings")
            statisticsDraft["application"] = statisticsDraft["app"]
            statisticsDraft["application"]["enableStatistics"] = .bool(true)
            try await api.send("/api/settings/apply", method: "PUT", body: statisticsDraft)
            let trafficProbe = Process(); trafficProbe.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            trafficProbe.arguments = ["--fail", "--silent", "--max-time", "10", "--noproxy", "", "--proxy", "http://127.0.0.1:\(proxyPort)"] + Array(repeating: "http://native-check.invalid:\(fixturePort)/traffic", count: 40)
            trafficProbe.standardOutput = FileHandle.nullDevice; trafficProbe.standardError = FileHandle.nullDevice
            try trafficProbe.run(); trafficProbe.waitUntilExit()
            try require(trafficProbe.terminationStatus == 0, "Generate loopback traffic for cumulative dashboard counters")
            var cumulativeTraffic: Double = 0
            for _ in 0..<40 {
                let counted: [Profile] = try await api.value("/api/profiles?subscriptionId=")
                cumulativeTraffic = counted.reduce(0) { $0 + ($1.totalUp ?? 0) + ($1.totalDown ?? 0) }
                if cumulativeTraffic > 0 { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            try require(cumulativeTraffic > 0, "Dashboard cumulative traffic increases with actual Xray proxy traffic")
            if ProcessInfo.processInfo.environment["V2RAYM_CHECK_UPDATES"] == "1" {
                let before: RuntimeStatus = try await api.value("/api/status")
                let settings: ModuleUpdateSettings = try await api.value("/api/core-updates")
                var input = settings.input; input.useProxy = false
                try await api.send("/api/core-updates/settings", method: "PUT", body: input)
                try await api.perform("/api/core-updates/Xray/update?useProxy=false")
                var completed: ModuleUpdateProgress?
                var phases = Set<String>()
                for _ in 0..<750 {
                    let progress: [ModuleUpdateProgress] = try await api.value("/api/core-updates/progress")
                    if let current = progress.first(where: { $0.coreType == "Xray" }) {
                        if phases.insert(current.phase).inserted { print("UPDATE: " + current.phase) }
                        if current.isComplete { completed = current; break }
                    }
                    try await Task.sleep(for: .milliseconds(200))
                }
                try require(completed?.success == true, "Official Xray update completed: " + (completed?.detail ?? "timeout"))
                for _ in 0..<100 {
                    let operations: [String] = try await api.value("/api/operations")
                    if !operations.contains(where: { $0.hasPrefix("core-update") }) { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                let after: RuntimeStatus = try await api.value("/api/status")
                try require(after.coreRunning && before.currentProfileId == after.currentProfileId
                            && before.coreProcessIds != after.coreProcessIds, "Serving core restarts on the selected node after update")
                let curl = Process(); curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                curl.arguments = ["--fail", "--silent", "--max-time", "10", "--noproxy", "", "--proxy", "http://127.0.0.1:\(proxyPort)", "http://native-check.invalid:\(fixturePort)/traffic"]
                let traffic = Pipe(); curl.standardOutput = traffic; curl.standardError = FileHandle.nullDevice
                try curl.run(); let bytes = traffic.fileHandleForReading.readDataToEndOfFile(); curl.waitUntilExit()
                try require(curl.terminationStatus == 0 && String(decoding: bytes, as: UTF8.self) == "v2rayM-local-traffic-ok", "Traffic survives automatic update replacement")
                let bridge = Process(); bridge.executableURL = bundle.appendingPathComponent("Contents/MacOS/V2rayMHelperClient")
                bridge.arguments = ["update"]
                let inputPipe = Pipe(), outputPipe = Pipe(); bridge.standardInput = inputPipe; bridge.standardOutput = outputPipe
                try bridge.run()
                try inputPipe.fileHandleForWriting.write(contentsOf: Data("{\"action\":\"update-status\",\"core\":\"xray\"}\n".utf8))
                try inputPipe.fileHandleForWriting.close()
                let reply = outputPipe.fileHandleForReading.readDataToEndOfFile(); bridge.waitUntilExit()
                let status = try JSONDecoder().decode(ApprovedUpdate.self, from: reply)
                let executable = data.appendingPathComponent("bin/xray/xray")
                let hash = SHA256.hash(data: try Data(contentsOf: executable)).map { String(format: "%02x", $0) }.joined()
                try require(status.success && status.verifiedSHA256 == hash && status.previousVersionPresent == false,
                            "Privileged and ordinary core hashes match; old privileged version removed")
                let files = try FileManager.default.contentsOfDirectory(atPath: data.appendingPathComponent("bin").path)
                try require(!files.contains(where: { $0.contains("-backup-") || $0.contains("-candidate-") || $0.contains("-package-") }),
                            "Ordinary update backup and staging directories removed")
            }
            if ProcessInfo.processInfo.environment["V2RAYM_CHECK_RESOURCES"] == "1" {
                for scope in ["rules", "geo"] {
                    let before: RuntimeStatus = try await api.value("/api/status")
                    try await api.perform("/api/core/geo/update?scope=\(scope)&useProxy=false")
                    var completed: ModuleUpdateProgress?
                    for _ in 0..<750 {
                        let progress: [ModuleUpdateProgress] = try await api.value("/api/core-updates/progress")
                        if let current = progress.first(where: { $0.coreType == "GeoFiles" }), current.isComplete {
                            completed = current; break
                        }
                        try await Task.sleep(for: .milliseconds(200))
                    }
                    try require(completed?.success == true, "Independent \(scope) update completed" + (completed?.detail.map { ": " + $0 } ?? ""))
                    let after: RuntimeStatus = try await api.value("/api/status")
                    try require(after.coreRunning && before.currentProfileId == after.currentProfileId
                        && before.coreProcessIds != after.coreProcessIds, "Serving core reloads after \(scope) replacement")
                    let curl = Process(); curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                    curl.arguments = ["--fail", "--silent", "--max-time", "10", "--noproxy", "", "--proxy", "http://127.0.0.1:\(proxyPort)", "http://native-check.invalid:\(fixturePort)/traffic"]
                    let output = Pipe(); curl.standardOutput = output; curl.standardError = FileHandle.nullDevice
                    try curl.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); curl.waitUntilExit()
                    try require(curl.terminationStatus == 0 && String(decoding: bytes, as: UTF8.self) == "v2rayM-local-traffic-ok", "Proxy traffic survives \(scope) reload")
                }
            }
            try await api.perform("/api/core/stop")
            let stopped: RuntimeStatus = try await api.value("/api/status")
            try require(!stopped.coreRunning && stopped.traffic == nil, "Disconnect core clears displayed traffic")
            let retainedProfiles: [Profile] = try await api.value("/api/profiles?subscriptionId=")
            try require(retainedProfiles.reduce(0) { $0 + ($1.totalUp ?? 0) + ($1.totalDown ?? 0) } >= cumulativeTraffic, "Stopping proxy retains cumulative dashboard traffic")
            let retained: LogTail = try await api.value("/api/logs/tail?after=0&limit=10000")
            try require(firstCoreLog != nil && retained.items.contains(where: { $0.id == firstCoreLog?.id }),
                        "Core switching and stopping retain earlier log entries and stable identifiers")
            let deltaTail: LogTail = try await api.value("/api/logs/tail?after=\(retained.latestSequence)&limit=10000")
            try require(deltaTail.items.allSatisfy({ ($0.sequence ?? 0) > retained.latestSequence }),
                        "Incremental polling returns only new log entries")
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
private struct ApprovedUpdate: Decodable {
    var success: Bool
    var verifiedSHA256: String?
    var previousVersionPresent: Bool?
}
private struct Inbound: Encodable {
    var localPort: Int
    let secondLocalPortEnabled = false, udpEnabled = true, sniffingEnabled = false
    let destOverride = ["http", "tls"], routeOnly = false, allowLANConn = false, newPort4LAN = false
}
