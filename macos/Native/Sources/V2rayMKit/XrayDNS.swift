import Darwin
import Foundation

struct XrayDNS {
    let simple: SettingsValue
    let custom: SettingsValue
    let protectedDomains: [String]
    let systemHosts: [String: String]
    let useTunnel: Bool

    static func fakePool(_ input: String) throws -> SettingsValue {
        let cidr = input.isEmpty ? "198.18.0.0/15" : input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]), String(prefix) == parts[1] else {
            throw ClientFailure("fake_dns_range_invalid")
        }
        let host = String(parts[0])
        let ipv6 = host.contains(":")
        var address = in6_addr()
        let width = ipv6 ? 128 : 32
        guard !host.contains("\0"), inet_pton(ipv6 ? AF_INET6 : AF_INET, host, &address) == 1,
              (0..<width).contains(prefix) else { throw ClientFailure("fake_dns_range_invalid") }
        let hostBits = width - prefix
        var capacity: Int64 = hostBits >= 63 ? .max : (Int64(1) << hostBits) - 1
        // Xray compares log2(Double(capacity)) to hostBits. Near a large power
        // of two even capacity minus one rounds up, making an otherwise valid pool fail startup.
        if log2(Double(capacity)) >= Double(hostBits) { capacity = Int64(1) << (hostBits - 1) }
        return .object(["ipPool": .string(cidr), "poolSize": .integer64(capacity)])
    }

    func apply(to config: inout SettingsValue, routingProfile: SettingsValue) throws {
        if custom["Enabled"].flag {
            try applyCustom(to: &config)
            return
        }
        let rulesText = routingProfile["RuleSet"].text
        let rules = try rulesText.isEmpty ? [] : NativeConfigurationStore.parseRoutingRules(rulesText).items
        let expected = split(simple["DirectExpectedIPs"].text)
        let region = expected.last(where: { $0.lowercased().hasPrefix("geoip:") }).map { String($0.dropFirst(6)) }
        var directDomains: [String] = [], proxyDomains: [String] = [], directSites: [String] = []
        var proxySites: [String] = [], regional: [String] = []
        var last: [String: SettingsValue] = [:]
        for rule in rules {
            let fields = try StoredRoutingRule.fields(of: rule)
            if fields["enabled"] == .bool(false) || ["1", "routing"].contains(fields["ruleType"]?.text.lowercased()) { continue }
            // An empty editor row or a domain list made entirely of comments
            // produces no Xray routing rule and cannot choose the fallback DNS.
            let domains = fields["domain"]?.items ?? []
            let hasOtherList = ["ip", "process"].contains { !(fields[$0]?.items ?? []).isEmpty }
            let hasBaseSelector = ["network", "port"].contains { !(fields[$0]?.text ?? "").isEmpty }
                || ["inboundTag", "protocol"].contains { !(fields[$0]?.items ?? []).isEmpty }
            guard hasOtherList || domains.contains(where: { !$0.text.hasPrefix("#") })
                    || (domains.isEmpty && hasBaseSelector) else { continue }
            last = fields
            let tag = (fields["outboundProfileId"]?.text ?? "").isEmpty ? fields["outboundTag"]?.text : "proxy"
            if tag == "block" { continue }
            for item in last["domain"]?.items ?? [] {
                let name = item.text.replacingOccurrences(of: "<COMMA>", with: ",")
                if name.hasPrefix("#") { continue }
                let site = name.hasPrefix("geosite:") || name.hasPrefix("ext:")
                if tag == "direct" {
                    if !site { directDomains.append(name) }
                    else if let region, name == "geosite:" + region || name.hasSuffix("-" + region) || name.hasSuffix("@" + region) {
                        regional.append(name)
                    } else { directSites.append(name) }
                } else if site { proxySites.append(name) }
                else { proxyDomains.append(name) }
            }
        }
        let direct = addresses("DirectDNS", fallback: "119.29.29.29")
        let remote = addresses("RemoteDNS", fallback: "https://cloudflare-dns.com/dns-query")
        let bootstrap = addresses("BootstrapDNS", fallback: "119.29.29.29")
        let bootstrapDomains = (direct + remote).compactMap { address -> String? in
            let host = Self.parts(address)?.host ?? address
            return Self.isDomain(host) ? "full:" + host : nil
        }
        var servers: [SettingsValue] = [], directTags: [String] = []
        func append(_ addresses: [String], domains: [String], direct: Bool = false,
                    expected: [String] = [], fallback: Bool = false) {
            guard !domains.isEmpty || fallback else { return }
            for address in addresses {
                var server = Self.server(address: address, domains: unique(domains))
                if fallback { server["skipFallback"] = .bool(false) }
                if !expected.isEmpty { server["expectedIPs"] = strings(unique(expected)) }
                if direct {
                    let tag = "direct-dns-\(directTags.count + 1)"
                    directTags.append(tag)
                    server["tag"] = .string(tag)
                }
                servers.append(server)
            }
        }
        append(bootstrap, domains: bootstrapDomains)
        append(direct, domains: protectedDomains, direct: true)
        if simple["FakeIP"].flag {
            var match = proxyDomains + proxySites
            if simple["GlobalFakeIp"] != .bool(false) { match += directDomains + directSites + regional }
            if !match.isEmpty {
                config["fakedns"] = try Self.fakePool(simple["FakeIPRange"].text)
                append(["fakedns"], domains: match)
            }
        }
        append(remote, domains: proxyDomains)
        append(direct, domains: directDomains, direct: true)
        append(remote, domains: proxySites)
        append(direct, domains: directSites, direct: true)
        append(direct, domains: regional, direct: true, expected: expected)
        let ips = last["ip"]?.items ?? []
        if (last["outboundProfileId"]?.text ?? "").isEmpty, last["outboundTag"]?.text == "direct", (last["domain"]?.items ?? []).isEmpty,
           ["process", "inboundTag", "protocol"].allSatisfy({ (last[$0]?.items ?? []).isEmpty }), ips.isEmpty || ips.contains(.string("0.0.0.0/0")),
           ["", "0-65535", "1-65535"].contains(last["port"]?.text ?? ""), ["","tcp,udp","udp,tcp"].contains(last["network"]?.text ?? "") {
            append(direct, domains: [], direct: true, fallback: true)
        } else { servers += remote.map(Self.resolver) }
        var dns: SettingsValue = .object(["servers": .array(servers), "tag": .string("dns-module")])
        if simple["ServeStale"].flag { dns["serveStale"] = .bool(true) }
        if simple["ParallelQuery"].flag { dns["enableParallelQuery"] = .bool(true) }
        if simple["BlockAAAAQuery"].flag { dns["queryStrategy"] = .string("UseIPv4") }
        var hosts = simple["AddCommonHosts"].flag ? Self.commonHosts : [:]
        if simple["UseSystemHosts"].flag {
            for (name, ip) in systemHosts where hosts[name] == nil { hosts[name] = [ip] }
        }
        var overrides: [String: [String]] = [:]
        for line in simple["Hosts"].text.components(separatedBy: .newlines) {
            let fields = line.prefix { $0 != "#" }.split(whereSeparator: \.isWhitespace).map(String.init)
            if fields.count >= 2 { overrides[fields[0], default: []] += fields.dropFirst() }
        }
        hosts.merge(overrides) { _, user in user }
        if !hosts.isEmpty { dns["hosts"] = .object(hosts.mapValues(strings)) }
        config["dns"] = dns
        var routes = config["routing"]["rules"].items
        if !directTags.isEmpty {
            let before = routes.firstIndex(where: Self.catchAll) ?? routes.count
            routes.insert(.object(["type": .string("field"), "inboundTag": strings(directTags),
                                   "outboundTag": .string("direct")]), at: before)
        }
        routes.append(Self.defaultDNSRoute(in: config))
        config["routing"]["rules"] = .array(routes)
    }

    private static func defaultDNSRoute(in config: SettingsValue) -> SettingsValue {
        let balanced = config["routing"]["balancers"].items.contains { $0["tag"].text == "proxy-balancer" }
        return .object(["type": .string("field"), "inboundTag": .array([.string("dns-module")]),
                        balanced ? "balancerTag" : "outboundTag": .string(balanced ? "proxy-balancer" : "proxy")])
    }

    static func isDomain(_ host: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return !host.isEmpty && host.lowercased() != "localhost" && inet_pton(AF_INET, host, &v4) != 1
            && inet_pton(AF_INET6, host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), &v6) != 1
    }

    private func applyCustom(to config: inout SettingsValue) throws {
        let text = custom[useTunnel ? "TunDNS" : "NormalDNS"].text
        var dns: SettingsValue
        if text.isEmpty { dns = try SettingsValue.parse(Self.defaultCustomDNS) }
        else if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") { dns = try SettingsValue.parse(text) }
        else { dns = .object(["servers": .array(split(text).map(Self.resolver))]) }
        if dns["hosts"] == .null && custom["UseSystemHosts"].flag && !systemHosts.isEmpty {
            dns["hosts"] = .object([:])
        }
        if case .object(var hosts) = dns["hosts"] {
            if custom["UseSystemHosts"].flag {
                for (name, ip) in systemHosts where hosts[name] == nil { hosts[name] = .string(ip) }
            }
            dns["hosts"] = .object(hosts.mapValues { if case .string = $0 { return .array([$0]) }; return $0 })
        }
        if !protectedDomains.isEmpty, case .array(let servers) = dns["servers"] {
            let address = custom["DomainDNSAddress"].text
            dns["servers"] = .array(servers + [Self.server(address: address.isEmpty ? "119.29.29.29" : address,
                                                            domains: protectedDomains)])
        }
        if config["routing"]["domainStrategy"].text == "IPIfNonMatch" {
            dns["tag"] = .string("dns-module")
            let rule = Self.defaultDNSRoute(in: config)
            config["routing"]["rules"] = .array(config["routing"]["rules"].items + [rule])
        }
        config["dns"] = dns
    }

    private static func parts(_ address: String) -> URLComponents? {
        if address.contains("://") { return URLComponents(string: address) }
        if address.filter({ $0 == ":" }).count > 1 && !address.hasPrefix("[") {
            return URLComponents(string: "udp://[\(address)]")
        }
        return URLComponents(string: "udp://" + address)
    }

    // Xray accepts UDP addresses with a separate port. TCP, DoH and QUIC
    // keep the port in their URL, including when used as a fallback server.
    private static func resolver(_ address: String) -> SettingsValue {
        guard let url = parts(address), url.scheme?.lowercased().hasPrefix("udp") == true, let host = url.host else { return .string(address) }
        let ip = SettingsValue.string(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
        guard let port = url.port else { return ip }
        return .object(["address": ip, "port": .number(Double(port))])
    }

    private static func server(address: String, domains: [String]) -> SettingsValue {
        let endpoint = resolver(address)
        var server = endpoint
        if case .string = endpoint { server = .object(["address": endpoint]) }
        server["skipFallback"] = .bool(true)
        if !domains.isEmpty { server["domains"] = .array(domains.map(SettingsValue.string)) }
        return server
    }

    private func addresses(_ key: String, fallback: String) -> [String] {
        let list = split(simple[key].text).map { $0.lowercased().hasPrefix("dhcp") ? "localhost" : $0 }
        return list.isEmpty ? [fallback] : unique(list)
    }
    private func split(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
    private func strings(_ values: [String]) -> SettingsValue { .array(values.map(SettingsValue.string)) }

    private static func catchAll(_ rule: SettingsValue) -> Bool {
        (rule["outboundTag"].text == "proxy" || rule["balancerTag"].text == "proxy-balancer")
            && ["inboundTag", "domain", "ip", "protocol", "process"].allSatisfy { rule[$0].items.isEmpty }
            && ["", "0-65535", "1-65535"].contains(rule["port"].text)
            && ["", "tcp,udp", "udp,tcp"].contains(rule["network"].text)
    }
}

private extension XrayDNS {
    static let commonHosts = [
        "dns.google": ["8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844"],
        "dns.alidns.com": ["223.5.5.5", "223.6.6.6", "2400:3200::1", "2400:3200:baba::1"],
        "one.one.one.one": ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"],
        "1dot1dot1dot1.cloudflare-dns.com": ["1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"],
        "cloudflare-dns.com": ["104.16.249.249", "104.16.248.249", "2606:4700::6810:f8f9", "2606:4700::6810:f9f9"],
        "dns.cloudflare.com": ["162.159.61.8", "172.64.41.8", "2a06:98c1:52::8", "2803:f800:53::8"],
        "dot.pub": ["1.12.12.12", "120.53.53.53"],
        "doh.pub": ["1.12.12.12", "120.53.53.53"],
        "dns.quad9.net": ["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"],
        "dns.yandex.net": ["77.88.8.8", "77.88.8.1", "2a02:6b8::feed:0ff", "2a02:6b8:0:1::feed:0ff"],
        "dns.sb": ["45.11.45.11", "185.222.222.222", "2a09::", "2a11::"],
        "dns.umbrella.com": ["208.67.220.220", "208.67.222.222", "2620:119:35::35", "2620:119:53::53"],
        "dns.sse.cisco.com": ["208.67.220.220", "208.67.222.222", "2620:119:35::35", "2620:119:53::53"],
        "engage.cloudflareclient.com": ["162.159.192.1", "2606:4700:d0::a29f:c001"],
    ]
    static let defaultCustomDNS = #"{"hosts":{"dns.google":"8.8.8.8","proxy.example.com":"127.0.0.1"},"servers":[{"address":"1.1.1.1","skipFallback":true,"domains":["geosite:google"]},{"address":"223.5.5.5","skipFallback":true,"domains":["geosite:cn"],"expectIPs":["geoip:cn"]},"1.1.1.1","8.8.8.8","https://dns.google/dns-query"]}"#
}
