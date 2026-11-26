import XCTest
@testable import V2rayMKit

final class XrayDNSTests: XCTestCase {
    func testFakeDNSRejectsInvalidPoolsAtSaveAndGenerationAndKeepsValidCIDRs() throws {
        let route = SettingsValue.object(["RuleSet": .string(#"[{"domain":["example.org"],"outboundTag":"proxy"}]"#)])
        func generate(_ cidr: String) throws -> SettingsValue {
            let simple: SettingsValue = .object(["FakeIP": .bool(true), "FakeIPRange": .string(cidr)])
            var config = SettingsValue.object([:])
            try XrayDNS(simple: simple, custom: .null, protectedDomains: [], systemHosts: [:], useTunnel: false)
                .apply(to: &config, routingProfile: route)
            return config["fakedns"]
        }
        for invalid in ["bogus/24", "24", "192.0.2.1/32", "fd00::1/128", "fd00::/64/96"] {
            let update: SettingsValue = .object(["fakeIP": .bool(true), "fakeIPRange": .string(invalid)])
            XCTAssertThrowsError(try NativeSettings.applying(update, section: "simpleDNS", to: .object([:]), options: .null), invalid)
            XCTAssertThrowsError(try generate(invalid), invalid)
        }
        XCTAssertEqual(try generate("")["poolSize"].text, "131071")
        XCTAssertEqual(try generate("fd00::/127")["poolSize"].text, "1")
        let large = try XCTUnwrap(Int64(generate("fd00::/68")["poolSize"].text))
        XCTAssertLessThan(log2(Double(large)), 60, "Xray rejects a cache size that rounds up to the subnet capacity")
    }

    func testFreshDatabaseDNSAndRoutingMatchReviewedReference() throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "dns-routing-reference", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(SettingsValue.self, from: Data(contentsOf: file))
        let routing = try XrayRouting.generate(config: .object(["RoutingBasicItem": fixture["routingBasic"]]),
                                              profile: fixture["route"], tunProcesses: nil) { _, _ in "proxy" }
        var config = SettingsValue.object(["routing": routing])
        let dns = XrayDNS(simple: fixture["simple"], custom: .null, protectedDomains: [], systemHosts: [:], useTunnel: false)
        try dns.apply(to: &config, routingProfile: fixture["route"])
        XCTAssertEqual(config["dns"], fixture["dns"])
        XCTAssertEqual(config["routing"], fixture["routing"])
    }
    func testOnlyAnEffectiveUnconditionalDirectRuleSelectsDirectFallback() throws {
        let simple = SettingsValue.object(["RemoteDNS": .string("127.0.0.1"), "DirectDNS": .string("127.0.0.2")])
        let dns = XrayDNS(simple: simple, custom: .null, protectedDomains: [], systemHosts: [:], useTunnel: false)
        let proxy: SettingsValue = .object(["Network":.string("tcp,udp"), "OutboundTag":.string("proxy")])
        let direct: SettingsValue = .object(["Network":.string("tcp,udp"), "OutboundTag":.string("direct")])
        func servers(_ end: SettingsValue) throws -> [SettingsValue] {
            var config = SettingsValue.object([:])
            let ruleSet = try SettingsValue.array([proxy,end]).json()
            try dns.apply(to: &config, routingProfile: .object(["RuleSet":.string(ruleSet)]))
            return config["dns"]["servers"].items
        }
        for (key,value): (String, SettingsValue) in [("Enabled",.bool(false)), ("RuleType",.string("routing")), ("InboundTag",.array([.string("tun")])), ("Protocol",.array([.string("http")]))] {
            var constrained = direct
            constrained[key] = value
            XCTAssertEqual(try servers(constrained), [.string("127.0.0.1")])
        }
        XCTAssertEqual(try servers(.object(["OutboundTag": .string("direct")])), [.string("127.0.0.1")])
        XCTAssertEqual(try servers(direct).last?["address"], .string("127.0.0.2"))
    }

    func testDirectWildcardOfEitherFamilySurvivesLaterSpecificRulesAndNodeOverrides() throws {
        let simple = SettingsValue.object(["RemoteDNS": .string("127.0.0.1"), "DirectDNS": .string("127.0.0.2")])
        let dns = XrayDNS(simple: simple, custom: .null, protectedDomains: [], systemHosts: [:], useTunnel: false)
        func fallback(ip: String, profile: String = "") throws -> SettingsValue? {
            let route: SettingsValue = .object(["Ip": .array([.string(ip)]), "OutboundTag": .string("direct"), "OutboundProfileId": .string(profile)])
            let specific: SettingsValue = .object(["Domain": .array([.string("full:edge.example")]), "OutboundTag": .string("proxy")])
            var config = SettingsValue.object([:])
            try dns.apply(to: &config, routingProfile: .object(["RuleSet": .string(try SettingsValue.array([route, specific]).json())]))
            return config["dns"]["servers"].items.last
        }
        for ip in ["::/0", "0.0.0.0/0"] {
            let server = try XCTUnwrap(fallback(ip: ip))
            XCTAssertEqual(server["address"], .string("127.0.0.2"))
            XCTAssertEqual(server["tag"], .string("direct-dns"))
            XCTAssertEqual(server["skipFallback"], .bool(false))
            XCTAssertEqual(server["finalQuery"], .null)
            XCTAssertEqual(try fallback(ip: ip, profile: "specific-node"), .string("127.0.0.1"))
        }
        XCTAssertEqual(try fallback(ip: "2001:db8::/32"), .string("127.0.0.1"))
    }

    func testMatchedResolverGroupsStopAtTheirLastServerAndRegionalFallbackAcceptsRemoteIPs() throws {
        let route = SettingsValue.object(["RuleSet": .string("""
        [{"Domain":["geosite:cn","ext:sites.dat:news-cn","geosite:cdn@cn","geosite:private","full:direct.invalid"],"OutboundTag":"direct"},
         {"Domain":["full:proxy.invalid"],"OutboundTag":"proxy"}]
        """)])
        for parallel in [false, true] {
            let simple: SettingsValue = .object(["DirectDNS": .string("127.0.0.1:5301,127.0.0.1:5302"),
                "RemoteDNS": .string("127.0.0.1:5401,127.0.0.1:5402"), "DirectExpectedIPs": .string("geoip:cn,192.0.2.0/24"),
                "ParallelQuery": .bool(parallel)])
            var config = SettingsValue.object([:])
            try XrayDNS(simple: simple, custom: .null, protectedDomains: ["full:peer.invalid"], systemHosts: [:], useTunnel: false)
                .apply(to: &config, routingProfile: route)
            let dns = config["dns"], servers = dns["servers"].items
            XCTAssertEqual(dns["disableFallbackIfMatch"], .bool(true))
            XCTAssertEqual(dns["enableParallelQuery"], parallel ? .bool(true) : .null)
            func matches(_ domain: String) -> [SettingsValue] { servers.filter { $0["domains"].items.contains(.string(domain)) } }
            for domain in ["geosite:cn", "ext:sites.dat:news-cn", "geosite:cdn@cn"] {
                let matched = matches(domain)
                XCTAssertEqual(matched.map { $0["port"].text }, ["5301", "5302", "5401", "5402"])
                XCTAssertEqual(matched.map { $0["finalQuery"].flag }, [false, false, false, true])
                XCTAssertEqual(matched.map { $0["tag"].text }, ["direct-dns", "direct-dns", "", ""])
                XCTAssertEqual(matched.map { $0["expectedIPs"].items.map(\.text) },
                               [["geoip:cn", "192.0.2.0/24"], ["geoip:cn", "192.0.2.0/24"], [], []])
            }
            for domain in ["full:proxy.invalid", "full:direct.invalid", "full:peer.invalid", "geosite:private"] {
                let matched = matches(domain)
                XCTAssertEqual(matched.map { $0["finalQuery"].flag }, [false, true])
                XCTAssertTrue(matched.allSatisfy { $0["skipFallback"].flag && $0["expectedIPs"] == .null })
                let port = domain == "full:proxy.invalid" ? "5401" : "5301"
                XCTAssertEqual(matched.first?["port"].text, port)
            }
            let unmatched = servers.filter { $0["domains"].items.isEmpty }
            XCTAssertEqual(unmatched.map { $0["port"].text }, ["5401", "5402"])
            XCTAssertTrue(unmatched.allSatisfy { $0["finalQuery"] == .null && !$0["skipFallback"].flag })
        }
    }

    func testDirectDNSPrecedesGenericRoutesAndPreservesTargetedLegacyAndModuleOverrides() throws {
        let simple = SettingsValue.object(["DirectDNS": .string("127.0.0.2,127.0.0.3")])
        let profile = SettingsValue.object(["RuleSet": .string("""
        [{"Ip":["0.0.0.0/0"],"OutboundTag":"proxy"},
         {"InboundTag":["direct-dns-1","socks"],"Port":"53","OutboundTag":"block"},
         {"InboundTag":["dns-module"],"Port":"443","OutboundTag":"direct"}]
        """)])
        let routing = try XrayRouting.generate(config: .null, profile: profile, tunProcesses: []) { _,_ in "proxy" }
        var config = SettingsValue.object(["routing": routing])
        try XrayDNS(simple: simple, custom: .null, protectedDomains: ["full:peer.invalid"], systemHosts: [:], useTunnel: true)
            .apply(to: &config, routingProfile: profile)
        let rules = config["routing"]["rules"].items
        XCTAssertEqual(config["dns"]["servers"].items.filter { $0["domains"].items.contains(.string("full:peer.invalid")) }
            .map { $0["tag"].text }, ["direct-dns-1", "direct-dns"])
        XCTAssertEqual(rules[0]["inboundTag"].items.map(\.text), ["direct-dns-1"])
        XCTAssertEqual(rules[0]["outboundTag"].text, "block")
        XCTAssertEqual(rules[0]["port"].text, "53")
        XCTAssertEqual(rules[1]["inboundTag"].items.map(\.text), ["direct-dns-1", "direct-dns"])
        XCTAssertEqual(rules[1]["outboundTag"].text, "direct")
        XCTAssertEqual(rules.dropFirst(2).prefix(3).map { $0["inboundTag"].items.map(\.text) }, [["tun"], ["tun"], ["tun"]])
        XCTAssertEqual(rules.suffix(4).map { $0["inboundTag"].items.map(\.text) }, [[], ["socks"], ["dns-module"], ["dns-module"]])
        XCTAssertEqual(rules.suffix(2).map { $0["outboundTag"].text }, ["direct", "proxy"])
    }

    func testAdvancedDNSRetainsExplicitFallbackAndParallelPolicy() throws {
        let document = #"{"disableFallbackIfMatch":false,"enableParallelQuery":false,"servers":[{"address":"127.0.0.1","finalQuery":false,"skipFallback":false,"expectIPs":["192.0.2.0/24"]}]}"#
        let custom = SettingsValue.object(["Enabled": .bool(true), "NormalDNS": .string(document), "TunDNS": .string(document)])
        for tun in [false, true] {
            var config = SettingsValue.object([:])
            try XrayDNS(simple: .object(["ParallelQuery": .bool(true)]), custom: custom, protectedDomains: [], systemHosts: [:], useTunnel: tun)
                .apply(to: &config, routingProfile: .null)
            XCTAssertEqual(config["dns"], try SettingsValue.parse(document))
            XCTAssertTrue(config["routing"]["rules"].items.isEmpty)
        }
    }

    func testSplitDNSRespectsTCPURIPortsAndPreservesUDPPortFields() throws {
        let addresses = "tcp://127.0.0.1:1053,tcp+local://[::1]:2053,127.0.0.1:3053"
        let simple = SettingsValue.object(["DirectDNS": .string(addresses), "RemoteDNS": .string("127.0.0.1")])
        var config = SettingsValue.object([:])
        try XrayDNS(simple:simple, custom:.null, protectedDomains:["test.invalid"], systemHosts:[:], useTunnel:false)
            .apply(to:&config,routingProfile:.null)
        let servers = config["dns"]["servers"].items
        XCTAssertEqual(servers[0]["address"], .string("tcp://127.0.0.1:1053"))
        XCTAssertEqual(servers[1]["address"], .string("tcp+local://[::1]:2053"))
        XCTAssertEqual(servers[1]["port"], .null)
        XCTAssertEqual(servers[2]["address"], .string("127.0.0.1"))
        XCTAssertEqual(servers[2]["port"], .number(3053))
    }

    func testCustomDNSUsesExistingPolicyGroupBalancerInBothModes() throws {
        let custom = SettingsValue.object(["Enabled":.bool(true), "NormalDNS":.string("127.0.0.1"), "TunDNS":.string("127.0.0.2")])
        for tun in [false,true] {
            var config: SettingsValue = .object(["routing":.object(["domainStrategy":.string("IPIfNonMatch"),
                "balancers":.array([.object(["tag":.string("proxy-balancer")])])])])
            try XrayDNS(simple:.null,custom:custom,protectedDomains:[],systemHosts:[:],useTunnel:tun).apply(to:&config,routingProfile:.null)
            let rule = try XCTUnwrap(config["routing"]["rules"].items.last)
            XCTAssertEqual(rule["balancerTag"], .string("proxy-balancer"))
            XCTAssertEqual(rule["outboundTag"], .null)
            XCTAssertEqual(config["dns"]["servers"].items.first,.string(tun ? "127.0.0.2":"127.0.0.1"))
        }
    }

    func testUDPPortsInFallbackAndAdvancedListsAndHostOverrides() throws {
        let addresses = "127.0.0.1:5301,udp://[::1]:5302,tcp://127.0.0.1:5303"
        let expected: [SettingsValue] = [.object(["address":.string("127.0.0.1"),"port":.number(5301)]),
            .object(["address":.string("::1"),"port":.number(5302)]), .string("tcp://127.0.0.1:5303")]
        for tunnel in [false, true] {
            let simple: SettingsValue = .object(["RemoteDNS": .string(addresses),
                "Hosts": .string("# header\nfixture.invalid 192.0.2.10 2001:db8::1 # test addresses")])
            var config: SettingsValue = .object([:])
            try XrayDNS(simple: simple, custom: .null, protectedDomains: [], systemHosts: [:], useTunnel: tunnel)
                .apply(to: &config, routingProfile: .null)
            XCTAssertEqual(config["dns"]["servers"].items, expected)
            XCTAssertEqual(config["dns"]["hosts"]["fixture.invalid"].items, [.string("192.0.2.10"), .string("2001:db8::1")])

            var custom: SettingsValue = .object(["Enabled": .bool(true), "UseSystemHosts": .bool(true),
                "NormalDNS": .string(addresses), "TunDNS": .string(addresses), "DomainDNSAddress": .string("[::1]:5304")])
            func applyCustom() throws {
                config = .object([:])
                try XrayDNS(simple: .null, custom: custom, protectedDomains: ["full:peer.invalid"],
                            systemHosts: ["fixture.invalid":"192.0.2.11"], useTunnel: tunnel)
                    .apply(to: &config, routingProfile: .null)
            }
            try applyCustom()
            XCTAssertEqual(Array(config["dns"]["servers"].items.prefix(3)), expected)
            XCTAssertEqual(config["dns"]["servers"].items.last?["port"], .number(5304))
            XCTAssertEqual(config["dns"]["hosts"]["fixture.invalid"], .array([.string("192.0.2.11")]))
            custom[tunnel ? "TunDNS" : "NormalDNS"] = .string(#"{"hosts":{"fixture.invalid":"192.0.2.12"},"servers":["localhost"]}"#)
            try applyCustom()
            XCTAssertEqual(config["dns"]["hosts"]["fixture.invalid"], .array([.string("192.0.2.12")]))
        }
    }
}
