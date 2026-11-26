import Foundation
import Darwin

struct XrayClientConfiguration {
    let settings: SettingsValue
    let route: SettingsValue
    let customDNS: SettingsValue
    let template: SettingsValue
    let systemHosts: [String: String]
    var nodes: [SettingsValue]

    var subscriptions: [String: SettingsValue] = [:]
    var profileDirectory: URL?

    func generate(for node: SettingsValue, metricsPort: Int?, logDirectory: URL, at date: Date,
                  tunnelInterface: String? = nil, hasGlobalIPv6: Bool = false, diagnosticID: UUID? = nil) throws -> SettingsValue {
        let basic = settings["CoreBasicItem"]
        let bind = basic["BindInterface"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        if node["configType"].text == "custom" {
            guard node["coreType"] == .null || node["coreType"].text == "xray" else { throw ClientFailure("xray_only_profile_required") }
            guard tunnelInterface == nil else { throw ClientFailure("mac_tun_generated_core_required") }
            return try XrayFileProfile.document(node, directory: profileDirectory)
        }
        let graph = XrayProfileGraph(nodes: nodes, subscriptions: subscriptions)
        var groupRouting = XrayGroupRouting()
        var registeredNodes = [SettingsValue]()
        var hops = [XrayProfileGraph.Hop]()
        var entryTags = Set<String>()
        func appendGroup(_ profile: SettingsValue, tag: String) throws {
            let added = try graph.expand(graph.root(profile), tag: tag)
            let entries = added.filter { $0.tag.hasPrefix(tag) }
            entryTags.formUnion(entries.map(\.tag))
            if entries.count > 1 {
                try groupRouting.register(profile, prefix: tag, pingURL: settings["SpeedTestItem"]["SpeedPingTestUrl"])
            }
            registeredNodes += added.sorted { $0.memberOrder.lexicographicallyPrecedes($1.memberOrder) }.map(\.node)
            hops += added
        }
        try appendGroup(node, tag: "proxy")
        let primaryCount = hops.count
        var routedIDs = Set<String>()
        var routing: SettingsValue = try diagnosticID != nil ? .object([:]) : XrayRouting.generate(config: settings, profile: route,
                                              tunProcesses: tunnelInterface == nil ? nil : ["xray/", "self/"]) { name, id in
            let other = try graph.targets.node(id: id, name: name)
            let index = other["indexId"].text
            let tag = index + "-proxy-" + other["remarks"].text
            if routedIDs.insert(index).inserted { try appendGroup(other, tag: tag) }
            return tag
        }
        if !groupRouting.balancers.isEmpty {
            routing["balancers"] = .array(groupRouting.balancers)
            routing["rules"] = .array(XrayGroupRouting.rules(routing["rules"].items, matching: groupRouting.tags))
        }
        let usedNodes = hops.map(\.node)
        var proxies = try hops.map { hop -> SettingsValue in
            if hop.node["configType"].text == "outbound" { return .object(["tag": .string(hop.tag)]) }
            var outbound = try XrayOutbound(node: hop.node, config: settings).build(tag: hop.tag)
            if let via = hop.via { XrayFileProfile.setSocketOption("dialerProxy", via, on: &outbound) }
            return outbound
        }
        guard let listener = settings["Inbound"].items.first else { throw ClientFailure("invalid_port") }
        let simple = settings["SimpleDNSItem"]
        let fake = !customDNS["Enabled"].flag && simple["FakeIP"].flag
        var inbounds = try XrayInbound.mixed(settings: listener, fakeDNS: fake, usingTunnel: tunnelInterface != nil, node: node)
        if let tunnelInterface {
            let local = try XrayInbound.mixed(settings: listener, fakeDNS: fake, usingTunnel: false, node: node)
            let tun = try XrayInbound.tunnel(settings: settings["TunModeItem"], interface: tunnelInterface, bindInterface: bind,
                                             hasGlobalIPv6: hasGlobalIPv6, sniffing: local[0]["sniffing"])
            inbounds.append(tun)
        }
        var log: SettingsValue = .object(["loglevel": basic["Loglevel"]])
        if basic["LogEnabled"].flag {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            let day = formatter.string(from: date)
            log["access"] = .string(logDirectory.appendingPathComponent("Vaccess_" + day + ".txt").path)
            log["error"] = .string(logDirectory.appendingPathComponent("Verror_" + day + ".txt").path)
        }
        var direct: SettingsValue = .object(["tag": .string("direct"), "protocol": .string("freedom")])
        let rawDNS = customDNS["Enabled"].flag
        let directStrategy = rawDNS ? customDNS["DomainStrategy4Freedom"].text : simple["Strategy4Freedom"].text
        func applyStrategy(_ strategy: String, to outbound: inout SettingsValue) {
            outbound["streamSettings"]["sockopt"]["domainStrategy"] = .string(strategy)
            guard !rawDNS, simple["EnableHappyEyeballs"].flag else { return }
            let happy = settings["HappyEyeballs4RayItem"]
            for name in ["TryDelayMs","PrioritizeIPv6","Interleave","MaxConcurrentTry"] where happy[name] != .null {
                let key = name.prefix(1).lowercased() + name.dropFirst()
                outbound["streamSettings"]["sockopt"]["happyEyeballs"][key] = happy[name]
            }
        }
        if !directStrategy.isEmpty && (rawDNS || directStrategy != "AsIs") { applyStrategy(directStrategy, to: &direct) }
        let templateText = template[tunnelInterface == nil ? "Config" : "TunConfig"].text
        let templateTags = template["Enabled"].flag ? (try? SettingsValue.parse(templateText))?["outbounds"].items.map { $0["tag"].text } ?? [] : []
        var privateTags = XrayCustomOutboundTags(reserving: Set(hops.map(\.tag) + templateTags + ["direct", "block", "dns"]))
        var expanded = [[SettingsValue]]()
        for index in proxies.indices {
            let proxyStrategy = simple["Strategy4Proxy"].text, dial = simple["Strategy4ProxyDial"].text
            if !rawDNS && !proxyStrategy.isEmpty && proxyStrategy != "AsIs" { proxies[index]["targetStrategy"] = .string(proxyStrategy) }
            if !rawDNS && !dial.isEmpty && dial != "AsIs" { applyStrategy(dial, to: &proxies[index]) }
            let host = usedNodes[index]["address"].text.lowercased()
            var address = in_addr(), address6 = in6_addr()
            let local = host == "localhost" || (inet_pton(AF_INET, host, &address) == 1 && UInt32(bigEndian: address.s_addr) >> 24 == 127)
                || (inet_pton(AF_INET6, host, &address6) == 1 && withUnsafeBytes(of: &address6) { Array($0) == Array(repeating: UInt8(0), count: 15) + [1] })
            let physical = !local && hops[index].via == nil
            if usedNodes[index]["configType"].text == "outbound" {
                guard usedNodes[index]["coreType"] == .null || usedNodes[index]["coreType"].text == "xray" else { throw ClientFailure("xray_only_profile_required") }
                let file = try XrayFileProfile.document(usedNodes[index], directory: profileDirectory)
                expanded.append(try XrayFileProfile.outbounds(file, tag: hops[index].tag, via: hops[index].via,
                                                              bind: physical ? bind : "", strategy: proxies[index]["targetStrategy"], tags: &privateTags))
                continue
            } else if physical {
                if !bind.isEmpty {
                    proxies[index]["streamSettings"]["sockopt"]["interface"] = .string(bind)
                    if case .object = proxies[index]["streamSettings"]["xhttpSettings"]["extra"]["downloadSettings"] {
                        proxies[index]["streamSettings"]["xhttpSettings"]["extra"]["downloadSettings"]["sockopt"]["interface"] = .string(bind)
                    }
                }
                if !basic["SendThrough"].text.isEmpty { proxies[index]["sendThrough"] = basic["SendThrough"] }
            }
            expanded.append([proxies[index]])
        }
        let fragment = XrayFragmentation(settings: settings, entryTags: entryTags)
        let primary = try fragment.apply(to: expanded.prefix(primaryCount).flatMap { $0 }[...])
        if let diagnosticID {
            return try NativeLatencyTest.privateConfiguration(primary, id: diagnosticID, group: groupRouting, pingURL: settings["SpeedTestItem"]["SpeedPingTestUrl"])
        }
        var outbounds = primary + [direct, .object(["tag": .string("block"), "protocol": .string("blackhole")])]
        if tunnelInterface != nil { outbounds.append(.object(["tag": .string("dns"), "protocol": .string("dns")])) }
        outbounds += try fragment.apply(to: expanded.dropFirst(primaryCount).flatMap { $0 }[...])
        var config: SettingsValue = .object(["log": log, "routing": routing, "inbounds": .array(inbounds), "outbounds": .array(outbounds)])
        for (key, value) in groupRouting.probes { config[key] = value }
        var domains: [String] = []
        func protect(_ host: String) {
            if XrayDNS.isDomain(host) && !domains.contains(host) { domains.append(host) }
        }
        for item in registeredNodes {
            if item["configType"].text != "outbound" { protect(item["address"].text) }
            let ech = item["echConfigList"].text
            if !ech.isEmpty {
                let name = ech.contains("://") && ech.contains("+") ? String(ech.prefix { $0 != "+" }) : item["sni"].text
                protect(name)
            }
            if let transport = try? SettingsValue.parse(item["transportExtra"].text),
               let extra = try? SettingsValue.parse(transport["XhttpExtra"].text) {
                protect(extra["downloadSettings"]["address"].text)
            }
        }
        try XrayDNS(simple: simple, custom: customDNS, protectedDomains: domains, systemHosts: systemHosts,
                    useTunnel: tunnelInterface != nil).apply(to: &config, routingProfile: route)
        if settings["GuiItem"]["EnableStatistics"].flag || settings["GuiItem"]["DisplayRealTimeSpeed"].flag {
            config["stats"] = .object([:])
            // Standalone exports can request an HTTP endpoint. Embedded serving reads the counters directly.
            if let metricsPort {
                guard (1...65535).contains(metricsPort) else { throw ClientFailure("invalid_port") }
                config["metrics"] = .object(["listen": .string("127.0.0.1:\(metricsPort)")])
            }
            config["policy"] = .object(["system": .object(["statsOutboundDownlink": .bool(true), "statsOutboundUplink": .bool(true)])])
        }
        if groupRouting.tags.contains("proxy-balancer") {
            var rule: SettingsValue = .object(["type": .string("field"), "balancerTag": .string("proxy-balancer")])
            if routing["domainStrategy"].text == "IPIfNonMatch" { rule["ip"] = .array([.string("0.0.0.0/0"), .string("::/0")]) }
            else { rule["network"] = .string("tcp,udp") }
            config["routing"]["rules"] = .array(config["routing"]["rules"].items + [rule])
        }
        return try applyTemplate(to: config, tunnel: tunnelInterface != nil)
    }

    private func applyTemplate(to generated: SettingsValue, tunnel: Bool) throws -> SettingsValue {
        let text = template[tunnel ? "TunConfig" : "Config"].text
        guard template["Enabled"].flag && !text.isEmpty else { return generated }
        var result = try SettingsValue.parse(text)
        guard case .object = result else { throw ClientFailure("core_template_invalid") }
        XrayGroupRouting.mergeTemplate(&result, generated: generated)
        var combined: [SettingsValue] = []
        for var outbound in generated["outbounds"].items {
            let builtin = ["direct","block","dns"].contains(outbound["tag"].text)
            if builtin && template["AddProxyOnly"].flag { continue }
            let detour = template["ProxyDetour"].text
            if !builtin && !detour.isEmpty && outbound["streamSettings"]["sockopt"]["dialerProxy"].text.isEmpty && outbound["proxySettings"]["tag"].text.isEmpty {
                outbound["streamSettings"]["sockopt"]["dialerProxy"] = .string(detour)
                if case .object = outbound["streamSettings"]["xhttpSettings"]["extra"]["downloadSettings"] {
                    outbound["streamSettings"]["xhttpSettings"]["extra"]["downloadSettings"]["sockopt"]["dialerProxy"] = .string(detour)
                }
            }
            combined.append(outbound)
        }
        result["outbounds"] = .array(combined + result["outbounds"].items)
        return result
    }
}
