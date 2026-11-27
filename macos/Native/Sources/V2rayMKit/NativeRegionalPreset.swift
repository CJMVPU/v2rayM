import Foundation

public struct RegionalSources: Sendable {
    let dnsBase: String
    let routingTemplate: String
    let geoPattern: String

    public init(dnsBase: String, routingTemplate: String, geoPattern: String) {
        self.dnsBase = dnsBase
        self.routingTemplate = routingTemplate
        self.geoPattern = geoPattern
    }

    static func standard(_ region: String) throws -> Self {
        let repository: String
        let dataset: String
        switch region {
        case "default": return Self(dnsBase: "", routingTemplate: "", geoPattern: "")
        case "russia":
            repository = "runetfreedom/russia-v2ray-custom-routing-list"
            dataset = "runetfreedom/russia-v2ray-rules-dat"
        case "iran":
            repository = "Chocolate4U/Iran-v2ray-rules"
            dataset = repository
        default: throw ClientFailure("regional_preset_invalid")
        }
        let base = "https://raw.githubusercontent.com/" + repository + "/main/v2rayN/"
        return Self(dnsBase: base, routingTemplate: base + "template.json",
                    geoPattern: "https://github.com/" + dataset + "/releases/latest/download/{0}.dat")
    }
}

struct RegionalSnapshot: Equatable {
    let routes: [SettingsValue]
    let dns: SettingsValue
    let simple: SettingsValue
    let routing: SettingsValue
    let geoURL: SettingsValue
    let routeURL: SettingsValue
}

struct RegionalRoutingPlan {
    var additions: [SettingsValue] = []
    var remove: String?
    var activate: String?
    var useFirst = false
    var clearLegacy = false
}

struct NativeRegionalPreset {
    let fetch: @Sendable (String) async throws -> String
    let builtins: [SettingsValue]
    let defaultDNS: SettingsValue

    private func content(_ address: String) async throws -> String? {
        guard !address.isEmpty else { return nil }
        do { return try await fetch(address) }
        catch { try Task.checkCancellation(); return nil }
    }

    private func object(_ address: String) async throws -> SettingsValue? {
        guard let text = try await content(address), let parsed = try? SettingsValue.parse(text), case .object = parsed else { return nil }
        return parsed
    }

    // Upstream templates may use either .NET property names or camelCase JSON.
    private func field(_ object: SettingsValue, _ key: String) -> SettingsValue {
        guard case .object(let fields) = object else { return .null }
        return fields[key] ?? fields.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value ?? .null
    }

    func routes(source: String, base: RegionalSnapshot, explicitImport: Bool) async throws -> RegionalRoutingPlan {
        // The default region resets DNS and Geo sources while preserving the user's routes.
        if source.isEmpty && !explicitImport { return RegionalRoutingPlan() }
        if let template = try await object(source), !field(template, "Version").text.isEmpty,
           case .array(let entries) = field(template, "RoutingItems") {
            let version = field(template, "Version").text
            if !explicitImport && base.routes.contains(where: { $0["remarks"].text.hasPrefix(version + "-") }) { return RegionalRoutingPlan() }
            var plan = RegionalRoutingPlan()
            for entry in entries {
                try Task.checkCancellation()
                let inline = field(entry, "RuleSet")
                var rules = inline.text
                if case .array = inline { rules = try inline.json() }
                if rules.isEmpty { rules = try await content(field(entry, "Url").text) ?? "" }
                guard let list = try? NativeConfigurationStore.parseRoutingRules(rules), list.items.allSatisfy({ if case .object = $0 { true } else { false } }) else { continue }
                var item: SettingsValue = .object(["remarks": .string(version + "-" + field(entry, "Remarks").text),
                                                    "ruleSet": .string(rules), "enabled": .bool(true)])
                for key in ["domainStrategy","locked","customIcon"] { item[key] = field(entry, key) }
                plan.additions.append(item)
            }
            plan.useFirst = !explicitImport
            return plan
        }
        var plan = RegionalRoutingPlan()
        plan.remove = base.routes.first { $0["locked"].flag }?["id"].text
        let remaining = base.routes.filter { $0["id"].text != plan.remove }
        if explicitImport || remaining.isEmpty {
            plan.additions = builtins
            plan.useFirst = !explicitImport
        } else {
            let previous = base.routing["RoutingIndexId"].text
            plan.clearLegacy = !previous.isEmpty
            plan.activate = remaining.first { $0["id"].text == previous }?["id"].text
        }
        return plan
    }

    func dns(region: String, sources: RegionalSources, existing: SettingsValue) async throws -> (simple: SettingsValue, profile: SettingsValue) {
        guard region != "default" else { return (defaultDNS, .object(["remarks": .string("V2ray"), "enabled": .bool(false)])) }
        async let simpleDownload = object(sources.dnsBase + "simple_dns.json")
        async let profileDownload = object(sources.dnsBase + "v2ray.json")
        let (simple, remote) = try await (simpleDownload, profileDownload)
        var profile = existing
        if let remote {
            for column in CoreConfigurationProfile.dns.columns where column != "Enabled" && column != "Remarks" {
                let key = column.prefix(1).lowercased() + column.dropFirst()
                let value = field(remote, column)
                if ["NormalDNS","TunDNS"].contains(column), !value.text.isEmpty {
                    profile[key] = .string(try await content(value.text) ?? "")
                } else { profile[key] = value }
            }
        }
        if simple == nil { profile["enabled"] = .bool(true) }
        var result = defaultDNS
        if case .object(let fields) = simple, case .object(let defaults) = defaultDNS {
            // Missing optional fields use the model's empty defaults, not the built-in preset's populated values.
            for key in defaults.keys {
                if let match = fields.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) { result[key] = match.value }
                else { result[key] = .null }
            }
        }
        return (result, profile)
    }
}

extension NativeConfigurationStore {
    func regionSnapshot() throws -> RegionalSnapshot {
        let settings = try readSettings()
        return try RegionalSnapshot(routes: routeDocuments(), dns: coreConfigurationProfiles(.dns).first ?? .null,
                                    simple: settings["SimpleDNSItem"], routing: settings["RoutingBasicItem"],
                                    geoURL: settings["ConstItem"]["GeoSourceUrl"], routeURL: settings["ConstItem"]["RouteRulesTemplateSourceUrl"])
    }

    func presetStager(proxyEndpoints: ProxyEndpoints?) throws -> NativeRegionalPreset {
        let embedded = try [("white","绕过大陆(Whitelist)"),("black","黑名单(Blacklist)"),("global","全局(Global)")].map { file, label in
            SettingsValue.object(["remarks": .string("V4-" + label), "enabled": .bool(true), "ruleSet": .string(try builtin(file).json())])
        }
        return try NativeRegionalPreset(fetch: { address in
            let url = try SubscriptionDownload.address(address)
            return try await SubscriptionDownload.download(URLRequest(url: url, timeoutInterval: 30), proxyEndpoints: proxyEndpoints)
        }, builtins: embedded, defaultDNS: builtin("settings")["SimpleDNSItem"])
    }

    func importRoutes(_ plan: RegionalRoutingPlan) throws {
        if let remove = plan.remove { try selectRoute(remove, delete: true) }
        var first: String?
        for route in plan.additions {
            try Task.checkCancellation()
            let id = try saveRoute(route)
            if first == nil { first = id }
        }
        if let id = plan.useFirst ? first : plan.activate { try selectRoute(id, delete: false) }
        if plan.clearLegacy {
            var settings = try readSettings()
            settings["RoutingBasicItem"]["RoutingIndexId"] = .string("")
            try writeSettings(settings)
        }
    }

    func applyRegion(sources: RegionalSources, dns: (simple: SettingsValue, profile: SettingsValue), routes: RegionalRoutingPlan) throws {
        _ = try saveCoreConfigurationProfile(.dns, input: dns.profile)
        try importRoutes(routes)
        var settings = try readSettings()
        settings["SimpleDNSItem"] = dns.simple
        settings["ConstItem"]["GeoSourceUrl"] = .string(sources.geoPattern)
        settings["ConstItem"]["RouteRulesTemplateSourceUrl"] = .string(sources.routingTemplate)
        try writeSettings(settings)
    }
}
