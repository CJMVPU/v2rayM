import Foundation

enum StoredRoutingRule {
    private static let keys = Dictionary(uniqueKeysWithValues: [
        "id", "type", "port", "network", "inboundTag", "outboundTag", "outboundProfileId",
        "ip", "domain", "protocol", "process", "enabled", "remarks", "ruleType"
    ].map { ($0.lowercased(), $0) })

    /// Editors can read malformed legacy rules so the user can correct or disable them.
    static func fields(of rule: SettingsValue, validate: Bool = true) throws -> [String: SettingsValue] {
        guard case .object(let object) = rule else { throw ClientFailure("routing_rules_json_invalid") }
        var fields: [String: SettingsValue] = [:]
        for (key, value) in object {
            let canonical = keys[key.lowercased()] ?? key
            guard fields.updateValue(value, forKey: canonical) == nil else { throw ClientFailure("routing_rules_json_invalid") }
        }
        guard validate, fields["enabled"] != .bool(false) else { return fields }
        func invalid(_ key: String, _ expected: String) -> ClientFailure {
            ClientFailure("routing_rule_field_invalid", "路由规则字段“\(key)”需要\(expected)。")
        }
        if let enabled = fields["enabled"], enabled != .bool(true) {
            throw invalid("enabled", "布尔值")
        }
        if let type = fields["ruleType"], type != .null,
           !["0", "1", "2", "all", "routing", "dns"].contains(type.text.lowercased()) {
            throw invalid("ruleType", "有效的规则类型")
        }
        for key in ["domain", "ip", "process", "protocol", "inboundTag"] {
            guard let value = fields[key], value != .null else { continue }
            guard case .array(let items) = value, items.allSatisfy({ if case .string = $0 { true } else { false } }) else {
                throw invalid(key, "字符串数组")
            }
        }
        if let network = fields["network"], network != .null {
            guard case .string = network else { throw invalid("network", "字符串") }
        }
        if let port = fields["port"], port != .null {
            switch port {
            case .string: break
            case .number(let n) where (0...65535).contains(n) && n.rounded() == n: break
            default: throw invalid("port", "端口或端口范围")
            }
        }
        return fields
    }
}

enum XrayRouting {
    /// Stored rules use PascalCase. Match keys without changing domain or process values.
    static func generate(config: SettingsValue, profile: SettingsValue, tunProcesses: [String]?,
                         balancers: Set<String> = [], resolve: (String, String) throws -> String) throws -> SettingsValue {
        var rules: [SettingsValue] = []
        if let tunProcesses {
            rules = [
                .object(["network": .string("udp"), "port": .string("135,137-139,5353"), "outboundTag": .string("block")]),
                .object(["ip": .array(["224.0.0.0/3", "ff00::/8"].map(SettingsValue.string)), "outboundTag": .string("block")]),
                .object(["port": .string("53"), "outboundTag": .string("dns")])
            ]
            if !tunProcesses.isEmpty {
                let processes = SettingsValue.array(tunProcesses.map(SettingsValue.string))
                rules.append(.object(["process": processes, "outboundTag": .string("direct")]))
            }
            // Local clients can still explicitly use the mixed listener while TUN is on.
            // Only packets received from utun need these capture and loop-prevention rules.
            for index in rules.indices { rules[index]["inboundTag"] = .array([.string("tun")]) }
        }
        let encoded = profile["RuleSet"].text
        if !encoded.isEmpty {
            guard case .array(let stored) = try SettingsValue.parse(encoded) else { throw ClientFailure("routing_rules_invalid") }
            for rule in stored { rules += try expand(rule, balancers: balancers, resolve: resolve) }
        }
        let strategy = profile["DomainStrategy"].text
        return .object(["domainStrategy": strategy.isEmpty ? config["RoutingBasicItem"]["DomainStrategy"] : .string(strategy),
                        "rules": .array(rules)])
    }

    private static func expand(_ value: SettingsValue, balancers: Set<String>,
                               resolve: (String, String) throws -> String) throws -> [SettingsValue] {
        let fields = try StoredRoutingRule.fields(of: value)
        if fields["enabled"] == .bool(false) || ["2", "dns"].contains(fields["ruleType"]?.text.lowercased()) { return [] }
        let requested = fields["outboundTag"]?.text ?? "proxy"
        let id = fields["outboundProfileId"]?.text ?? ""
        let tag = try id.isEmpty && RoutingTargets.builtins.contains(requested) ? requested : resolve(requested, id)
        var base: [String: SettingsValue] = ["type": .string("field")]
        if balancers.contains(tag + "-balancer") { base["balancerTag"] = .string(tag + "-balancer") }
        else { base["outboundTag"] = .string(tag) }
        for key in ["port", "network"] {
            if let value = fields[key], !value.text.isEmpty { base[key] = value }
        }
        for key in ["inboundTag", "protocol"] {
            if let value = fields[key], !value.items.isEmpty { base[key] = value }
        }
        var rules: [SettingsValue] = []
        var hadSelector = false
        for key in ["domain", "ip", "process"] {
            let entries = fields[key]?.items ?? []
            guard !entries.isEmpty else { continue }
            hadSelector = true
            var rule = base
            if key == "domain" {
                let domains = entries.filter { !$0.text.hasPrefix("#") }.map {
                    SettingsValue.string($0.text.replacingOccurrences(of: "<COMMA>", with: ","))
                }
                guard !domains.isEmpty else { continue }
                rule[key] = .array(domains)
            } else { rule[key] = .array(entries) }
            rules.append(.object(rule))
        }
        if !hadSelector && ["port", "network", "inboundTag", "protocol"].contains(where: { base[$0] != nil }) {
            rules.append(.object(base))
        }
        return rules
    }
}
