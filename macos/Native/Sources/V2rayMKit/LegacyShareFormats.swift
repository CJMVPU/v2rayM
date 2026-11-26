import Foundation

extension ShareLinkImport {
    static func vmessQR(_ encoded: String) throws -> RuntimeDatabase.Row {
        guard let decoded = base64Text(encoded), let qr = try? SettingsValue.parse(decoded),
              let port = Int64(qr["port"].text), (1...65535).contains(port), !qr["id"].text.isEmpty,
              !qr["add"].text.isEmpty else { throw ClientFailure("profile_validation_failed") }
        let network = ["", "tcp"].contains(qr["net"].text) ? "raw" : qr["net"].text
        var transport: [String: SettingsValue] = [:]
        switch network {
        case "raw", "ws", "httpupgrade", "xhttp":
            transport["Host"] = qr["host"]
            transport["Path"] = qr["path"]
            if network == "raw" { transport["RawHeaderType"] = qr["type"] }
            if network == "xhttp" { transport["XhttpMode"] = qr["type"] }
        case "kcp":
            transport["KcpSeed"] = qr["path"]
            transport["KcpHeaderType"] = qr["type"]
        case "grpc":
            transport["GrpcServiceName"] = qr["path"]
            transport["GrpcAuthority"] = qr["host"]
            transport["GrpcMode"] = qr["type"]
        default: throw ClientFailure("transport_unsupported")
        }
        let proto: SettingsValue = .object(["AlterId": .string(String(Int(qr["aid"].text) ?? 0)),
            "VmessSecurity": .string(qr["scy"].text.isEmpty ? "auto" : qr["scy"].text)])
        var row: RuntimeDatabase.Row = ["ConfigType": .integer(1), "Port": .integer(port), "Network": .text(network),
                                        "ProtoExtra": .text(try proto.json()), "TransportExtra": .text(try SettingsValue.object(transport).json())]
        for (key, column) in [("id","Password"), ("ps","Remarks"), ("add","Address"), ("tls","StreamSecurity"),
                              ("sni","Sni"), ("fp","Fingerprint"), ("alpn","Alpn"), ("vcn","VerifyPeerCertByName"), ("pcs","CertSha")] {
            row[column] = .text(qr[key].text)
        }
        if qr["insecure"].text == "1" { row["AllowInsecure"] = .text("true") }
        return row
    }

    static func applyShadowsocksPlugin(_ plugin: String, to row: inout RuntimeDatabase.Row,
                                       transport: inout [String: SettingsValue], network: inout String,
                                       security: inout String) throws {
        let tokens = plugin.split(separator: ";").map(String.init)
        var parameters: [String: String] = [:]
        for token in tokens.dropFirst() {
            let pair = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2 { parameters[String(pair[0])] = String(pair[1]) }
        }
        switch tokens.first {
        case "simple-obfs", "obfs-local":
            guard parameters["obfs"] == "http", let host = parameters["obfs-host"], !host.isEmpty else {
                throw ClientFailure("share_plugin_unsupported")
            }
            network = "raw"
            transport["RawHeaderType"] = .string("http")
            transport["Host"] = .string(host)
        case "v2ray-plugin":
            guard parameters["mode"] ?? "websocket" == "websocket", parameters["mux"] ?? "0" == "0" else {
                throw ClientFailure("share_plugin_unsupported")
            }
            network = "ws"
            if let host = parameters["host"] {
                transport["Host"] = .string(host)
                row["Sni"] = .text(host)
            }
            if let path = parameters["path"] {
                transport["Path"] = .string(path.replacingOccurrences(of: "\\=", with: "=")
                    .replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\\\", with: "\\"))
            }
            if tokens.contains("tls") {
                security = "tls"
                if let raw = parameters["certRaw"] {
                    row["Cert"] = .text("-----BEGIN CERTIFICATE-----\n" + raw.replacingOccurrences(of: "\\=", with: "=") + "\n-----END CERTIFICATE-----")
                }
            }
        default: throw ClientFailure("share_plugin_unsupported")
        }
    }
}

extension ShareLinkImport {
    static func sip008(_ document: SettingsValue) throws -> [RuntimeDatabase.Row]? {
        let servers: [SettingsValue]
        if case .array(let items) = document["servers"], document["outbounds"] == .null {
            servers = items
        } else if case .array(let items) = document, items.contains(where: { $0["server_port"] != .null }) {
            servers = items
        } else {
            return nil
        }
        guard !servers.isEmpty else { throw ClientFailure("profile_import_empty") }
        return try servers.map { item in
            guard case .string(let host) = item["server"], !host.isEmpty,
                  let port = Int64(item["server_port"].text), (1...65535).contains(port),
                  case .string(let method) = item["method"], !method.isEmpty,
                  case .string(let password) = item["password"], !password.isEmpty else {
                throw ClientFailure("profile_validation_failed")
            }
            var options: [String: SettingsValue] = ["SsMethod": .string(method)]
            if let id = UUID(uuidString: item["id"].text) {
                options["Sip008ServerId"] = .string(id.uuidString)
            }
            var row: RuntimeDatabase.Row = ["ConfigType": .integer(3), "Address": .text(host), "Port": .integer(port),
                "Password": .text(password), "Remarks": .text(item["remarks"].text.isEmpty ? host : item["remarks"].text),
                "ProtoExtra": .text(try SettingsValue.object(options).json())]
            var network = "raw", security = ""
            var transport: [String: SettingsValue] = [:]
            if !item["plugin"].text.isEmpty {
                let plugin = [item["plugin"].text, item["plugin_opts"].text].filter { !$0.isEmpty }.joined(separator: ";")
                try applyShadowsocksPlugin(plugin, to: &row, transport: &transport, network: &network, security: &security)
            }
            row["Network"] = .text(network)
            row["StreamSecurity"] = .text(security)
            row["TransportExtra"] = .text(try SettingsValue.object(transport).json())
            return row
        }
    }
}
