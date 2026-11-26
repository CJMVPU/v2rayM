import Foundation

/// Decode the share link into the existing SQLite representation before opening a write transaction.
struct ShareLinkImport {
    static func decode(_ content: String, subscriptionName: String? = nil) throws -> [RuntimeDatabase.Row] {
        let padding = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))
        var text = content.trimmingCharacters(in: padding)
        if !text.contains("://"), let decoded = base64Text(text.components(separatedBy: .whitespacesAndNewlines).joined()) {
            text = decoded.trimmingCharacters(in: padding)
        }
        if let peers = try WireGuardImport.decodeIfPresent(text) { return peers }
        if text.hasPrefix("{") || text.hasPrefix("[") { return try FileProfileImport.decode(text, subscriptionName: subscriptionName) }
        let links = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !links.isEmpty else { throw ClientFailure("profile_import_empty") }
        let rows = try links.map(decodeLink)
        guard rows.contains(where: { $0["IndexId"] != nil || ProfileTransfer.isGroup($0) }) else { return rows }
        return try ProfileTransfer.rekey(rows, ids: rows.map { _ in UUID().uuidString }, subscription: "self")
    }

    static func base64Text(_ text: String) -> String? {
        var encoded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.utf8.count % 4) % 4)
        guard let bytes = Data(base64Encoded: encoded) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    private static func decodeLink(_ link: String) throws -> RuntimeDatabase.Row {
        if link.lowercased().hasPrefix("vmess://"), !link.contains("@") {
            return try vmessQR(String(link.dropFirst("vmess://".count)))
        }
        guard var url = URLComponents(string: link), let scheme = url.scheme?.lowercased() else { throw ClientFailure("profile_import_empty") }
        if scheme == "v2rayn" { return try ProfileTransfer.readInner(url) }
        let kinds: [String: Int64] = ["socks": 4, "socks5": 4, "socks4": 4, "vless": 5, "trojan": 6, "ss": 3, "wireguard": 9, "vmess": 1, "hysteria2": 7, "hy2": 7]
        guard let kind = kinds[scheme] else { throw ClientFailure("share_format_unsupported") }
        if url.port == nil, [3,4].contains(kind), let delimiter = link.range(of: "://") {
            let payload = link[delimiter.upperBound...].prefix { $0 != "#" }
            if let details = base64Text(String(payload)), let at = details.lastIndex(of: "@"),
               var legacy = URLComponents(string: scheme + "://" + details[details.index(after: at)...]) {
                let credentials = details[..<at].split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard credentials.count == 2 else { throw ClientFailure("profile_validation_failed") }
                legacy.user = String(credentials[0])
                legacy.password = String(credentials[1])
                legacy.fragment = url.fragment
                url = legacy
            }
        }
        guard let host = url.host, !host.isEmpty, let port = url.port ?? (kind == 7 ? 443 : nil), (1...65535).contains(port) else {
            throw ClientFailure("profile_validation_failed")
        }
        let query = Dictionary((url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        let name = url.fragment.flatMap { $0.isEmpty ? nil : $0 } ?? host
        var row: RuntimeDatabase.Row = ["ConfigType": .integer(kind), "Address": .text(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))),
                                        "Port": .integer(Int64(port)), "Remarks": .text(name)]
        var proto: [String: SettingsValue] = [:]
        var transport: [String: SettingsValue] = [:]
        var security = query["security"] ?? ""
        var network = query["type"] ?? "raw"
        if network == "tcp" { network = "raw" }
        let user = url.user ?? ""
        let password = url.password
        switch kind {
        case 3, 4:
            var credentials: (String, String)?
            if let password { credentials = (user, password) }
            else if !user.isEmpty {
                guard let decoded = base64Text(user), let colon = decoded.firstIndex(of: ":") else { throw ClientFailure("profile_validation_failed") }
                credentials = (String(decoded[..<colon]), String(decoded[decoded.index(after: colon)...]))
            }
            if let (first, secret) = credentials {
                if kind == 3 { proto["SsMethod"] = .string(first) } else { row["Username"] = .text(first) }
                row["Password"] = .text(secret)
            } else if kind == 3 { throw ClientFailure("profile_validation_failed") }
        case 1, 5, 6, 7, 9:
            let secret = password.map { user + ":" + $0 } ?? user
            guard !secret.isEmpty else { throw ClientFailure("profile_validation_failed") }
            row["Password"] = .text(secret)
            if kind == 1 { proto["VmessSecurity"] = .string("auto") }
            if kind == 7 {
                security = "tls"
                for (key, field) in [("mport", "Ports"), ("obfs-password", "SalamanderPass"), ("minPacketSize", "GeckoMinPacketSize"),
                                     ("maxPacketSize", "GeckoMaxPacketSize")] { proto[field] = query[key].map(SettingsValue.string) }
                if query["obfs"] == "gecko" {
                    if proto["GeckoMinPacketSize"]?.text.isEmpty != false { proto["GeckoMinPacketSize"] = .string("512") }
                    if proto["GeckoMaxPacketSize"]?.text.isEmpty != false { proto["GeckoMaxPacketSize"] = .string("1200") }
                }
            }
            if kind == 5 { proto["VlessEncryption"] = .string(query["encryption"] ?? "none") }
            if kind == 6, security.isEmpty { security = "tls" }
            if let flow = query["flow"] { proto["Flow"] = .string(flow) }
            if kind == 9 {
                for (key, field) in [("publickey","WgPublicKey"),("presharedkey","WgPresharedKey"),("reserved","WgReserved"),
                                     ("address","WgInterfaceAddress"),("dns","WgDns"),("allowedips","WgAllowedIPs"),("keepalive","WgKeepAlive")] {
                    proto[field] = query[key].map(SettingsValue.string)
                }
                if let mtu = Int(query["mtu"] ?? "") { proto["WgMtu"] = .number(Double(mtu)) }
            }
        default: throw ClientFailure("share_format_unsupported")
        }
        for (key, field) in [("sni","Sni"),("alpn","Alpn"),("fp","Fingerprint"),("pbk","PublicKey"),("sid","ShortId"),("spx","SpiderX"),
                             ("pqv","Mldsa65Verify"),("ech","EchConfigList"),("vcn","VerifyPeerCertByName"),("pcs","CertSha"),("fm","Finalmask")] {
            row[field] = query[key].map(RuntimeDatabase.Value.text)
        }
        if query["allowInsecure"] == "1" || query["insecure"] == "1" { row["AllowInsecure"] = .text("true") }
        switch network {
        case "ws", "xhttp", "httpupgrade", "raw":
            transport["Host"] = query["host"].map(SettingsValue.string)
            transport["Path"] = .string(query["path"] ?? (network == "raw" ? "" : "/"))
            if network == "raw" { transport["RawHeaderType"] = .string(query["headerType"] ?? "none") }
            if network == "xhttp" {
                transport["XhttpMode"] = query["mode"].map(SettingsValue.string)
                transport["XhttpExtra"] = query["extra"].map(SettingsValue.string)
            }
        case "kcp":
            transport["KcpSeed"] = query["seed"].map(SettingsValue.string)
            transport["KcpHeaderType"] = .string(query["headerType"] ?? "none")
            if let mtu = Int(query["mtu"] ?? "") { transport["KcpMtu"] = .number(Double(mtu)) }
        case "grpc":
            transport["GrpcServiceName"] = query["serviceName"].map(SettingsValue.string)
            transport["GrpcAuthority"] = query["authority"].map(SettingsValue.string)
            transport["GrpcMode"] = .string(query["mode"] ?? "gun")
        default: throw ClientFailure("transport_unsupported")
        }
        if kind == 3, let plugin = query["plugin"], !plugin.isEmpty {
            try applyShadowsocksPlugin(plugin, to: &row, transport: &transport, network: &network, security: &security)
        }
        if kind == 7, row["CertSha"] == nil, let pin = query["pinSHA256"], !pin.isEmpty {
            row["CertSha"] = .text(pin)
            row["AllowInsecure"] = .text("true")
        }
        row["Network"] = .text(network)
        row["StreamSecurity"] = .text(security)
        row["ProtoExtra"] = .text(try SettingsValue.object(proto).json())
        row["TransportExtra"] = .text(try SettingsValue.object(transport).json())
        return row
    }
}

extension NativeConfigurationStore {
    func importProfiles(content: String, groupID: String?, isSubscription: Bool) throws -> Int {
        let settings = try readSettings()
        let group = groupID ?? settings["SubIndexId"].text
        let db = try RuntimeDatabase(url: databaseURL, writable: true)
        let directory = databaseURL.deletingLastPathComponent()
        defer { try? FileProfileImport.prune(directory, db: db) }
        return try db.transaction {
            let subscription: Subscription?
            if group.isEmpty { subscription = nil }
            else {
                subscription = try Self.subscription(id: group, in: db)
            }
            let rows = try ShareLinkImport.decode(content, subscriptionName: subscription?.remarks)
            for var row in try ProfileTransfer.rekey(rows, ids: rows.map { _ in UUID().uuidString }, subscription: group) {
                if FileProfileImport.isFile(row) {
                    try FileProfileImport.materialize(&row, directory: directory)
                    if row["ConfigType"] == .integer(2), let port = subscription?.preSocksPort { row["PreSocksPort"] = .integer(Int64(port)) }
                }
                row["ConfigVersion"] = .integer(4)
                row["Subid"] = .text(group)
                row["IsSub"] = .integer(isSubscription ? 1 : 0)
                let node = Self.nodeDocument(from: row)
                if !ProfileTransfer.isGroup(row), !FileProfileImport.isFile(row) { _ = try XrayOutbound(node: node, config: settings).build() }
                try Self.insertProfile(row, into: db)
            }
            return rows.count
        }
    }

    static func insertProfile(_ item: RuntimeDatabase.Row, into db: RuntimeDatabase, group: Bool = false) throws {
        // A cloned old record can contain additional SQLite columns. Quote their identifiers and bind every value.
        let keys = item.keys.sorted()
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
        let columns = keys.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let table = group ? "ProfileGroupItem" : "ProfileItem"
        _ = try db.query("INSERT INTO " + table + " (" + columns.joined(separator: ",") + ") VALUES (" + placeholders + ")",
                 keys.compactMap { item[$0] })
    }
}
