import Foundation
import V2rayMKit

extension NativeCheck {
    static func checkGeoFixture(bundle: URL, data: URL, serverPort: Int, proxyPort: Int, peerPort: Int) async throws {
        let store = NativeConfigurationStore(dataDirectory: data)
        try await store.initializeRuntimeStore()
        let path = data.appendingPathComponent("guiConfigs/guiNConfig.json")
        var settings = try JSONDecoder().decode(SettingsValue.self, from: Data(contentsOf: path))
        settings["ConstItem"]["GeoSourceUrl"] = .string("http://127.0.0.1:" + String(serverPort) + "/dat/{0}.dat")
        settings["ConstItem"]["RouteRulesTemplateSourceUrl"] = .string("http://127.0.0.1:" + String(serverPort) + "/hold-routes")
        settings["CheckUpdateItem"]["UpdateViaProxy"] = .bool(false)
        try JSONEncoder().encode(settings).write(to: path, options: .atomic)
        let sources = Dictionary(uniqueKeysWithValues: ["russia","iran","default"].map { region in
            let url = "http://127.0.0.1:" + String(serverPort) + "/regional/" + region + "/"
            return (region, RegionalSources(dnsBase: url, routingTemplate: url + "template.json", geoPattern: url + "{0}.dat"))
        })
        let host = NativeRuntimeHost(bundle: bundle, dataDirectory: data, mayContactHelper: false, automaticMaintenance: false, presetSources: sources)
        try await host.start()
        do {
            try await host.saveSettings(.inbound, NativeCheck.fixtureInbound(port: proxyPort))
            try await host.importProfiles("socks://127.0.0.1:" + String(peerPort) + "#Local", group: "", isSubscription: false)
            let profiles = try await host.profileMetadata()
            guard let id = profiles.first?.id else { throw ClientFailure("fixture_missing") }
            try await host.selectProfile(id, connect: true)
            let before: RuntimeStatus = try await host.runtimeStatus()
            func waitForUpdate() async throws -> ModuleUpdateProgress {
                for _ in 0..<400 {
                    if let terminal = try await host.geoUpdateProgress(), terminal.isComplete { return terminal }
                    try await Task.sleep(for: .milliseconds(100))
                }
                throw ClientFailure("geo_fixture_timeout")
            }
            func update() async throws -> ModuleUpdateProgress {
                try await host.submitGeoUpdate(useProxy: false)
                return try await waitForUpdate()
            }
            let success = try await update()
            try require(success.success, "Loopback Geo download and Xray DAT validation: " + (success.detail ?? success.phase))
            let after: RuntimeStatus = try await host.runtimeStatus()
            try require(after.coreRunning && after.coreSessionID != before.coreSessionID && after.runningProfileId == before.runningProfileId,
                        "Updated Geo data starts a replacement core on the same node")
            let marker = data.appendingPathComponent("native-geo/current")
            let installed = try Data(contentsOf: marker)
            func waitForMarker(_ name: String) async throws {
                let url = data.appendingPathComponent(name)
                for _ in 0..<200 {
                    if FileManager.default.fileExists(atPath: url.path) { return }
                    try await Task.sleep(for: .milliseconds(50))
                }
                throw ClientFailure("fixture_marker_timeout", name)
            }
            try await host.submitGeoUpdate(useProxy: false)
            try await waitForMarker("fixture-busy-geo-start")
            do {
                try await host.submitGeoUpdate(useProxy: nil)
                throw ClientFailure("fixture_accepted_duplicate_geo_update")
            } catch let failure as ClientFailure where failure.code == "core_update_busy" {}
            let inFlight = try await host.geoUpdateProgress()
            try require(inFlight?.phase == "downloading" && inFlight?.isComplete == false,
                        "Duplicate submission preserves the active Geo download")
            let downloading = try await host.activeOperations()
            try require(downloading == ["geo-update"], "Active operations report the held Geo download")
            let routeImport = Task { try await host.importRoutes() }
            try await waitForMarker("fixture-route-start")
            let overlapping = try await host.activeOperations()
            try require(overlapping == ["settings", "geo-update"], "Active operations report the routing edit before the concurrent Geo download")
            try Data().write(to: data.appendingPathComponent("fixture-busy-geo-release"))
            var waiting = false
            for _ in 0..<200 {
                if let update = try await host.geoUpdateProgress(), update.phase == "waiting-to-apply" || update.isComplete {
                    waiting = update.phase == "waiting-to-apply" && !update.isComplete
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            try Data().write(to: data.appendingPathComponent("fixture-route-release"))
            try await routeImport.value
            try require(waiting, "Validated Geo candidate waits for the running route import")
            let repeated = try await waitForUpdate()
            // Progress becomes terminal just before the background task releases ownership.
            let deadline = ContinuousClock.now + .seconds(2)
            var remaining = try await host.activeOperations()
            while !remaining.isEmpty && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
                remaining = try await host.activeOperations()
            }
            try require(remaining.isEmpty, "Active operations clear after both the routing edit and Geo download finish")
            let unchanged: RuntimeStatus = try await host.runtimeStatus()
            let sameGeneration = try Data(contentsOf: marker)
            try require(repeated.success && unchanged.coreRunning && unchanged.coreSessionID == after.coreSessionID && sameGeneration == installed,
                        "Repeated identical Geo pair preserves its generation and serving session")
            let failed = try await update()
            let recovered: RuntimeStatus = try await host.runtimeStatus()
            let kept = try Data(contentsOf: marker)
            try require(!failed.success && recovered.coreSessionID == after.coreSessionID && installed == kept,
                        "Damaged Geo download preserves the active dataset and serving process")
            let incompatible = try await update()
            let restored: RuntimeStatus = try await host.runtimeStatus()
            let rolledBack = try Data(contentsOf: marker)
            try require(!incompatible.success && restored.coreRunning && restored.runningProfileId == before.runningProfileId
                && restored.coreSessionID != recovered.coreSessionID && rolledBack == installed,
                "Valid datasets missing live routing tags restore the original files and relaunch the serving node")
            try await host.submitGeoUpdate(useProxy: false)
            let started = data.appendingPathComponent("fixture-geo-started")
            for _ in 0..<200 where !FileManager.default.fileExists(atPath: started.path) {
                try await Task.sleep(for: .milliseconds(50))
            }
            try require(FileManager.default.fileExists(atPath: started.path), "Fixture received the pending Geo request")
            let newSource = "http://127.0.0.1:" + String(serverPort) + "/changed/{0}.dat"
            try await host.saveSettings(.application, .object(["geoSourceUrl": .string(newSource)]))
            try Data().write(to: data.appendingPathComponent("fixture-geo-release"))
            let superseded = try await waitForUpdate()
            let keptSession: RuntimeStatus = try await host.runtimeStatus()
            let keptGeneration = try Data(contentsOf: marker)
            try require(!superseded.success && superseded.detail == "geo_update_source_changed"
                        && keptSession.coreSessionID == restored.coreSessionID && keptGeneration == installed,
                        "Changing the Geo source discards the pending pair and preserves the serving session")
            try await checkBackupFixture(host, server: serverPort, proxy: proxyPort)
            try await checkRegionalFixture(host, data: data, nodeID: id, server: serverPort, proxy: proxyPort)
            try await host.stop()
        } catch { try await host.stop(); throw error }
    }
}

extension NativeCheck {
    static func checkRegionalFixture(_ api: NativeRuntimeHost, data: URL, nodeID: String, server: Int, proxy: Int) async throws {
        let marker = data.appendingPathComponent("native-geo/current")
        let file = data.appendingPathComponent("guiConfigs/guiNConfig.json")
        let old: RuntimeStatus = try await api.runtimeStatus()
        try await api.applyRegion("russia")
        let applied: RuntimeStatus = try await api.runtimeStatus()
        let current: SettingsValue = try await api.routeDocuments()
        try require(applied.runningProfileId == nodeID && applied.coreSessionID != old.coreSessionID &&
                    current.items.contains { $0["isActive"].flag && $0["remarks"].text == "russia-loopback" },
                    "Regional preset activates its downloaded routing profile and restarts the same node")
        try checkLoopbackHTTP(server: server, proxy: proxy, label: "Regional route forwards real HTTP after Geo and DNS activation")

        try await api.importRoutes()
        let imported: SettingsValue = try await api.routeDocuments()
        try require(imported.items.count == current.items.count + 1 &&
                    imported.items.first(where: { $0["isActive"].flag }) == current.items.first(where: { $0["isActive"].flag }),
                    "Explicit template import appends routes and preserves the active choice")
        let generation = try Data(contentsOf: marker)
        let settings = try SettingsValue.parse(String(contentsOf: file, encoding: .utf8))
        let dns: SettingsValue = try await api.configurationProfiles(.dns)
        do {
            try await api.applyRegion("iran")
            throw ClientFailure("fixture_invalid_preset_accepted")
        } catch let failure as ClientFailure where ["core_config_invalid","core_start_failed"].contains(failure.code) {}
        let remaining: SettingsValue = try await api.routeDocuments()
        let restoredDNS: SettingsValue = try await api.configurationProfiles(.dns)
        let state: RuntimeStatus = try await api.runtimeStatus()
        let restoredSettings = try SettingsValue.parse(String(contentsOf: file, encoding: .utf8))
        let restoredGeneration = try Data(contentsOf: marker)
        try require(remaining == imported && settings == restoredSettings && dns == restoredDNS &&
                    restoredGeneration == generation && state.runningProfileId == nodeID && state.coreRunning,
                    "Rejected regional route restores DNS, all routes, Geo generation and running node")
        try checkLoopbackHTTP(server: server, proxy: proxy, label: "Original node forwards real HTTP after regional rollback")
    }
}
