import Foundation

struct XrayGroupRouting {
    var balancers: [SettingsValue] = []
    var probes = [String: SettingsValue]()
    var tags: Set<String> { Set(balancers.map { $0["tag"].text }) }

    mutating func register(_ group: SettingsValue, prefix: String, pingURL: SettingsValue) throws {
        let text = group["protoExtra"].text
        let choice = text.isEmpty ? "" : try SettingsValue.parse(text)["MultipleLoad"].text.lowercased()
        let type: String, probe: String?
        switch choice {
        case "1", "fallback", "4", "leastload": type = "leastLoad"; probe = "burstObservatory"
        case "2", "random": type = "random"; probe = nil
        case "3", "roundrobin": type = "roundRobin"; probe = nil
        default: type = "leastPing"; probe = "observatory"
        }
        var strategy: SettingsValue = .object(["type": .string(type)])
        if type == "leastLoad" {
            strategy["settings"]["expected"] = .number(1)
            if ["1","fallback"].contains(choice) {
                strategy["settings"]["tolerance"] = .number(0.2)
                strategy["settings"]["maxRTT"] = .string("5000ms")
            }
        }
        balancers.append(.object(["tag": .string(prefix + "-balancer"), "selector": .array([.string(prefix)]), "strategy": strategy]))
        guard let probe else { return }
        var config = probes[probe] ?? .object([:])
        if config["subjectSelector"] == .null {
            if probe == "observatory" {
                config["probeUrl"] = pingURL
                config["probeInterval"] = .string("3m")
                config["enableConcurrency"] = .bool(true)
            } else {
                config["pingConfig"] = .object(["destination": pingURL, "interval": .string("5m"), "timeout": .string("30s"), "sampling": .number(2)])
            }
        }
        config["subjectSelector"] = .array(config["subjectSelector"].items + [.string(prefix)])
        probes[probe] = config
    }

    static func rules(_ values: [SettingsValue], matching tags: Set<String>) -> [SettingsValue] {
        values.map { value in
            guard case .object(var fields) = value, let target = fields["outboundTag"]?.text,
                  tags.contains(target + "-balancer") else { return value }
            fields.removeValue(forKey: "outboundTag")
            fields["balancerTag"] = .string(target + "-balancer")
            return .object(fields)
        }
    }

    static func mergeTemplate(_ result: inout SettingsValue, generated: SettingsValue) {
        let items = generated["routing"]["balancers"].items
        if !items.isEmpty {
            if result["routing"]["rules"] != .null {
                result["routing"]["rules"] = .array(rules(result["routing"]["rules"].items, matching: Set(items.map { $0["tag"].text })))
            }
            result["routing"]["balancers"] = .array(result["routing"]["balancers"].items + items)
        }
        for key in ["observatory", "burstObservatory"] where generated[key] != .null {
            if result[key] == .null { result[key] = generated[key]; continue }
            var seen = Set<String>()
            result[key]["subjectSelector"] = .array((generated[key]["subjectSelector"].items + result[key]["subjectSelector"].items)
                .filter { seen.insert($0.text).inserted })
        }
    }
}
