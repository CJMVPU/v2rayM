import Foundation

/// Internal tags must stay outside the public "proxy" prefix used by Xray balancer selectors.
struct XrayCustomOutboundTags {
    var reserved: Set<String>
    private var sequence = 0

    init(reserving tags: Set<String>) { reserved = tags }

    mutating func next() -> String {
        while true {
            sequence += 1
            let tag = "custom-hop-" + String(sequence)
            if reserved.insert(tag).inserted { return tag }
        }
    }
}

extension XrayFileProfile {
    static func outbounds(_ source: SettingsValue, tag: String, via: String?, bind: String, strategy: SettingsValue,
                          tags: inout XrayCustomOutboundTags) throws -> [SettingsValue] {
        let members = try FileProfileImport.customMembers(source)
        let array: Bool
        if case .array = source { array = true } else { array = false }
        let assigned = [tag] + members.dropFirst().map { _ in tags.next() }
        var names = [String: String]()
        for (member, destination) in zip(members, assigned) {
            let name = member["tag"].text
            if array, !name.isEmpty { names[name] = destination }
        }
        var used = Set<String>()
        let placeholders = ["{{tag}}": tag, "{{detour}}": via ?? "", "{{interface}}": bind]
        var rendered = try members.map { member in
            var item = member
            // Resolve local references before expanding {{detour}}, which names an outer hop.
            remapReferences(in: &item) { names[$0] ?? $0 }
            return try substitute(item, placeholders: placeholders, used: &used)
        }
        if array {
            for i in rendered.indices { rendered[i]["tag"] = .string(assigned[i]) }
        } else if !used.contains("{{tag}}") {
            rendered[0]["tag"] = .string(tag)
        }
        if rendered[0]["targetStrategy"] == .null, strategy != .null { rendered[0]["targetStrategy"] = strategy }
        let last = rendered.count - 1
        if let via, !used.contains("{{detour}}") { setSocketOption("dialerProxy", via, on: &rendered[last]) }
        if !bind.isEmpty && !used.contains("{{interface}}") { setSocketOption("interface", bind, on: &rendered[last]) }
        return rendered
    }

    static func remapReferences(in item: inout SettingsValue, transform: (String) throws -> String) rethrows {
        func remap(_ field: inout SettingsValue) throws {
            if case let .string(value) = field, !value.isEmpty { field = .string(try transform(value)) }
        }
        func stream(_ value: inout SettingsValue) throws {
            if case .string = value["sockopt"]["dialerProxy"] { try remap(&value["sockopt"]["dialerProxy"]) }
            for transport in ["xhttpSettings", "splithttpSettings"] {
                if case .object = value[transport]["downloadSettings"] { try stream(&value[transport]["downloadSettings"]) }
                if case .object = value[transport]["extra"]["downloadSettings"] { try stream(&value[transport]["extra"]["downloadSettings"]) }
            }
        }
        if case .string = item["proxySettings"]["tag"] { try remap(&item["proxySettings"]["tag"]) }
        if case .object = item["streamSettings"] { try stream(&item["streamSettings"]) }
    }

    private static func substitute(_ source: SettingsValue, placeholders: [String: String], used: inout Set<String>) throws -> SettingsValue {
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
        return try walk(source)
    }
}
