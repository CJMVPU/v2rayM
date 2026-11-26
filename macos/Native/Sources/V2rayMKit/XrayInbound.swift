import Foundation

public enum XrayInbound {
    public static func maximumBasePort(secondLocal: Bool, separateLAN: Bool) -> Int {
        if separateLAN { return 65533 }
        return secondLocal ? 65534 : 65535
    }

    /// Ordinary mixed listeners are shared by system-proxy and TUN configurations.
    static func mixed(settings: SettingsValue, fakeDNS: Bool, usingTunnel: Bool,
                      node: SettingsValue) throws -> [SettingsValue] {
        guard let basePort = Int(settings["LocalPort"].text), (1...65535).contains(basePort) else {
            throw ClientFailure("invalid_port")
        }
        if usingTunnel && node["address"].text == "127.0.0.1" && Int(node["port"].text) == basePort { return [] }

        let allowLAN = settings["AllowLANConn"].flag
        let separateLAN = allowLAN && settings["NewPort4LAN"].flag
        let user = settings["User"].text, password = settings["Pass"].text
        if separateLAN && user.isEmpty != password.isEmpty { throw ClientFailure("inbound_lan_credentials_invalid") }

        var sniffing: [String: SettingsValue] = ["enabled": .bool(settings["SniffingEnabled"].flag),
                                                 "routeOnly": .bool(settings["RouteOnly"].flag)]
        var destinations = settings["DestOverride"]
        if fakeDNS && !destinations.items.contains(.string("fakedns")) {
            destinations = .array(destinations.items + [.string("fakedns")])
        }
        if destinations != .null { sniffing["destOverride"] = destinations }
        func listener(_ tag: String, offset: Int, allowRemote: Bool, authenticate: Bool = false) throws -> SettingsValue {
            let port = basePort + offset
            guard port <= 65535 else { throw ClientFailure("invalid_port") }
            var access: [String: SettingsValue] = ["allowTransparent": .bool(false),
                                                    "udp": .bool(settings["UdpEnabled"].flag), "auth": .string("noauth")]
            if authenticate {
                access["auth"] = .string("password")
                access["accounts"] = .array([.object(["user": .string(user), "pass": .string(password)])])
            }
            return .object(["tag": .string(tag), "protocol": .string("mixed"), "port": .number(Double(port)),
                            "listen": .string(allowRemote ? "0.0.0.0" : "127.0.0.1"),
                            "settings": .object(access), "sniffing": .object(sniffing)])
        }
        var result = [try listener("socks", offset: 0, allowRemote: allowLAN && !separateLAN)]
        if settings["SecondLocalPortEnabled"].flag {
            result.append(try listener("socks2", offset: 1, allowRemote: false))
        }
        if separateLAN {
            result.append(try listener("socks3", offset: 2, allowRemote: true, authenticate: !user.isEmpty))
        }
        return result
    }
}

extension XrayInbound {
    static func tunnel(settings: SettingsValue, interface: String, bindInterface: String,
                       hasGlobalIPv6: Bool, sniffing: SettingsValue) throws -> SettingsValue {
        let mtu = Int(settings["Mtu"].text) ?? 1280
        guard (1280...65535).contains(mtu) else { throw ClientFailure("mac_tun_settings_invalid") }
        let useIPv6 = settings["EnableIPv6Address"].flag
        var gateways = [settings["IPv4Address"].text.isEmpty ? "172.18.0.1/30" : settings["IPv4Address"].text]
        if useIPv6 {
            gateways.append(settings["IPv6Address"].text.isEmpty ? "fc00::172:18:0:1/126" : settings["IPv6Address"].text)
        }
        let routes = try TunnelRouteSet.included(excluding: settings["RouteExcludeAddress"].items.map(\.text),
                                                  ipv6: useIPv6 || hasGlobalIPv6)
        var inspection = sniffing
        inspection["routeOnly"] = .bool(true)
        let options: [String: SettingsValue] = [
            "name": .string(interface), "MTU": .number(Double(mtu)), "gateway": .array(gateways.map(SettingsValue.string)),
            "dns": .array(["1.1.1.1", "8.8.8.8"].map(SettingsValue.string)),
            "autoSystemRoutingTable": .array(routes.map(SettingsValue.string)),
            "autoOutboundsInterface": .string(bindInterface.isEmpty ? "auto" : bindInterface)
        ]
        return .object(["tag": .string("tun"), "protocol": .string("tun"), "settings": .object(options), "sniffing": inspection])
    }
}
