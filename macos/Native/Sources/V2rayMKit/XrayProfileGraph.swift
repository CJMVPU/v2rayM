import Foundation

/// The first outbound receives the user's traffic. A chain stored in connection order
/// must therefore be emitted in reverse, with each exit dialing through its predecessor.
final class XrayProfileGraph {
    struct Hop {
        let node: SettingsValue
        var tag: String
        var via: String?
        let memberOrder: [Int]
    }

    let nodes: [SettingsValue]
    private let subscriptions: [String: SettingsValue]
    private(set) lazy var targets = RoutingTargets(nodes: nodes)

    init(nodes: [SettingsValue], subscriptions: [String: SettingsValue] = [:]) {
        self.nodes = nodes
        self.subscriptions = subscriptions
    }

    static func memberFilter(_ extra: SettingsValue) throws -> NSRegularExpression? {
        switch extra["Filter"] {
        case .null, .string(""): return nil
        case .string(let pattern):
            do { return try NSRegularExpression(pattern: pattern) }
            catch { throw ClientFailure("profile_group_filter_invalid") }
        default: throw ClientFailure("profile_group_filter_invalid")
        }
    }

    static func canJoinSubscriptionGroup(_ node: SettingsValue) -> Bool {
        let kind = node["configType"].text
        guard node["coreType"] == .null || node["coreType"].text == "xray" else { return false }
        if kind == "outbound" { return true }
        guard ["vMess","vless","trojan","shadowsocks","socks","http","hysteria2","wireGuard","masque"].contains(kind),
              !node["address"].text.isEmpty, UInt16(node["port"].text).map({ $0 > 0 }) == true else { return false }
        let password = node["password"].text
        let proto = (try? SettingsValue.parse(node["protoExtra"].text)) ?? .null
        if ["vless","trojan"].contains(kind), node["streamSecurity"].text == "reality", node["publicKey"].text.isEmpty { return false }
        switch kind {
        case "vMess": return UUID(uuidString: password) != nil
        case "vless": return !password.isEmpty && (password.count <= 30 || UUID(uuidString: password) != nil)
            && ["","xtls-rprx-vision","xtls-rprx-vision-udp443"].contains(proto["Flow"].text)
        case "shadowsocks": return !password.isEmpty && ["aes-256-gcm","aes-128-gcm","chacha20-poly1305",
            "chacha20-ietf-poly1305","xchacha20-poly1305","xchacha20-ietf-poly1305","none","plain",
            "2022-blake3-aes-128-gcm","2022-blake3-aes-256-gcm","2022-blake3-chacha20-poly1305"].contains(proto["SsMethod"].text)
        default: return true
        }
    }

    func root(_ node: SettingsValue) throws -> SettingsValue {
        guard let sub = subscriptions[node["subid"].text], node["configType"].text != "custom" else { return node }
        func linked(_ key: String) throws -> [String] {
            let name = sub[key].text
            guard !name.isEmpty else { return [] }
            let matches = targets.byName[name] ?? []
            guard let found = matches.first else {
                throw ClientFailure("profile_chain_member_missing", name)
            }
            guard matches.count == 1 else {
                throw ClientFailure("profile_chain_member_ambiguous", "订阅前后置节点“\(name)”有多个同名匹配。请使用唯一的节点名称。")
            }
            return [found["indexId"].text]
        }
        let ids = try linked("prevProfile") + [node["indexId"].text] + linked("nextProfile")
        guard ids.count > 1 else { return node }
        return .object(["configType": .string("proxyChain"), "remarks": node["remarks"],
                        "protoExtra": .string(try SettingsValue.object(["ChildItems": .string(ids.joined(separator: ","))]).json())])
    }

    func expand(_ node: SettingsValue, tag: String, ancestors: Set<String> = [], memberOrder: [Int] = []) throws -> [Hop] {
        let kind = node["configType"].text
        guard node["coreType"] == .null || node["coreType"].text == "xray" else { throw ClientFailure("xray_only_profile_required") }
        guard ["proxyChain", "policyGroup"].contains(kind) else { return [Hop(node: node, tag: tag, memberOrder: memberOrder)] }
        let id = node["indexId"].text
        guard !ancestors.contains(id) else { throw ClientFailure("profile_group_cycle", node["remarks"].text) }
        let next = ancestors.union([id])
        let extra = try SettingsValue.parse(node["protoExtra"].text.isEmpty ? "{}" : node["protoExtra"].text)
        var members: [SettingsValue] = []
        let group = extra["SubChildItems"].text
        let regex = try Self.memberFilter(extra)
        if !group.isEmpty {
            members = nodes.filter { member in
                guard member["subid"].text == group else { return false }
                guard Self.canJoinSubscriptionGroup(member) else { return false }
                let name = member["remarks"].text
                return regex.map { $0.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil } ?? true
            }
        }
        for child in extra["ChildItems"].text.split(separator: ",") {
            let key = child.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let found = targets.byID[key] else {
                throw ClientFailure("profile_chain_member_missing", key)
            }
            members.append(found)
        }
        guard !members.isEmpty else { throw ClientFailure("profile_group_empty") }
        if kind == "policyGroup" {
            return try members.enumerated().flatMap { index, child in
                let prefix = members.count == 1 ? tag : tag + "-\(index + 1)-" + child["remarks"].text
                return try expand(child, tag: prefix, ancestors: next, memberOrder: memberOrder + [index])
            }
        }
        var exits: [Hop] = []
        for (index, child) in members.reversed().enumerated() {
            let prefix = index == 0 ? tag : "chain-" + tag + "-\(index)-" + child["remarks"].text
            let hops = try expand(child, tag: prefix, ancestors: next, memberOrder: memberOrder + [members.count - 1 - index])
            let starts = hops.filter { $0.tag.hasPrefix(prefix) }
            if starts.count > 1 && !exits.isEmpty {
                let original = exits
                exits = starts.enumerated().flatMap { branch, start in
                    let suffix = "-clone-\(branch + 1)"
                    return original.map { entry in
                        Hop(node: entry.node, tag: entry.tag + suffix, via: entry.via.map { $0 + suffix } ?? start.tag, memberOrder: entry.memberOrder)
                    }
                }
            } else if let start = starts.first {
                for i in exits.indices where exits[i].via == nil { exits[i].via = start.tag }
            }
            exits.append(contentsOf: hops)
        }
        return exits
    }
}

enum XrayFileProfile {
    static func document(_ node: SettingsValue, directory: URL?) throws -> SettingsValue {
        let path = node["address"].text
        guard !path.isEmpty, let directory else { throw ClientFailure("profile_config_file_missing") }
        let url = URL(fileURLWithPath: path, relativeTo: directory.appendingPathComponent("", isDirectory: true)).standardizedFileURL
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw ClientFailure("profile_config_file_missing")
        }
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        guard let doc = try? decoder.decode(SettingsValue.self, from: Data(contentsOf: url)), case .object = doc else {
            throw ClientFailure("profile_config_file_invalid")
        }
        return doc
    }

    static func outbound(_ source: SettingsValue, tag: String, via: String?, bind: String, strategy: SettingsValue) throws -> SettingsValue {
        let placeholders = ["{{tag}}": tag, "{{detour}}": via ?? "", "{{interface}}": bind]
        var used = Set<String>()
        func replace(_ string: String) -> String {
            var result = string
            for (key, value) in placeholders where string.contains(key) {
                used.insert(key)
                result = result.replacingOccurrences(of: key, with: value)
            }
            return result
        }
        func walk(_ value: SettingsValue) throws -> SettingsValue {
            switch value {
            case let .string(text): return .string(replace(text))
            case let .array(values): return .array(try values.map(walk))
            case let .object(fields):
                var replaced = [String: SettingsValue]()
                for (k, v) in fields {
                    guard replaced.updateValue(try walk(v), forKey: replace(k)) == nil else { throw ClientFailure("profile_config_file_invalid") }
                }
                return .object(replaced)
            default: return value
            }
        }
        var result = try walk(source)
        guard !result["protocol"].text.isEmpty else { throw ClientFailure("profile_config_file_invalid") }
        if !used.contains("{{tag}}") { result["tag"] = .string(tag) }
        if result["targetStrategy"] == .null, strategy != .null { result["targetStrategy"] = strategy }
        if let via, !used.contains("{{detour}}") { setSocketOption("dialerProxy", via, on: &result) }
        if via == nil, case .object(var options) = result["streamSettings"]["sockopt"] {
            options.removeValue(forKey: "dialerProxy")
            result["streamSettings"]["sockopt"] = .object(options)
        }
        if !bind.isEmpty && !used.contains("{{interface}}") { setSocketOption("interface", bind, on: &result) }
        return result
    }

    static func setSocketOption(_ key: String, _ value: String, on outbound: inout SettingsValue) {
        outbound["streamSettings"]["sockopt"][key] = .string(value)
        if case .object = outbound["streamSettings"]["xhttpSettings"]["extra"]["downloadSettings"] {
            outbound["streamSettings"]["xhttpSettings"]["extra"]["downloadSettings"]["sockopt"][key] = .string(value)
        }
    }
}
