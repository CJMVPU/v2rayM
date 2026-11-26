import Foundation
import CryptoKit

enum ProfileTransfer {
    static let kinds: [Int64: String] = [1:"vmess",3:"ss",4:"socks",5:"vless",6:"trojan",7:"hysteria2",9:"wireguard",10:"http",14:"masque"]
    private static let fileNames: [Int64: String] = [13: "outbound"]
    private static let groupNames: [Int64: String] = [101: "policygroup", 102: "proxychain"]
    private static let exportKey = SymmetricKey(size: .bits256)

    static func supportsXray(_ row: RuntimeDatabase.Row) -> Bool {
        row["CoreType"] == nil || row["CoreType"] == .null || row["CoreType"] == .integer(2)
    }

    static func isOrdinary(_ row: RuntimeDatabase.Row) -> Bool {
        guard case .integer(let kind) = row["ConfigType"] else { return false }
        return kinds[kind] != nil
    }

    static func isGroup(_ row: RuntimeDatabase.Row) -> Bool {
        guard case .integer(let kind) = row["ConfigType"] else { return false }
        return groupNames[kind] != nil
    }

    private static func exportID(_ id: String) -> String {
        base64URL(Data(HMAC<SHA256>.authenticationCode(for: Data(id.utf8), using: exportKey).prefix(16)))
    }

    /// Translate only identifiers belonging to this incoming batch. A link cannot name an
    /// existing local node or subscribe a group to an unrelated local subscription.
    static func rekey(_ rows: [RuntimeDatabase.Row], ids: [String], subscription: String) throws -> [RuntimeDatabase.Row] {
        var mapping = [String: String]()
        for (row, id) in zip(rows, ids) {
            if case .text(let old) = row["IndexId"], !old.isEmpty {
                guard mapping.updateValue(id, forKey: old) == nil else { throw ClientFailure("profile_import_duplicate_id") }
            }
        }
        var dependencies = [String: [String]]()
        let result = try zip(rows, ids).map { original, id in
            var row = original
            row["IndexId"] = .text(id)
            if isGroup(row) {
                let node = NativeConfigurationStore.nodeDocument(from: row)
                var extra = try SettingsValue.parse(node["protoExtra"].text)
                guard case .object = extra else { throw ClientFailure("profile_validation_failed") }
                _ = try XrayProfileGraph.memberFilter(extra)
                let children = try childIDs(extra).map { old in
                    guard let member = mapping[old] else { throw ClientFailure("profile_chain_member_missing", old) }
                    return member
                }
                let sub = extra["SubChildItems"].text == "self" ? subscription : ""
                guard !sub.isEmpty || !children.isEmpty else { throw ClientFailure("profile_group_empty") }
                extra["ChildItems"] = children.isEmpty ? .null : .string(children.joined(separator: ","))
                extra["SubChildItems"] = sub.isEmpty ? .null : .string(sub)
                let mode = extra["MultipleLoad"].text.lowercased()
                guard ["", "0", "1", "2", "3", "4", "leastping", "fallback", "random", "roundrobin", "leastload"].contains(mode) else {
                    throw ClientFailure("profile_validation_failed")
                }
                row["ProtoExtra"] = .text(try extra.json())
                dependencies[id] = children
            }
            return row
        }
        // Topological traversal avoids recursive expansion of an untrusted chain during import.
        var outstanding = [String: Int](), parents = [String: [String]]()
        for (id, children) in dependencies {
            let groups = Set(children.filter { dependencies[$0] != nil })
            outstanding[id] = groups.count
            for child in groups { parents[child, default: []].append(id) }
        }
        var ready = outstanding.compactMap { $0.value == 0 ? $0.key : nil }
        var visited = 0
        while let id = ready.popLast() {
            visited += 1
            for parent in parents[id] ?? [] {
                outstanding[parent, default: 0] -= 1
                if outstanding[parent] == 0 { ready.append(parent) }
            }
        }
        guard visited == dependencies.count else { throw ClientFailure("profile_group_cycle") }
        return result
    }

    private static func childIDs(_ extra: SettingsValue) -> [String] {
        extra["ChildItems"].text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static let textColumns = Set("Remarks Address Password Username Network HeaderType RequestHost Path StreamSecurity AllowInsecure Sni Alpn Fingerprint PublicKey ShortId SpiderX Mldsa65Verify Extra Cert CertSha EchConfigList VerifyPeerCertByName Finalmask ProtoExtra TransportExtra Ports Flow Id Security".split(separator: " ").map(String.init))
    private static let numericColumns = Set(["ConfigVersion","ConfigType","CoreType","PreSocksPort","Port","AlterId"])
    private static let booleans = Set(["DisplayLog","MuxEnabled"])
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func base64URL(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func readInner(_ uri: URLComponents) throws -> RuntimeDatabase.Row {
        guard let text = ShareLinkImport.base64Text(String(uri.path.dropFirst())),
              case let .object(fields) = try SettingsValue.parse(text),
              fields["ConfigVersion"]?.text == "4", let kind = Int64(fields["ConfigType"]?.text ?? ""),
              let name = kinds[kind] ?? groupNames[kind] ?? fileNames[kind], uri.host?.lowercased() == (name == "ss" ? "shadowsocks" : name),
              fields["CoreType"] == nil || fields["CoreType"] == .null || fields["CoreType"]?.text == "2" else {
            throw ClientFailure("share_format_unsupported")
        }
        var row: RuntimeDatabase.Row = [:]
        if case .string(let id) = fields["IndexId"] { row["IndexId"] = .text(id) }
        for (key,value) in fields {
            if key == "ProtoExtraObj" || key == "TransportExtraObj" {
                guard case .object = value else { throw ClientFailure("profile_validation_failed") }
                row[String(key.dropLast(3))] = .text(try value.json())
            } else if textColumns.contains(key), case .string(let text) = value { row[key] = .text(text) }
            else if numericColumns.contains(key), let n = Int64(value.text) { row[key] = .integer(n) }
            else if booleans.contains(key), case .bool(let flag) = value { row[key] = .integer(flag ? 1 : 0) }
        }
        if kind == 13 { try FileProfileImport.attachOutbound(fields["CustomOutboundObj"] ?? .null, to: &row) }
        return row
    }

    static func inner(_ row: RuntimeDatabase.Row, directory: URL) throws -> String? {
        guard case .integer(let number) = row["ConfigType"], let name = kinds[number] ?? groupNames[number] ?? fileNames[number], case .text(let id) = row["IndexId"] else { return nil }
        var fields: [String: SettingsValue] = ["IndexId": .string(exportID(id))]
        for (key,value) in row {
            guard textColumns.contains(key) || numericColumns.contains(key) || booleans.contains(key) else { continue }
            switch value {
            case .text(let text) where !text.isEmpty:
                if ["ProtoExtra","TransportExtra"].contains(key), case let .object(object)? = try? SettingsValue.parse(text) {
                    if !object.isEmpty { fields[key + "Obj"] = .object(object) }
                } else { fields[key] = .string(text) }
            case .integer(let n):
                fields[key] = booleans.contains(key) ? .bool(n != 0) : .integer64(n)
            default: break
            }
        }
        if number == 13 {
            fields["CustomOutboundObj"] = try XrayFileProfile.document(NativeConfigurationStore.nodeDocument(from: row), directory: directory)
            fields.removeValue(forKey: "Address")
        }
        if isGroup(row) {
            var extra = fields["ProtoExtraObj"] ?? .object([:])
            let children = childIDs(extra).map(exportID)
            extra["ChildItems"] = children.isEmpty ? .null : .string(children.joined(separator: ","))
            if !extra["SubChildItems"].text.isEmpty { extra["SubChildItems"] = .string("self") }
            fields["ProtoExtraObj"] = extra
        }
        fields["ConfigVersion"] = .number(4)
        if fields["DisplayLog"] == nil { fields["DisplayLog"] = .bool(true) }
        if fields["AlterId"] == nil { fields["AlterId"] = .number(0) }
        let bytes = try JSONEncoder().encode(fields)
        return "v2rayn://" + (name == "ss" ? "shadowsocks" : name) + "/" + base64URL(bytes)
    }

    static func share(_ node: SettingsValue) throws -> String? {
        let scheme = node["configType"].text.lowercased()
        let network = ["","raw","tcp"].contains(node["network"].text) ? "tcp" : node["network"].text
        let proto = try extra(node["protoExtra"]), transport = try extra(node["transportExtra"])
        let password = node["password"].text
        var user = password
        var query: [(String,String)] = []
        func add(_ key: String, _ value: String) { if !value.isEmpty { query.append((key,value)) } }
        func parameter(_ key: String, _ field: String) { add(key, proto[field].text) }
        switch scheme {
        case "socks": user = base64URL(Data((node["username"].text + ":" + password).utf8))
        case "shadowsocks":
            user = base64URL(Data((proto["SsMethod"].text + ":" + password).utf8))
            if network == "ws" {
                var options = ["v2ray-plugin", "mode=websocket"]
                if !transport["Host"].text.isEmpty { options.append("host=" + transport["Host"].text) }
                if !transport["Path"].text.isEmpty { options.append("path=" + transport["Path"].text) }
                if node["streamSecurity"].text == "tls" {
                    options.append("tls")
                    let cert = node["cert"].text.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
                    if !cert.isEmpty { options.append("certRaw=" + cert.replacingOccurrences(of: "=", with: "\\=")) }
                }
                options.append("mux=0")
                add("plugin",options.joined(separator: ";"))
            } else if network == "tcp", transport["RawHeaderType"].text == "http" {
                add("plugin","obfs-local;obfs=http;obfs-host=" + transport["Host"].text)
            }
        case "vless", "trojan":
            if scheme == "vless" { add("encryption",proto["VlessEncryption"].text.isEmpty ? "none" : proto["VlessEncryption"].text) }
            if scheme == "trojan", node["allowInsecure"].text == "true" { add("allowInsecure","1"); add("insecure","1") }
            parameter("flow","Flow")
            add("security", node["streamSecurity"].text.isEmpty && scheme == "vless" ? "none" : node["streamSecurity"].text)
            for (key,field) in [("sni","sni"),("fp","fingerprint"),("pbk","publicKey"),("sid","shortId"),("spx","spiderX"),("pqv","mldsa65Verify"),
                                ("alpn","alpn"),("ech","echConfigList"),("vcn","verifyPeerCertByName"),("pcs","certSha"),("fm","finalmask")] {
                add(key,node[field].text)
            }
            add("type",network)
            if network == "tcp" || network == "kcp" {
                let header = transport[network == "tcp" ? "RawHeaderType" : "KcpHeaderType"].text
                add("headerType",header.isEmpty ? "none" : header)
            }
            // Editors retain settings for the other transports. Only the selected
            // transport may supply query fields such as "mode", "host" and "path".
            switch network {
            case "tcp", "ws", "httpupgrade", "xhttp":
                add("host", transport["Host"].text)
                add("path", transport["Path"].text)
                if network == "xhttp" {
                    add("mode", transport["XhttpMode"].text)
                    add("extra", transport["XhttpExtra"].text)
                }
            case "grpc":
                add("serviceName", transport["GrpcServiceName"].text)
                add("authority", transport["GrpcAuthority"].text)
                add("mode", transport["GrpcMode"].text)
            case "kcp":
                add("seed", transport["KcpSeed"].text)
                add("mtu", transport["KcpMtu"].text)
            default: break
            }
        case "wireguard":
            for (key,field) in [("publickey","WgPublicKey"),("presharedkey","WgPresharedKey"),("reserved","WgReserved"),("address","WgInterfaceAddress"),("dns","WgDns"),("mtu","WgMtu"),("allowedips","WgAllowedIPs"),("keepalive","WgKeepAlive")] { parameter(key,field) }
            add("fm",node["finalmask"].text)
        case "hysteria2":
            guard proto["Hy2RealmUrl"].text.isEmpty else { throw ClientFailure("share_realm_unsupported") }
            for (key,field) in [("sni","sni"),("alpn","alpn"),("pinSHA256","certSha"),("ech","echConfigList")] { add(key,node[field].text) }
            if node["allowInsecure"].text == "true" { add("insecure","1") }
            parameter("mport","Ports")
            if !proto["SalamanderPass"].text.isEmpty {
                add("obfs",proto["GeckoMinPacketSize"].text.isEmpty ? "salamander" : "gecko")
                parameter("obfs-password","SalamanderPass"); parameter("minPacketSize","GeckoMinPacketSize"); parameter("maxPacketSize","GeckoMaxPacketSize")
            }
        case "vmess":
            let type = ["tcp":"RawHeaderType","kcp":"KcpHeaderType","xhttp":"XhttpMode","grpc":"GrpcMode"][network]
            var qr: SettingsValue = .object(["v":.number(2),"ps":node["remarks"],"add":node["address"],"port":node["port"],"id":node["password"],
                "aid":.number(Double(Int(proto["AlterId"].text) ?? 0)), "scy":.string(proto["VmessSecurity"].text),"net":.string(network),
                "type":type.map { transport[$0] } ?? .string("none"),"host":transport[network == "grpc" ? "GrpcAuthority" : "Host"],
                "path":transport[network == "grpc" ? "GrpcServiceName" : network == "kcp" ? "KcpSeed" : "Path"],
                "tls":node["streamSecurity"],"insecure":.string(node["allowInsecure"].text == "true" ? "1" : "0")])
            for (key,field) in [("sni","sni"),("alpn","alpn"),("fp","fingerprint"),("vcn","verifyPeerCertByName"),("pcs","certSha")] { qr[key] = node[field] }
            return "vmess://" + (try JSONEncoder().encode(qr)).base64EncodedString()
        default: return nil
        }
        func escape(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
        var url = URLComponents()
        url.scheme = scheme == "shadowsocks" ? "ss" : scheme
        let host = node["address"].text
        url.host = host.contains(":") && !host.hasPrefix("[") ? "[" + host + "]" : host
        url.port = Int(node["port"].text)
        url.percentEncodedUser = escape(user)
        if !query.isEmpty { url.percentEncodedQuery = query.map { escape($0.0) + "=" + escape($0.1) }.joined(separator:"&") }
        if !node["remarks"].text.isEmpty { url.percentEncodedFragment = escape(node["remarks"].text) }
        guard let link = url.string else { throw ClientFailure("profile_validation_failed") }
        return link
    }

    private static func extra(_ value: SettingsValue) throws -> SettingsValue {
        value.text.isEmpty ? .object([:]) : try SettingsValue.parse(value.text)
    }
}

extension NativeConfigurationStore {
    public func exportProfiles(_ request: SettingsValue, metricsPort: Int) throws -> [SettingsValue] {
        let db = try RuntimeDatabase(url: databaseURL)
        var seen = Set<String>()
        let rows = try request["profileIds"].items.compactMap { value -> RuntimeDatabase.Row? in
            guard seen.insert(value.text).inserted else { return nil }
            guard let row = try db.query("SELECT * FROM ProfileItem WHERE IndexId=?", [.text(value.text)]).first else { return nil }
            return try Self.profileWithLegacyGroup(row, db: db)
        }
        func document(_ format: String, _ content: String, node: SettingsValue? = nil) -> SettingsValue {
            .object(["indexId": .string(node?["indexId"].text ?? ""), "remarks": .string(node?["remarks"].text ?? ""),
                     "format": .string(format), "content": .string(content)])
        }
        var documents = [SettingsValue]()
        if request["includeShareUris"] != .bool(false) {
            let links = try rows.compactMap { try ProfileTransfer.share(Self.nodeDocument(from:$0)) }
            if !links.isEmpty {
                let text = links.joined(separator:"\n") + "\n"
                let encoded = request["base64ShareUris"].flag
                documents.append(document(encoded ? "share-uri-base64" : "share-uri", encoded ? Data(text.utf8).base64EncodedString() : text))
            }
        }
        if request["includeInnerUri"].flag {
            let links = try rows.compactMap { try ProfileTransfer.inner($0, directory: databaseURL.deletingLastPathComponent()) }
            if !links.isEmpty { documents.append(document("inner-uri",links.joined(separator:"\n") + "\n")) }
        }
        if !rows.isEmpty && request["includeClientConfig"] != .bool(false) {
            let snapshot = try configurationSnapshot()
            for row in rows {
                let node = Self.nodeDocument(from:row)
                let config = try snapshot.generate(nodeID: node["indexId"].text, metricsPort: metricsPort)
                documents.append(document("client-config",try config.json(),node:node))
            }
        }
        return documents
    }
}
