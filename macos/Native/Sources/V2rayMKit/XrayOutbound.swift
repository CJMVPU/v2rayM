import Foundation
import Security

/// Generates an Xray outbound from a stored node and the user's core settings.
struct XrayOutbound {
    // Matches cipherFromString and shadowsocks_2022.GetCipherMethod in the bundled Xray revision.
    static let shadowsocksMethods: Set<String> = [
        "aes-128-gcm", "aead_aes_128_gcm", "aes-256-gcm", "aead_aes_256_gcm",
        "chacha20-poly1305", "aead_chacha20_poly1305", "chacha20-ietf-poly1305",
        "xchacha20-poly1305", "aead_xchacha20_poly1305", "xchacha20-ietf-poly1305",
        "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305"
    ]

    static func acceptsShadowsocksPassword(_ password: String, method: String) -> Bool {
        guard shadowsocksMethods.contains(method), !password.isEmpty else { return false }
        guard method.hasPrefix("2022-") else { return true }
        let length = method == "2022-blake3-aes-128-gcm" ? 16 : 32
        let keys = password.components(separatedBy: ":")
        guard keys.count == 1 || method != "2022-blake3-chacha20-poly1305" else { return false }
        return keys.allSatisfy { key in
            // The pinned Xray accepts raw bytes only if standard Base64 decoding fails.
            let encoded = key.utf8.filter { $0 != 13 && $0 != 10 }
            let padding = encoded.drop(while: { $0 != 61 })
            if encoded.count.isMultiple(of: 4), padding.count <= 2, padding.allSatisfy({ $0 == 61 }),
               let bytes = Data(base64Encoded: Data(encoded)) { return bytes.count == length }
            return key.utf8.count == length
        }
    }

    static func wireGuardKeyIdentity(_ value: String) -> String? {
        if value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) {
            return value.lowercased()
        }
        let unpadded = value.hasSuffix("=") ? String(value.dropLast()) : value
        let raw = String(decoding: unpadded.utf8.filter { $0 != 13 && $0 != 10 }, as: UTF8.self)
        guard raw.utf8.count == 43 else { return nil }
        guard !raw.contains("=") else { return nil }
        let standard = raw.contains("+") || raw.contains("/")
        guard !standard || (!raw.contains("-") && !raw.contains("_")) else { return nil }
        let base64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let bytes = Data(base64Encoded: base64 + "="), bytes.count == 32 else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func acceptsWireGuardKeys(secret: String, options: SettingsValue) -> Bool {
        let shared = options["WgPresharedKey"].text
        return wireGuardKeyIdentity(secret) != nil && wireGuardKeyIdentity(options["WgPublicKey"].text) != nil
            && (shared.isEmpty || wireGuardKeyIdentity(shared) != nil)
    }

    let node: SettingsValue
    let config: SettingsValue
    let protocolOptions: SettingsValue
    let transport: SettingsValue

    init(node: SettingsValue, config: SettingsValue) throws {
        self.node = node
        self.config = config
        func options(_ key: String) throws -> SettingsValue {
            guard !node[key].text.isEmpty else { return .object([:]) }
            guard case .object(let values) = try SettingsValue.parse(node[key].text) else {
                throw ClientFailure("profile_validation_failed")
            }
            return .object(values)
        }
        protocolOptions = try options("protoExtra")
        transport = try options("transportExtra")
    }

    func build(tag: String = "proxy") throws -> SettingsValue {
        let core = node["coreType"]
        guard core == .null || core.text == "xray" else { throw ClientFailure("xray_only_profile_required") }
        guard let port = Int(node["port"].text), (1...65535).contains(port), !node["address"].text.isEmpty else {
            throw ClientFailure("profile_validation_failed")
        }
        let kind = node["configType"].text.lowercased()
        var settings: [String: SettingsValue] = ["address": node["address"], "port": .number(Double(port))]
        switch kind {
        case "vmess", "vless":
            settings["id"] = node["password"]
            settings["email"] = .string("t@t.tt")
            if kind == "vmess" {
                guard UUID(uuidString: node["password"].text) != nil else { throw ClientFailure("profile_validation_failed") }
                settings["alterId"] = .number(Double(Int(protocolOptions["AlterId"].text) ?? 0))
                let security = protocolOptions["VmessSecurity"].text
                settings["security"] = .string(["aes-128-gcm", "chacha20-poly1305", "auto", "none", "zero"].contains(security) ? security : "auto")
            } else {
                guard !node["password"].text.isEmpty else { throw ClientFailure("profile_validation_failed") }
                settings["encryption"] = protocolOptions["VlessEncryption"].optionalValue
                settings["flow"] = protocolOptions["Flow"].nonemptyString
            }
        case "trojan", "shadowsocks":
            settings["password"] = node["password"]
            settings["ota"] = .bool(false)
            settings["level"] = .number(1)
            if kind == "shadowsocks" {
                let method = protocolOptions["SsMethod"].text.lowercased()
                guard Self.shadowsocksMethods.contains(method) else {
                    throw ClientFailure("profile_validation_failed", "当前 Xray 内核不支持此 Shadowsocks 加密方式。")
                }
                guard Self.acceptsShadowsocksPassword(node["password"].text, method: method) else {
                    throw ClientFailure("profile_validation_failed", "Shadowsocks 密钥格式或长度无效。")
                }
                settings["method"] = .string(method)
                if protocolOptions["Uot"].flag { settings["uot"] = .bool(true) }
            }
        case "hysteria2": settings["version"] = .number(2)
        case "masque": break
        case "wireguard":
            settings = try wireGuardSettings(port: port)
        case "socks", "http":
            if !node["username"].text.isEmpty && !node["password"].text.isEmpty {
                settings["user"] = node["username"]
                settings["pass"] = node["password"]
                settings["level"] = .number(1)
                settings["email"] = .string("t@t.tt")
            }
            if kind == "http", !protocolOptions["HttpHeaders"].text.isEmpty {
                settings["headers"] = try SettingsValue.parse(protocolOptions["HttpHeaders"].text)
            }
        default: throw ClientFailure("xray_only_profile_required")
        }
        let stream = try streamSettings()
        var mux: [String: SettingsValue] = ["enabled": .bool(false), "concurrency": .number(-1)]
        if ["vmess", "vless"].contains(kind), node["muxEnabled"].flag, stream["network"].text != "xhttp" {
            mux["enabled"] = .bool(true)
            if protocolOptions["Flow"].text.isEmpty {
                mux["concurrency"] = config["Mux4RayItem"]["Concurrency"]
            } else {
                mux["xudpConcurrency"] = config["Mux4RayItem"]["XudpConcurrency"]
                mux["xudpProxyUDP443"] = config["Mux4RayItem"]["XudpProxyUDP443"]
            }
        }
        if ["wireguard", "hysteria2", "masque"].contains(kind) { mux = ["enabled": .bool(false)] }
        return .object(["tag": .string(tag), "protocol": .string(kind == "hysteria2" ? "hysteria" : kind), "settings": .object(settings),
                        "streamSettings": stream, "mux": .object(mux)])
    }

    private func wireGuardSettings(port: Int) throws -> [String: SettingsValue] {
        func list(_ key: String) -> [String]? {
            let text = protocolOptions[key].text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text.split { $0 == "," || $0.isNewline }
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        guard Self.acceptsWireGuardKeys(secret: node["password"].text, options: protocolOptions) else {
            throw ClientFailure("profile_validation_failed", "WireGuard 密钥须为 32 字节的 Base64 或十六进制编码。")
        }
        let address = node["address"].text
        let host = address.contains(":") && !address.hasPrefix("[") ? "[\(address)]" : address
        var peer: [String: SettingsValue] = ["endpoint": .string("\(host):\(port)"),
                                              "publicKey": .string(protocolOptions["WgPublicKey"].text)]
        peer["preSharedKey"] = protocolOptions["WgPresharedKey"].optionalValue
        if let allowed = list("WgAllowedIPs") { peer["allowedIPs"] = .array(allowed.map(SettingsValue.string)) }
        if !protocolOptions["WgKeepAlive"].text.isEmpty {
            guard let seconds = UInt16(protocolOptions["WgKeepAlive"].text) else { throw ClientFailure("profile_validation_failed") }
            peer["keepAlive"] = .number(Double(seconds))
        }
        let mtu = Int(protocolOptions["WgMtu"].text) ?? 0
        var settings: [String: SettingsValue] = [
            "address": .array((list("WgInterfaceAddress") ?? ["172.16.0.2/32"]).map(SettingsValue.string)),
            "secretKey": node["password"], "mtu": .number(Double(mtu > 0 ? mtu : 1280)), "peers": .array([.object(peer)])
        ]
        if let reserved = list("WgReserved") {
            guard reserved.count == 3 else {
                throw ClientFailure("profile_validation_failed", "WireGuard Reserved 须留空或填写三个字节。")
            }
            settings["reserved"] = .array(try reserved.map {
                guard let byte = UInt8($0) else { throw ClientFailure("profile_validation_failed") }
                return .number(Double(byte))
            })
        }
        if let dns = list("WgDns") { settings["remoteDNS"] = .array(dns.map(SettingsValue.string)) }
        return settings
    }

    private static func commaSeparated(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func rawHTTPSettings(host: String, path: String, agent: String) -> SettingsValue {
        let agents = [
            "chrome": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/92.0.4515.131 Safari/537.36",
            "firefox": "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:90.0) Gecko/20100101 Firefox/90.0",
            "safari": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.1.1 Safari/605.1.15",
            "edge": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36 Edg/91.0.864.70",
            "none": "",
            "golang": "Go-http-client/1.1",
            "curl": "curl/7.68.0",
        ]
        let resolvedAgent = agents[agent] ?? agent
        let headers: SettingsValue = .object([
            "Host": .array(Self.commaSeparated(host).map(SettingsValue.string)),
            "User-Agent": .array(resolvedAgent.isEmpty ? [] : [.string(resolvedAgent)]),
            "Accept-Encoding": .array([.string("gzip, deflate")]),
            "Connection": .array([.string("keep-alive")]), "Pragma": .string("no-cache")
        ])
        let paths = Self.commaSeparated(path).map(SettingsValue.string)
        return .object(["header": .object(["type": .string("http"), "request": .object([
            "version": .string("1.1"), "method": .string("GET"), "path": .array(paths.isEmpty ? [.string("/")] : paths), "headers": headers
        ])])])
    }

    private func configureKCP(_ stream: inout [String: SettingsValue]) {
        let defaults = config["KcpItem"]
        var values = [String: SettingsValue]()
        for key in ["Mtu", "Tti", "UplinkCapacity", "DownlinkCapacity", "CwndMultiplier", "MaxSendingWindow"] {
            values[key.prefix(1).lowercased() + key.dropFirst()] = defaults[key].optionalValue
        }
        if let mtu = Int(transport["KcpMtu"].text), mtu > 0 { values["mtu"] = .number(Double(mtu)) }
        stream["kcpSettings"] = .object(values)
        let seed = transport["KcpSeed"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        var first: SettingsValue = .object(["type": .string("mkcp-legacy")])
        if !seed.isEmpty { first["settings"]["value"] = .string(seed) }
        var masks = [first]
        let header = transport["KcpHeaderType"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ["srtp", "utp", "wechat-video", "dtls", "wireguard", "dns"].contains(header) {
            masks.append(.object(["type": .string("mkcp-legacy"),
                                  "settings": .object(["header": .string(header == "wechat-video" ? "wechat" : header)])]))
        }
        stream["finalmask"] = .object(["udp": .array(masks)])
    }

    private func streamSettings() throws -> SettingsValue {
        let requested = node["network"].text
        let network: String
        switch node["configType"].text.lowercased() {
        case "hysteria2": network = "hysteria"
        case "masque": network = "masque"
        default: network = ["", "tcp"].contains(requested) ? "raw" : requested
        }
        var stream: [String: SettingsValue] = ["network": .string(network)]
        let host = transport[network == "grpc" ? "GrpcAuthority" : "Host"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        let basic = config["CoreBasicItem"]
        var options: [String: SettingsValue] = [:]
        if !host.isEmpty { options["host"] = .string(host) }
        options["path"] = transport["Path"].nonemptyString
        switch network {
        case "hysteria":
            stream["hysteriaSettings"] = .object(["version": .number(2), "auth": node["password"]])
            stream["finalmask"] = try hysteriaMask()
        case "masque":
            let login = Data((node["username"].text + ":" + node["password"].text).utf8).base64EncodedString()
            var headers = ["Authorization": SettingsValue.string("Basic " + login)]
            let customHeaders = protocolOptions["MasqueHeaders"].text
            if !customHeaders.isEmpty {
                headers = [:]
                for line in customHeaders.components(separatedBy: .newlines) {
                    guard let split = line.firstIndex(of: ":") else { continue }
                    let key = line[..<split].trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty else { continue }
                    let value = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
                    if let existing = headers.keys.first(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
                        headers[existing] = .string((headers[existing]?.text ?? "") + ", " + value)
                    } else { headers[key] = .string(value) }
                }
            }
            var masque: [String: SettingsValue] = [:]
            if !headers.isEmpty { masque["headers"] = .object(headers) }
            masque["path"] = protocolOptions["MasquePath"].nonemptyString
            stream["masqueSettings"] = .object(masque)
        case "ws", "httpupgrade":
            if let agent = basic["DefUserAgent"].nonemptyString {
                options["headers"] = .object(["User-Agent": agent])
            }
            stream[network + "Settings"] = .object(options)
        case "xhttp":
            let mode = transport["XhttpMode"].text
            if ["auto", "packet-up", "stream-up", "stream-one"].contains(mode) { options["mode"] = .string(mode) }
            if !transport["XhttpExtra"].text.isEmpty { options["extra"] = try SettingsValue.parse(transport["XhttpExtra"].text) }
            stream["xhttpSettings"] = .object(options)
        case "grpc":
            let grpc = config["GrpcItem"]
            var fields: [String: SettingsValue] = ["serviceName": .string(transport["GrpcServiceName"].text),
                "multiMode": .bool(transport["GrpcMode"].text == "multi")]
            fields["authority"] = transport["GrpcAuthority"].nonemptyString
            fields["user_agent"] = basic["DefUserAgent"].nonemptyString
            for (input, output) in [("IdleTimeout","idle_timeout"), ("HealthCheckTimeout","health_check_timeout"),
                                    ("PermitWithoutStream","permit_without_stream"), ("InitialWindowsSize","initial_windows_size")] {
                fields[output] = grpc[input].optionalValue
            }
            stream["grpcSettings"] = .object(fields)
        case "raw":
            if transport["RawHeaderType"].text.trimmingCharacters(in: .whitespacesAndNewlines) == "http" {
                stream["rawSettings"] = rawHTTPSettings(host: host, path: transport["Path"].text.trimmingCharacters(in: .whitespacesAndNewlines),
                                                        agent: basic["DefUserAgent"].text)
            }
        case "kcp":
            configureKCP(&stream)
        default: throw ClientFailure("transport_unsupported")
        }
        let fingerprint = node["fingerprint"].nonemptyString ?? basic["DefFingerprint"].optionalValue
        switch node["streamSecurity"].text {
        case "", "none": break
        case "tls":
            var tls: [String: SettingsValue] = [:]
            tls["serverName"] = node["sni"].nonemptyString ?? Self.commaSeparated(host).first.map(SettingsValue.string)
            tls["fingerprint"] = fingerprint
            let protocols = Self.commaSeparated(node["alpn"].text)
            if !protocols.isEmpty {
                tls["alpn"] = .array(protocols.map(SettingsValue.string))
            }
            tls["echConfigList"] = node["echConfigList"].nonemptyString
            tls["verifyPeerCertByName"] = node["verifyPeerCertByName"].nonemptyString
            if !node["cert"].text.isEmpty {
                tls["certificates"] = try Self.certificates(node["cert"].text)
                tls["disableSystemRoot"] = .bool(true)
            } else { tls["pinnedPeerCertSha256"] = node["certSha"].nonemptyString }
            stream["security"] = .string("tls")
            stream["tlsSettings"] = .object(tls)
        case "reality":
            guard !node["publicKey"].text.isEmpty else { throw ClientFailure("profile_validation_failed") }
            var fields: [String: SettingsValue] = ["show": .bool(false), "serverName": .string(node["sni"].text)]
            fields["fingerprint"] = fingerprint
            for key in ["publicKey","shortId","spiderX","mldsa65Verify"] { fields[key] = node[key].optionalValue }
            stream["security"] = .string("reality")
            stream["realitySettings"] = .object(fields)
        default: throw ClientFailure("stream_security_unsupported")
        }
        if !node["finalmask"].text.isEmpty { stream["finalmask"] = try SettingsValue.parse(node["finalmask"].text) }
        return .object(stream)
    }

    private func hysteriaMask() throws -> SettingsValue {
        let defaults = config["HysteriaItem"]
        func speed(_ key: String) -> Int {
            if let n = Int(protocolOptions[key].text), n >= 0 { return n }
            return Int(defaults[key].text) ?? 0
        }
        let up = speed("UpMbps"), down = speed("DownMbps")
        var quic: [String: SettingsValue] = ["congestion": .string(up > 0 || down > 0 ? "brutal" : "bbr")]
        if up > 0 { quic["brutalUp"] = .string("\(up)mbps") }
        if down > 0 { quic["brutalDown"] = .string("\(down)mbps") }
        var masks: [SettingsValue] = []
        if let password = protocolOptions["SalamanderPass"].nonemptyString {
            var salamander = ["password": SettingsValue.string(password.text.trimmingCharacters(in: .whitespacesAndNewlines))]
            let min = protocolOptions["GeckoMinPacketSize"].text, max = protocolOptions["GeckoMaxPacketSize"].text
            if !min.isEmpty || !max.isEmpty { salamander["packetSize"] = .string(min + "-" + max) }
            masks.append(.object(["type": .string("salamander"), "settings": .object(salamander)]))
        }
        let realm = protocolOptions["Hy2RealmUrl"].text, ports = protocolOptions["Ports"].text
        if !realm.isEmpty {
            guard var url = URLComponents(string: realm), ["realm", "realm+http"].contains(url.scheme),
                  url.host != nil else { throw ClientFailure("profile_validation_failed") }
            let servers = (url.queryItems ?? []).filter { $0.name.lowercased() == "stun" }.compactMap(\.value)
            url.query = nil
            url.fragment = nil
            guard let normalized = url.string else { throw ClientFailure("profile_validation_failed") }
            masks.append(.object(["type": .string("realm"), "settings": .object([
                "url": .string(normalized), "stunServers": .array(servers.map(SettingsValue.string))])]))
        } else if ports.contains(where: { ":-,".contains($0) }) {
            let configured = Int(defaults["HopInterval"].text) ?? 0
            let interval = protocolOptions["HopInterval"].nonemptyString ?? .string(String(configured >= 5 ? configured : 30))
            masks.append(.object(["type": .string("udphop"), "settings": .object([
                "mode": .string("intervallocal,intervalremote"), "interval": interval,
                "remotePorts": .string(ports.replacingOccurrences(of: ":", with: "-"))])]))
        }
        return .object(["quicParams": .object(quic), "udp": .array(masks)])
    }

    private static func certificates(_ pem: String) throws -> SettingsValue {
        let begin = "-----BEGIN CERTIFICATE-----", end = "-----END CERTIFICATE-----"
        var input = pem[...]
        var result: [SettingsValue] = []
        while let start = input.range(of: begin) {
            guard let stop = input[start.upperBound...].range(of: end) else { throw ClientFailure("profile_certificate_invalid") }
            let base64 = input[start.upperBound..<stop.lowerBound].filter { !$0.isWhitespace }
            guard let der = Data(base64Encoded: String(base64)), SecCertificateCreateWithData(nil, der as CFData) != nil else {
                throw ClientFailure("profile_certificate_invalid")
            }
            result.append(.object(["usage": .string("verify"),
                                   "certificate": .array([begin, String(base64), end, ""].map(SettingsValue.string))]))
            input = input[stop.upperBound...]
        }
        guard !result.isEmpty else { throw ClientFailure("profile_certificate_invalid") }
        return .array(result)
    }
}

private extension SettingsValue {
    var nonemptyString: SettingsValue? { text.isEmpty ? nil : .string(text) }
    var optionalValue: SettingsValue? { self == .null ? nil : self }
}
