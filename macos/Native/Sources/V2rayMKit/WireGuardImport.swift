import Foundation

enum WireGuardImport {
    static func decodeIfPresent(_ text: String) throws -> [RuntimeDatabase.Row]? {
        guard let first = text.first, "[#;".contains(first) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).lazy.map {
            $0.prefix { $0 != "#" && $0 != ";" }.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        guard lines.first?.lowercased() == "[interface]" else { return nil }

        var interface: [String: String] = [:]
        var peers: [[String: String]] = []
        for line in lines.dropFirst() {
            if line.lowercased() == "[peer]" {
                peers.append([:])
                continue
            }
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, !line.hasPrefix("[") else { throw ClientFailure("profile_validation_failed") }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            if peers.isEmpty {
                if ["address", "dns"].contains(key), let previous = interface[key] {
                    interface[key] = previous + ", " + value
                } else { interface[key] = value }
            } else {
                let index = peers.count - 1
                if key == "allowedips", let previous = peers[index][key] {
                    peers[index][key] = previous + ", " + value
                } else { peers[index][key] = value }
            }
        }
        guard let secret = interface["privatekey"], !secret.isEmpty, !peers.isEmpty else { throw ClientFailure("profile_validation_failed") }
        var shared: [String: SettingsValue] = [:]
        shared["WgInterfaceAddress"] = interface["address"].map(SettingsValue.string)
        shared["WgDns"] = interface["dns"].map(SettingsValue.string)
        if let raw = interface["mtu"] {
            guard let mtu = UInt16(raw), mtu > 0 else { throw ClientFailure("profile_validation_failed") }
            shared["WgMtu"] = .number(Double(mtu))
        }
        return try peers.enumerated().map { index, peer in
            guard let key = peer["publickey"], !key.isEmpty, let endpoint = peer["endpoint"],
                  let url = URLComponents(string: "wg://" + endpoint), let address = url.host, !address.isEmpty,
                  url.user == nil, url.password == nil, url.path.isEmpty, url.fragment == nil, url.query == nil,
                  (url.port != nil || !endpoint.contains(":") || endpoint.hasSuffix("]")),
                  (1...65535).contains(url.port ?? 2408) else {
                throw ClientFailure("profile_validation_failed")
            }
            var options = shared
            options["WgPublicKey"] = .string(key)
            options["WgPresharedKey"] = peer["presharedkey"].map(SettingsValue.string)
            options["WgReserved"] = peer["reserved"].map(SettingsValue.string)
            if let allowed = peer["allowedips"] {
                guard !allowed.split(separator: ",").allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
                    throw ClientFailure("profile_validation_failed")
                }
                options["WgAllowedIPs"] = .string(allowed)
            }
            options["WgKeepAlive"] = peer["persistentkeepalive"].map(SettingsValue.string)
            return ["ConfigType": .integer(9), "Network": .text("raw"), "Password": .text(secret),
                    "Address": .text(address.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))),
                    "Port": .integer(Int64(url.port ?? 2408)), "Remarks": .text("WireGuard Peer " + String(index + 1)),
                    "ProtoExtra": .text(try SettingsValue.object(options).json())]
        }
    }
}
