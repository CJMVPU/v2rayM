import Foundation

/// The saved configuration uses the upstream property names. Each section edits only its own keys.
enum NativeSettings {
    private static let sections: [String:[(String,String)]] = [
        "inbound":[("Inbound","LocalPort SecondLocalPortEnabled UdpEnabled SniffingEnabled DestOverride RouteOnly AllowLANConn NewPort4LAN User Pass")],
        "core":[("CoreBasicItem","LogEnabled Loglevel DefFingerprint DefUserAgent SendThrough BindInterface EnableFragment EnableFinalFragment"),
                ("Mux4RayItem","Concurrency=mux4RayConcurrency XudpConcurrency=mux4RayXudpConcurrency XudpProxyUDP443=mux4RayXudpProxyUDP443"),
                ("HysteriaItem","UpMbps=hy2UpMbps DownMbps=hy2DownMbps"),
                ("Fragment4RayItem","Packets=fragmentPackets Lengths=fragmentLengths Delays=fragmentDelays MaxSplit=fragmentMaxSplit")],
        "application":[("GuiItem","EnableStatistics DisplayRealTimeSpeed KeepOlderDedupl AutoUpdateInterval=geoAutoUpdateInterval RootCertProvider"),
                       ("ConstItem","GeoSourceUrl RouteRulesTemplateSourceUrl SubConvertUrl")],
        "speedTest":[("SpeedTestItem","SpeedTestTimeout SpeedTestUrl SpeedPingTestUrl MixedConcurrencyCount IPAPIUrl=ipapiUrl UdpTestTarget")],
        "nativeTun":[("TunModeItem","Mtu EnableIPv6Address RouteExcludeAddress")],
        "simpleDNS":[("SimpleDNSItem","UseSystemHosts AddCommonHosts FakeIP GlobalFakeIp FakeIPRange BlockBindingQuery BlockAAAAQuery DirectDNS RemoteDNS BootstrapDNS Strategy4Freedom Strategy4Proxy Strategy4ProxyDial ServeStale ParallelQuery Hosts DirectExpectedIPs EnableHappyEyeballs")],
        "routing":[("RoutingBasicItem","DomainStrategy")],
        "webDAV":[("WebDavItem","Url UserName DirName")]
    ]
    static let mappings = [1:"vMess",2:"custom",3:"shadowsocks",4:"socks",5:"vless",6:"trojan",7:"hysteria2",9:"wireGuard"]

    private static func fields(_ section: String) -> [(group: String, key: String, label: String)] {
        (sections[section] ?? []).flatMap { group, keys in
            keys.split(separator:" ").map { token in
                let pair = token.components(separatedBy:"=")
                let key = pair[0]
                return (group,key,pair.count > 1 ? pair[1] : key.prefix(1).lowercased() + key.dropFirst())
            }
        }
    }

    static func section(_ section: String, from config: SettingsValue) -> SettingsValue {
        var result = SettingsValue.object([:])
        for (group,key,label) in fields(section) {
            let source = group == "Inbound" ? config[group].items.first ?? .null : config[group]
            result[label] = source[key]
            if ["fragmentLengths","fragmentDelays","routeExcludeAddress","destOverride"].contains(label), result[label] == .null { result[label] = .array([]) }
        }
        if section == "webDAV" { result["hasPassword"] = .bool(!config["WebDavItem"]["Password"].text.isEmpty) }
        return result
    }

    static func view(_ config: SettingsValue, options: SettingsValue) -> SettingsValue {
        let mappings = config["CoreTypeItem"].items.compactMap { item -> SettingsValue? in
            guard let id = Int(item["ConfigType"].text), let kind = Self.mappings[id] else { return nil }
            return .object(["configType": .string(kind), "coreType": .string("xray")])
        }
        return .object(["inbound":section("inbound",from:config),"core":section("core",from:config),"app":section("application",from:config),
                        "speedTest":section("speedTest",from:config),"domainStrategy":config["RoutingBasicItem"]["DomainStrategy"],
                        "coreTypes":.array(mappings),"options":options,"showIpInfoColumn":.bool(!config["SpeedTestItem"]["IPAPIUrl"].text.isEmpty && !config["UiItem"]["HideColumnIpInfo"].flag)])
    }

    static func applying(_ input: SettingsValue, section: String, to config: SettingsValue, options: SettingsValue) throws -> SettingsValue {
        guard case .object(let values) = input else { throw ClientFailure("settings_invalid") }
        var result = config
        if section == "apply" {
            for key in ["inbound","core","application","speedTest","nativeTun"] where values[key] != nil && values[key] != .null {
                result = try applying(input[key],section:key,to:result,options:options)
            }
            if let mappings = values["coreTypes"] { result = try applying(.object(["mappings":mappings]),section:"coreTypes",to:result,options:options) }
            if values["domainStrategy"] != nil { result = try applying(input,section:"routing",to:result,options:options) }
            return result
        }
        if section == "coreTypes" {
            guard case .array(let entries) = input["mappings"] else { throw ClientFailure("core_type_mapping_invalid") }
            var seen = Set<Int>()
            var existing = config["CoreTypeItem"].items
            for entry in entries {
                guard entry["coreType"].text.lowercased() == "xray",
                      let kind = mappings.first(where: { $0.value.lowercased() == entry["configType"].text.lowercased() })?.key,
                      seen.insert(kind).inserted else { throw ClientFailure("core_type_mapping_invalid") }
                if let i = existing.firstIndex(where: { $0["ConfigType"].text == String(kind) }) { existing[i]["CoreType"] = .number(2) }
                else { existing.append(.object(["ConfigType":.number(Double(kind)),"CoreType":.number(2)])) }
            }
            result["CoreTypeItem"] = .array(existing)
            return result
        }
        guard sections[section] != nil else { throw ClientFailure("settings_section_unknown") }
        let original = Self.section(section,from:config)
        var merged = original
        for (_,_,label) in fields(section) { if let value = values[label] { merged[label] = value } }
        try validate(&merged,section:section,options:options)
        for (group,key,label) in fields(section) {
            if merged[label] == original[label] { continue }
            if group == "Inbound" {
                var entries = result[group].items
                guard !entries.isEmpty else { throw ClientFailure("invalid_port") }
                entries[0][key] = merged[label]
                result[group] = .array(entries)
            } else { result[group][key] = merged[label] }
        }
        if section == "webDAV", let password = values["password"], case .string = password { result["WebDavItem"]["Password"] = password }
        return result
    }

    private static func validate(_ input: inout SettingsValue, section: String, options: SettingsValue) throws {
        func number(_ key: String) -> Int { Int(input[key].text) ?? -1 }
        func listed(_ key: String, _ list: String) -> Bool {
            options[list].items.contains { $0.text.caseInsensitiveCompare(input[key].text) == .orderedSame }
        }
        switch section {
        case "nativeTun":
            guard (1280...65535).contains(number("mtu")), case .array(let cidrs) = input["routeExcludeAddress"] else {
                throw ClientFailure("mac_tun_settings_invalid")
            }
            _ = try TunnelRouteSet.included(excluding: cidrs.map(\.text), ipv6:input["enableIPv6Address"].flag)
        case "inbound":
            let separate = input["allowLANConn"].flag && input["newPort4LAN"].flag
            let maximum = XrayInbound.maximumBasePort(secondLocal: input["secondLocalPortEnabled"].flag, separateLAN: separate)
            guard (1...maximum).contains(number("localPort")) else { throw ClientFailure("invalid_port") }
            guard !separate || input["user"].text.isEmpty == input["pass"].text.isEmpty else { throw ClientFailure("inbound_lan_credentials_invalid") }
            input["newPort4LAN"] = .bool(separate)
            var protocols = input["destOverride"].items
            guard protocols.allSatisfy({ $0.text == "fakedns" || options["destOverrideProtocols"].items.contains($0) }) else { throw ClientFailure("sniffing_protocol_invalid") }
            if protocols.isEmpty && input["sniffingEnabled"].flag { protocols = [.string("http"),.string("tls")] }
            var seen = Set<String>()
            input["destOverride"] = .array(protocols.filter { seen.insert($0.text.lowercased()).inserted })
        case "core":
            guard listed("loglevel","logLevels") else { throw ClientFailure("log_level_invalid") }
            for (key,list) in [("defFingerprint","fingerprints"),("defUserAgent","userAgents"),("mux4RayXudpProxyUDP443","mux4RayXudpProxyUDP443Options"),("fragmentPackets","fragmentPacketsOptions")] {
                guard input[key].text.isEmpty || listed(key,list) else { throw ClientFailure("core_options_invalid") }
            }
            for key in ["mux4RayConcurrency","mux4RayXudpConcurrency"] where input[key] != .null {
                guard (0...1024).contains(number(key)) else { throw ClientFailure("core_settings_invalid") }
                if number(key) == 0 { input[key] = .null }
            }
            guard number("hy2UpMbps") >= 0, number("hy2DownMbps") >= 0 else { throw ClientFailure("core_settings_invalid") }
            for (value, maximum) in (input["fragmentLengths"].items + input["fragmentDelays"].items).map({ ($0.text, Int(Int32.max)) }) + [(input["fragmentMaxSplit"].text,10000)] where !value.isEmpty {
                let parts = value.components(separatedBy:"-").compactMap(Int.init)
                guard parts.count == value.components(separatedBy:"-").count, (1...2).contains(parts.count), let first = parts.first, let last = parts.last,
                      first >= 0, last >= first, last <= maximum else { throw ClientFailure("fragment_settings_invalid") }
            }
            if input["enableFragment"].flag || input["enableFinalFragment"].flag {
                try XrayFragmentation.validateLengths(input["fragmentLengths"].items)
            }
        case "application":
            guard number("geoAutoUpdateInterval") >= 0, input["rootCertProvider"].text.isEmpty || listed("rootCertProvider","rootCertProviders") else { throw ClientFailure("application_settings_invalid") }
        case "simpleDNS":
            if input["fakeIP"].flag { _ = try XrayDNS.fakePool(input["fakeIPRange"].text) }
        case "speedTest":
            guard number("speedTestTimeout") > 0, number("mixedConcurrencyCount") > 0 else { throw ClientFailure("speedtest_settings_invalid") }
            for key in ["speedTestUrl","speedPingTestUrl"] { _ = try SubscriptionDownload.address(input[key].text) }
        case "routing":
            guard listed("domainStrategy","routingBasicDomainStrategies") else { throw ClientFailure("routing_strategy_invalid") }
        default: break
        }
    }
}
