import Foundation
import Darwin
import MachO
import V2rayMKit

/// This development executable is not shipped in the .app. It exercises the same native
/// controller/client as SwiftUI using a disposable data directory and loopback-only fixtures.
@main struct NativeCheck {
    static func main() async {
        do { try await run() }
        catch { FileHandle.standardError.write(Data(("Native check failed: " + error.localizedDescription + "\n").utf8)); exit(1) }
    }
    static func checkProfileCatalog(_ api: any NativeAPI, group: Subscription, profiles: [Profile]) async throws -> String {
        guard let original = profiles.first else { throw ClientFailure("fixture_node_missing") }
        try await api.send("/api/profiles/copy", body: ProfileIDs([original.id, original.id]))
        let copied: [Profile] = try await api.value("/api/profiles?subscriptionId=")
        guard let copy = copied.first(where: { node in !profiles.contains(where: { $0.id == node.id }) }) else {
            throw ClientFailure("copied_node_missing")
        }
        try require(copied.count == profiles.count + 1, "Copy deduplicates requested IDs and persists one new node")
        try await api.send("/api/profiles/move-to-group", body: SettingsValue.object([
            "profileIds": .array([.string(copy.id)]), "subscriptionId": .string(group.id)]))
        let grouped: [Profile] = try await api.value("/api/profiles?subscriptionId=\(group.id)")
        try require(grouped.contains(where: { $0.id == copy.id }), "Move copied node into subscription group")
        try await api.send("/api/profiles/move-to-group", body: SettingsValue.object([
            "profileIds": .array([.string(copy.id)]), "subscriptionId": .string("")]))
        try await api.send("/api/profile-groups/current", method: "PUT", body: ["subscriptionId": ""])
        try await api.send("/api/profiles/move", body: SettingsValue.object([
            "profileId": .string(copy.id), "direction": .string("top"), "position": .number(-1)]))
        let reordered: [Profile] = try await api.value("/api/profiles?subscriptionId=")
        try require(reordered.first?.id == copy.id, "Reorder persists copied node at top")
        try await api.send("/api/profiles/sort", body: SettingsValue.object([
            "subscriptionId": .string(""), "column": .string("Remarks"), "ascending": .bool(true)]))
        let sorted: [Profile] = try await api.value("/api/profiles?subscriptionId=")
        try require(sorted.count == copied.count && Set(sorted.map(\.id)) == Set(copied.map(\.id)), "Sort retains every node identity")
        try await api.send("/api/profiles/sort", body: SettingsValue.object([
            "subscriptionId": .string(""), "column": .string("Remarks"), "ascending": .bool(false)]))
        let descending: [Profile] = try await api.value("/api/profiles?subscriptionId=")
        try require(descending.map(\.remarks) == Array(sorted.map(\.remarks).reversed()), "Sort persists ascending and descending name order")
        try await api.send("/api/speedtests", body: SettingsValue.object([
            "action": .string("tcping"), "profileIds": .array([.string(copy.id)])]))
        var completedProbe = false
        for _ in 0..<100 {
            let operations: [String] = try await api.value("/api/operations")
            if !operations.contains("speedtest") { completedProbe = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try require(completedProbe, "Loopback TCP probe completes through application coordinator")
        try await api.perform("/api/speedtests", method: "DELETE")
        try await api.perform("/api/profiles/\(copy.id)/latency")
        var completedSingleProbe = false
        for _ in 0..<100 {
            let operations: [String] = try await api.value("/api/operations")
            if !operations.contains("speedtest") { completedSingleProbe = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try require(completedSingleProbe, "Single-node latency endpoint owns one background lease")
        let metadata: [Profile] = try await api.value("/api/profiles?subscriptionId=&includeStatistics=false")
        let observations: [ProfileObservation] = try await api.value("/api/profiles/observations")
        let complete: [Profile] = try await api.value("/api/profiles?subscriptionId=")
        try require(metadata.map(\.id) == complete.map(\.id), "Lightweight metadata preserves node identity and ordering")
        try require(observations.first(where: { $0.indexId == copy.id })?.delay == complete.first(where: { $0.id == copy.id })?.delay,
            "Fast observation endpoint reports the completed probe without reloading node documents")
        let export = SettingsValue.object(["profileIds": .array([.string(copy.id)]), "includeShareUris": .bool(true),
            "base64ShareUris": .bool(true), "includeInnerUri": .bool(true), "includeClientConfig": .bool(true)])
        let bytes = try await api.encodedResponse("/api/profiles/export", method: "POST", body: JSONEncoder().encode(export))
        let response = try JSONDecoder().decode(SettingsValue.self, from: bytes)
        let formats = Set(response["data"].items.map { $0["format"].text })
        try require(formats == Set(["share-uri-base64", "inner-uri", "client-config"]), "Export produces all requested formats")
        return copy.id
    }

    static func checkSettingsEditor(_ api: any NativeAPI) async throws {
        let initial: SettingsValue = try await api.value("/api/settings")
        let beforePassive: RuntimeStatus = try await api.value("/api/status")
        var app = initial["app"]
        app["enableStatistics"] = .bool(!app["enableStatistics"].flag)
        try await api.send("/api/settings/application", method: "PUT", body: app)
        var speed = initial["speedTest"]
        speed["speedTestTimeout"] = .number(15)
        try await api.send("/api/settings/speedtest", method: "PUT", body: speed)
        let afterPassive: RuntimeStatus = try await api.value("/api/status")
        let passive: SettingsValue = try await api.value("/api/settings")
        try require(passive["app"]["enableStatistics"] == app["enableStatistics"]
            && passive["speedTest"]["speedTestTimeout"] == .number(15), "Single application and speed-test edits persist")
        try require(beforePassive.coreSessionID == afterPassive.coreSessionID, "Passive settings and statistics refresh do not restart core")
        var core = passive["core"]
        core["mux4RayConcurrency"] = .number(0)
        core["mux4RayXudpConcurrency"] = .number(0)
        try await api.send("/api/settings/core", method: "PUT", body: core)
        var normalized: SettingsValue = try await api.value("/api/settings")
        try require(normalized["core"]["mux4RayConcurrency"] == .null
            && normalized["core"]["mux4RayXudpConcurrency"] == .null, "Zero Mux values normalize to disabled nullable values")
        normalized["application"] = normalized["app"]
        let beforeRoundTrip: RuntimeStatus = try await api.value("/api/status")
        try await api.send("/api/settings/apply", method: "PUT", body: normalized)
        try await api.send("/api/settings/core-types", method: "PUT", body: SettingsValue.object(["mappings": normalized["coreTypes"]]))
        try await api.send("/api/settings/routing", method: "PUT", body: SettingsValue.object(["domainStrategy": normalized["domainStrategy"]]))
        let afterRoundTrip: RuntimeStatus = try await api.value("/api/status")
        try require(beforeRoundTrip.coreSessionID == afterRoundTrip.coreSessionID,
            "Nullable Mux bulk save and unchanged mapping/strategy edits do not restart core")
    }

    static func checkConfigurationProfiles(_ api: any NativeAPI, running: Bool) async throws {
        let profiles: SettingsValue = try await api.value("/api/settings/dns/profiles")
        guard var dns = profiles.items.first(where: { $0["coreType"].text.lowercased() == "xray" }) else { throw ClientFailure("dns_fixture_missing") }
        let beforeDns: RuntimeStatus = try await api.value("/api/status")
        dns["enabled"] = .bool(true)
        dns["normalDNS"] = .string("{\"servers\":[\"9.9.9.9\"]}")
        try await api.send("/api/settings/dns/profiles/Xray", method: "PUT", body: dns)
        let afterDns: RuntimeStatus = try await api.value("/api/status")
        try require(afterDns.coreRunning == running && (!running || beforeDns.coreSessionID != afterDns.coreSessionID),
            "Active DNS change applies to the running core and preserves stopped intent")
        dns["remarks"] = .string(dns["remarks"].text + " checked")
        dns["tunDNS"] = .string("{\"servers\":[\"8.8.4.4\"]}")
        try await api.send("/api/settings/dns/profiles/Xray", method: "PUT", body: dns)
        let afterOtherMode: RuntimeStatus = try await api.value("/api/status")
        let savedProfiles: SettingsValue = try await api.value("/api/settings/dns/profiles")
        let savedDns = savedProfiles.items.first(where: { $0["id"] == dns["id"] })!
        try require(savedDns["tunDNS"] == dns["tunDNS"] && afterOtherMode.coreSessionID == afterDns.coreSessionID,
            "Editing TUN DNS and metadata preserves the active normal-mode core")
        let templates: SettingsValue = try await api.value("/api/settings/core-templates")
        guard var template = templates.items.first(where: { $0["coreType"].text.lowercased() == "xray" }),
              !template["enabled"].flag else { throw ClientFailure("disabled_template_fixture_missing") }
        template["remarks"] = .string(template["remarks"].text + " checked")
        template["tunConfig"] = .string("{\"outbounds\":[]}")
        try await api.send("/api/settings/core-templates/Xray", method: "PUT", body: template)
        let afterTemplate: RuntimeStatus = try await api.value("/api/status")
        let savedTemplates: SettingsValue = try await api.value("/api/settings/core-templates")
        let savedTemplate = savedTemplates.items.first(where: { $0["id"] == template["id"] })!
        try require(savedTemplate["tunConfig"] == template["tunConfig"] && afterTemplate.coreSessionID == afterOtherMode.coreSessionID,
            "Disabled template edits persist without restarting the core")
    }

    static func checkSettings(_ api: any NativeAPI, running: Bool, unavailablePort: Int? = nil) async throws {
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
        try await checkSettingsEditor(api)
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
        try await checkConfigurationProfiles(api, running: running)
        let beforeRoutes: SettingsValue = try await api.value("/api/settings/routing-profiles")
        let draftRoute = RoutingDraft.newProfile()
        let routeReply = try await api.encodedResponse("/api/settings/routing-profiles", method: "POST", body: JSONEncoder().encode(draftRoute))
        let acknowledgedRoute = try JSONDecoder().decode(SettingsValue.self, from: routeReply)["data"]["routingId"].text
        let createdRoutes: SettingsValue = try await api.value("/api/settings/routing-profiles")
        try require(!acknowledgedRoute.isEmpty && createdRoutes.items.contains(where: { $0["id"].text == acknowledgedRoute }),
            "Route creation acknowledgement carries the durable identity before list refresh")
        try require(createdRoutes.items.count == beforeRoutes.items.count + 1, "New route creates a separate record")
        for old in beforeRoutes.items {
            try require(createdRoutes.items.first(where: { $0["id"] == old["id"] }) == old, "Creating a route preserves every original route")
        }
        if let added = createdRoutes.items.first(where: { new in !beforeRoutes.items.contains(where: { $0["id"] == new["id"] }) }) {
            let path = "/api/settings/routing-profiles/\(added["id"].text)/rules"
            let customRules = SettingsValue.array([
                .object(["id": .string("fixture-a"), "type": .string("field"), "port": .string("443"), "outboundTag": .string("direct"), "process": .array([.string("fixture-process")])]),
                .object(["id": .string("fixture-b"), "type": .string("field"), "port": .string("80"), "outboundTag": .string("direct")])])
            let beforeRuleEdit: RuntimeStatus = try await api.value("/api/status")
            try await api.send(path, method: "PUT", body: customRules)
            try await api.send(path + "/move", body: SettingsValue.object(["ruleId": .string("fixture-a"), "direction": .string("bottom"), "position": .number(-1)]))
            let moved: SettingsValue = try await api.value(path)
            try require(moved.items.last?["id"].text == "fixture-a" && moved.items.last?["process"] == customRules.items.first?["process"], "Routing move preserves full matcher fields")
            try await api.send(path + "/import", body: SettingsValue.object(["content": .string("[{\"Id\":\"fixture-c\",\"Port\":\"53\",\"OutboundTag\":\"direct\"}]"), "append": .bool(true)]))
            try await api.perform(path + "/fixture-b", method: "DELETE")
            let remainingRules: SettingsValue = try await api.value(path)
            try require(remainingRules.items.map { $0["id"].text } == ["fixture-a", "fixture-c"], "Routing append and delete preserve order")
            let afterRuleEdit: RuntimeStatus = try await api.value("/api/status")
            try require(beforeRuleEdit.coreSessionID == afterRuleEdit.coreSessionID, "Inactive routing changes do not restart core")
        }
        let routes: SettingsValue = try await api.value("/api/settings/routing-profiles")
        if var route = routes.items.first(where: { $0["isActive"].flag }) {
            let id = route["id"].text
            let rules: SettingsValue = try await api.value("/api/settings/routing-profiles/\(id)/rules")
            route["ruleSet"] = .string(try rules.json())
            route["remarks"] = .string(route["remarks"].text + " checked")
            try await api.send("/api/settings/routing-profiles/\(id)", method: "PUT", body: route)
            let savedRules: SettingsValue = try await api.value("/api/settings/routing-profiles/\(id)/rules")
            try require(savedRules == rules, "Routing profile metadata edit preserves full ordered rules and IDs")
            let beforeNoOp: RuntimeStatus = try await api.value("/api/status")
            try await api.send("/api/settings/routing-profiles/\(id)", method: "PUT", body: route)
            try await api.perform("/api/settings/routing-profiles/\(id)/activate", method: "POST")
            let afterNoOp: RuntimeStatus = try await api.value("/api/status")
            try require(beforeNoOp.coreSessionID == afterNoOp.coreSessionID, "Unchanged active profile save and activation do not restart core")
            if let first = savedRules.items.first {
                let beforeMove: RuntimeStatus = try await api.value("/api/status")
                try await api.send("/api/settings/routing-profiles/\(id)/rules/move", body: SettingsValue.object([
                    "ruleId": .string(first["id"].text), "direction": .string("top"), "position": .number(-1)]))
                let afterMove: RuntimeStatus = try await api.value("/api/status")
                try require(beforeMove.coreSessionID == afterMove.coreSessionID, "No-op active rule move does not restart core")
            }
        }
        if running {
            let templates: SettingsValue = try await api.value("/api/settings/core-templates")
            guard var broken = templates.items.first(where: { $0["coreType"].text.lowercased() == "xray" }) else {
                throw ClientFailure("template_fixture_missing")
            }
            let beforeFailure: RuntimeStatus = try await api.value("/api/status")
            broken["enabled"] = .bool(true)
            broken["config"] = .string("{")
            do {
                try await api.send("/api/settings/core-templates/Xray", method: "PUT", body: broken)
                throw ClientFailure("broken_template_accepted")
            } catch let error as ClientFailure {
                try require(error.code == "settings_core_apply_failed", "Invalid runtime template reports settings apply failure")
            }
            let restoredTemplates: SettingsValue = try await api.value("/api/settings/core-templates")
            let restoredRuntime: RuntimeStatus = try await api.value("/api/status")
            try require(restoredTemplates == templates, "Failed runtime apply restores persisted template snapshot")
            try require(restoredRuntime.coreRunning && restoredRuntime.coreProcessIds?.isEmpty == false
                && restoredRuntime.currentProfileId == beforeFailure.currentProfileId,
                "Launch failure restores original running profile after configuration rollback")
            if let unavailablePort {
                let beforePortEdit: SettingsValue = try await api.value("/api/settings")
                var occupiedInbound = beforePortEdit["inbound"]
                occupiedInbound["localPort"] = .number(Double(unavailablePort))
                occupiedInbound["secondLocalPortEnabled"] = .bool(false)
                occupiedInbound["newPort4LAN"] = .bool(false)
                do {
                    try await api.send("/api/settings/inbound", method: "PUT", body: occupiedInbound)
                    throw ClientFailure("occupied_port_accepted")
                } catch let error as ClientFailure {
                    try require(error.code == "settings_core_apply_failed", "Occupied fixture port rejects runtime settings apply")
                }
                let afterPortEdit: SettingsValue = try await api.value("/api/settings")
                let afterPortFailure: RuntimeStatus = try await api.value("/api/status")
                try require(afterPortEdit["inbound"] == beforePortEdit["inbound"], "Preflight failure restores persisted inbound settings")
                try require(afterPortFailure.coreRunning && afterPortFailure.coreSessionID == restoredRuntime.coreSessionID,
                    "Preflight failure keeps healthy original core process")
            }
        }
        let status: RuntimeStatus = try await api.value("/api/status")
        try require(status.coreRunning == running, "Settings preserve stopped/running core intent")
    }
    static func run() async throws {
        let args = CommandLine.arguments
        if args.count == 5 && args[1] == "--serve-embedded-fixture", let descriptor = Int32(args[4]), descriptor >= 0 {
            let core = try EmbeddedXray(bundle: URL(fileURLWithPath: args[2]))
            let directory = URL(fileURLWithPath: args[3], isDirectory: true)
            let tunnel = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            while let action = readLine() {
                switch action {
                case "proxy", "tun":
                    let file = directory.appendingPathComponent(action + ".json")
                    let config = try JSONDecoder().decode(SettingsValue.self, from: Data(contentsOf: file))
                    do { try await core.start(config: config, assets: directory, tunnel: action == "tun" ? tunnel : nil) }
                    catch let failure as ClientFailure {
                        if let detail = failure.detail { FileHandle.standardError.write(Data((detail + "\n").utf8)) }
                        throw failure
                    }
                case "stop": try await core.stop()
                default: throw ClientFailure("fixture_command_invalid")
                }
                let version = core.version.components(separatedBy: .newlines).first ?? ""
                let response: SettingsValue = .object(["action": .string(action), "pid": .number(Double(getpid())), "version": .string(version)])
                FileHandle.standardOutput.write(try JSONEncoder().encode(response) + Data([10]))
            }
            try await core.stop()
            return
        }
        if args.count == 7 && args[1] == "--check-geo-fixture",
           let server = Int(args[4]), let proxy = Int(args[5]), let peer = Int(args[6]) {
            try await checkGeoFixture(bundle: URL(fileURLWithPath: args[2]), data: URL(fileURLWithPath: args[3]),
                                      serverPort: server, proxyPort: proxy, peerPort: peer)
            return
        }
        if args.count == 6 && args[1] == "--check-custom-fixture", let target = Int(args[4]), let inbound = Int(args[5]) {
            try await checkCustomFixture(bundle: URL(fileURLWithPath: args[2]), data: URL(fileURLWithPath: args[3]), target: target, inbound: inbound)
            return
        }
        if args.count == 4 && args[1] == "--serve-group-edit-fixture" {
            try await serveGroupEditFixture(bundle: URL(fileURLWithPath: args[2]), data: URL(fileURLWithPath: args[3]))
            return
        }
        if args.count == 5 && args[1] == "--serve-host-fixture" {
            try await serveHostFixture(data: URL(fileURLWithPath: args[2]), node: args[3],
                                       bundle: URL(fileURLWithPath: args[4]))
            return
        }
        if args.count == 4 && args[1] == "--export-fixture" {
            let store = NativeConfigurationStore(dataDirectory: URL(fileURLWithPath: args[2]))
            let documents = try await store.exportProfiles(.object(["profileIds": .array([.string(args[3])]),
                "includeInnerUri": .bool(true), "includeClientConfig": .bool(true)]), metricsPort: 59280)
            FileHandle.standardOutput.write(try JSONEncoder().encode(documents))
            return
        }
        if args.count == 4 && ["--generate-client", "--generate-tun-client"].contains(args[1]) {
            let store = NativeConfigurationStore(dataDirectory: URL(fileURLWithPath: args[2], isDirectory: true))
            let config = try await store.generateXrayConfiguration(nodeID: args[3], metricsPort: nil,
                tunnelInterface: args[1] == "--generate-tun-client" ? "utun9999" : nil)
            FileHandle.standardOutput.write(try JSONEncoder().encode(config))
            return
        }
        guard args.count == 6, let fixturePort = Int(args[3]),
              let proxyPort = Int(args[4]), let socksPort = Int(args[5]) else {
            fatalError("V2rayMCheck <app> <temporary-data> <http-fixture-port> <proxy-port> <socks-fixture-port>")
        }
        let bundle = URL(fileURLWithPath: args[1]), data = URL(fileURLWithPath: args[2])
        let backend = NativeRuntimeHost(bundle: bundle, dataDirectory: data, mayContactHelper: false, automaticMaintenance: false)
        do {
            let api = try await backend.startClient()
            async let initial: RuntimeStatus = api.value("/api/status")
            async let nodes: [Profile] = api.value("/api/profiles")
            async let subscriptions: [Subscription] = api.value("/api/subscriptions")
            let baseline = try await (initial, nodes, subscriptions)
            let lazyCore = !(0..<_dyld_image_count()).contains { index in
                _dyld_get_image_name(index).map { String(cString: $0).hasSuffix("/libV2rayMXray.dylib") } ?? false
            }
            try require(lazyCore && baseline.0.xrayAvailable && baseline.0.installedXrayVersion != nil,
                        "Cold status reads the packaged version without mapping the Go library")
            try require(!baseline.0.coreRunning && baseline.1.isEmpty && baseline.2.isEmpty, "Fresh data isolation")
            let tunnel = try await api.tunStatus()
            try require(tunnel.platformSupported && !tunnel.enabled && !tunnel.isRunning,
                        "TUN status distinguishes saved mode from a running tunnel")
            try await api.setTunEnabled(false)
            let disabled = try await api.tunStatus()
            try require(!disabled.enabled && disabled.privilegedCoreProcessIds.isEmpty,
                        "TUN can be disabled through the native API without starting a core")
            let collision = NativeRuntimeHost(bundle: bundle, dataDirectory: data, mayContactHelper: false, automaticMaintenance: false)
            do { _ = try await collision.startClient(); throw ClientFailure("collision_not_rejected") }
            catch let failure as ClientFailure { try require(failure.code == "runtime_data_in_use", "Duplicate owner rejected") }
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
            let copiedProfileId = try await checkProfileCatalog(api, group: group, profiles: profiles)
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
                try await api.saveProfile(id: item.id, original: original, edited: try draft.validated())
                let saved: SettingsValue = try await api.value(path)
                try require(saved["remarks"].text == "Edited node fixture" && saved["transportExtra"] == draft.value["transportExtra"], "Node editor saves identity and transport fields")
                var retired = saved; retired["coreType"] = .number(24)
                do {
                    try await api.saveProfile(id: item.id, original: saved, edited: retired)
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
                if firstCoreLog == nil {
                    try await api.perform("/api/core/start")
                    let repeated: RuntimeStatus = try await api.value("/api/status")
                    try require(repeated.coreSessionID == status.coreSessionID, "Starting the serving node is idempotent")
                    try await api.perform("/api/profiles/\(item.id)/select")
                    let reselected: RuntimeStatus = try await api.value("/api/status")
                    try require(reselected.coreSessionID != nil && reselected.coreSessionID == status.coreSessionID,
                                "Selecting the already serving node preserves its connections")
                    do {
                        try await api.perform("/api/profiles/\(item.id)/select?connect=false")
                        throw ClientFailure("running_selection_without_connect_accepted")
                    } catch let failure as ClientFailure {
                        try require(failure.code == "core_selection_requires_stop", "Selection without connecting requires a stopped core")
                    }
                    do {
                        try await api.perform("/api/profiles/missing-\(UUID().uuidString)/select")
                        throw ClientFailure("missing_node_selection_accepted")
                    } catch let failure as ClientFailure {
                        try require(failure.code == "profile_not_found", "Missing node selection fails clearly")
                    }
                    let unchanged: RuntimeStatus = try await api.value("/api/status")
                    try require(unchanged.coreSessionID == status.coreSessionID && unchanged.currentProfileId == item.id,
                        "Rejected selection preserves the serving core and selected node")
                }
                let editPath = "/api/profiles/\(item.id)"
                var runningEdit: SettingsValue = try await api.value(editPath)
                let originalEdit = runningEdit
                let preservedTransport = runningEdit["transportExtra"]
                runningEdit["remarks"] = .string("Running edit " + item.id)
                try await api.saveProfile(id: item.id, original: originalEdit, edited: runningEdit)
                let editedStatus: RuntimeStatus = try await api.value("/api/status")
                let editedDocument: SettingsValue = try await api.value(editPath)
                try require(editedStatus.coreRunning && editedStatus.currentProfileId == item.id
                    && editedStatus.coreSessionID == status.coreSessionID
                    && editedStatus.runningProfileName == runningEdit["remarks"].text
                    && editedDocument["remarks"] == runningEdit["remarks"]
                    && editedDocument["transportExtra"] == preservedTransport,
                    "Renaming the serving node updates its live name and preserves the session and transport fields")
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
            try await checkSettings(api, running: true, unavailablePort: fixturePort)
            var hasTrafficSample = false
            var trafficDiagnostic = ""
            for _ in 0..<40 {
                let sampled: RuntimeStatus = try await api.value("/api/status")
                trafficDiagnostic = "enabled=\(String(describing: sampled.trafficEnabled)), running=\(sampled.coreRunning), "
                    + "sample=\(String(describing: sampled.traffic)), parsedAt=\(String(describing: DashboardStatus.date(sampled.traffic?.sampledAt))), now=\(Date())"
                if sampled.trafficEnabled == true, let rates = sampled.traffic?.rates(at: Date()), rates.allSatisfy({ $0 >= 0 }) {
                    hasTrafficSample = true; break
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            try require(hasTrafficSample, "Dashboard receives fresh nonnegative Xray traffic rates with sampling interval; " + trafficDiagnostic)
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
            let beforePinCheck: RuntimeStatus = try await api.value("/api/status")
            do {
                try await api.perform("/api/core-updates/Xray/update")
                throw ClientFailure("fixture_unexpected_update")
            } catch let error as ClientFailure where error.code == "xray_bundled_with_app" {}
            let afterPinCheck: RuntimeStatus = try await api.value("/api/status")
            try require(afterPinCheck.coreRunning && beforePinCheck.coreSessionID == afterPinCheck.coreSessionID,
                        "Standalone Xray update refused while the bundled process keeps serving")
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
                        && before.coreSessionID != after.coreSessionID, "Serving core reloads after \(scope) replacement")
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
            try await api.perform("/api/profiles/\(copiedProfileId)/select")
            try await api.send("/api/profiles", method: "DELETE", body: ProfileIDs([copiedProfileId]))
            let afterRemoval: RuntimeStatus = try await api.value("/api/status")
            let afterRemovalNodes: [Profile] = try await api.value("/api/profiles?subscriptionId=")
            try require(afterRemoval.coreRunning && afterRemoval.currentProfileId != copiedProfileId
                && !afterRemovalNodes.contains(where: { $0.id == copiedProfileId }), "Delete running node and restart a remaining node")
            try await api.perform("/api/core/stop")
            if let manual = profiles.first(where: { $0.subscriptionId?.isEmpty != false }) {
                try await api.send("/api/profiles", method: "DELETE", body: ProfileIDs([manual.id]))
            }
            try await api.perform("/api/subscriptions/\(group.id)", method: "DELETE")
            let remaining: [Subscription] = try await api.value("/api/subscriptions")
            try require(remaining.isEmpty, "Delete subscription")
            let remainingNodes: [Profile] = try await api.value("/api/profiles?subscriptionId=")
            try require(remainingNodes.isEmpty, "Delete manual and subscription nodes")
            try await backend.stop()
            let reopened = try await collision.startClient()
            let renewed: RuntimeStatus = try await reopened.value("/api/status")
            try require(!renewed.coreRunning, "A new native host reopens the data after shutdown")
            try await collision.stop()
            let alive = await backend.isRunning; try require(!alive, "Owned runtime graceful exit")
            print("Native integration passed: process ownership, subscriptions, nodes, settings, Xray traffic and shutdown.")

        } catch {
            try? await backend.stop(); throw error
        }
    }
    static func require(_ condition: Bool, _ label: String) throws {
        guard condition else { throw ClientFailure("check_failed", label) }
        print("PASS: \(label)")
    }
}
struct Inbound: Encodable {
    var localPort: Int
    let secondLocalPortEnabled = false, udpEnabled = true, sniffingEnabled = false
    let destOverride = ["http", "tls"], routeOnly = false, allowLANConn = false, newPort4LAN = false
}
