import Foundation

/// The physical TLS connection and the user's connection inside the proxy
/// are different streams. Final fragmentation wraps the latter at its entry.
struct XrayFragmentation {
    let settings: SettingsValue
    let entryTags: Set<String>

    static func validateLengths(_ lengths: [SettingsValue]) throws {
        if let last = lengths.last, (Int(last.text.components(separatedBy: "-")[0]) ?? 0) <= 0 {
            throw ClientFailure("fragment_settings_invalid", "最后一个分片长度范围的最小值必须大于零。")
        }
    }

    func apply(to outbounds: ArraySlice<SettingsValue>) throws -> [SettingsValue] {
        let core = settings["CoreBasicItem"]
        let transport = core["EnableFragment"].flag
        let final = core["EnableFinalFragment"].flag
        guard transport || final, !outbounds.isEmpty else { return Array(outbounds) }
        let options = settings["Fragment4RayItem"]
        let lengths = options["Lengths"].items
        try Self.validateLengths(lengths)
        let delays = options["Delays"].items
        let packets = options["Packets"].text
        let mask: SettingsValue = .object(["type": .string("fragment"), "settings": .object([
            "packets": .string(packets.isEmpty ? "tlshello" : packets),
            "lengths": .array(lengths.isEmpty ? [.string("50-100")] : lengths),
            "delays": .array(delays.isEmpty ? [.string("10-20")] : delays),
            "maxSplit": .string(options["MaxSplit"].text.isEmpty ? "0" : options["MaxSplit"].text)
        ])])
        var result = [SettingsValue]()
        for var outbound in outbounds {
            let stream = outbound["streamSettings"]
            if transport, ["tls","reality"].contains(stream["security"].text),
               !["kcp","hysteria","masque"].contains(stream["network"].text),
               stream["sockopt"]["dialerProxy"].text.isEmpty,
               stream["finalmask"]["tcp"].items.isEmpty {
                var physical = mask
                if stream["security"].text == "reality", physical["settings"]["packets"].text == "tlshello" {
                    physical["settings"]["packets"] = .string("1-3")
                }
                outbound["streamSettings"]["finalmask"]["tcp"] = .array([physical])
            }
            let tag = outbound["tag"].text
            if final && entryTags.contains(tag) {
                let inner = "fragment-" + tag
                result.append(.object(["tag": .string(tag), "protocol": .string("freedom"),
                    "streamSettings": .object(["finalmask": .object(["tcp": .array([mask])]),
                                               "sockopt": .object(["dialerProxy": .string(inner)])])]))
                outbound["tag"] = .string(inner)
            }
            result.append(outbound)
        }
        return result
    }
}
