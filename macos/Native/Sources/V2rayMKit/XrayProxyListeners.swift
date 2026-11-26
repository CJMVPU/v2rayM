import Darwin
import Foundation

extension XrayInbound {
    /// SystemConfiguration can describe plain unauthenticated proxies at one address per protocol.
    /// Prefer an explicit HTTP listener over the HTTP fallback of Xray's SOCKS/mixed listener.
    static func proxyEndpoints(_ inbounds: [SettingsValue]) -> ProxyEndpoints? {
        var http: ProxyEndpoint?
        var socks: ProxyEndpoint?
        for inbound in inbounds {
            let kind = inbound["protocol"].text.lowercased()
            guard ["http", "socks", "mixed"].contains(kind), plainTCP(inbound),
                  let host = proxyHost(inbound["listen"].text), let port = firstProxyPort(inbound["port"].text) else { continue }
            let settings = inbound["settings"]
            let users = settings["accounts"] == .null ? settings["users"] : settings["accounts"]
            if kind == "http", users.items.isEmpty, http == nil {
                http = ProxyEndpoint(host: host, port: Int(port))
            } else if kind != "http", settings["auth"].text.lowercased() != "password", socks == nil {
                socks = ProxyEndpoint(host: host, port: Int(port))
            }
        }
        guard http != nil || socks != nil else { return nil }
        return ProxyEndpoints(http: http ?? socks, socks: socks)
    }

    // Xray accepts a number, a range or a comma-separated list and binds each port.
    // SystemConfiguration only needs one. Leave environment-variable port expansion to Xray.
    private static func firstProxyPort(_ list: String) -> UInt16? {
        for entry in list.split(separator: ",") {
            let parts = entry.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "-", omittingEmptySubsequences: false)
            guard let first = parts.first.flatMap({ UInt16($0) }) else { continue }
            if parts.count == 1, first > 0 { return first }
            if parts.count == 2, let last = UInt16(parts[1]), max(first, 1) <= last { return max(first, 1) }
        }
        return nil
    }

    private static func plainTCP(_ inbound: SettingsValue) -> Bool {
        let stream = inbound["streamSettings"]
        let tcp = stream["rawSettings"] == .null ? stream["tcpSettings"] : stream["rawSettings"]
        let masks = stream["finalmask"]["tcp"].items
        return ["", "tcp", "raw"].contains(stream["network"].text.lowercased())
            && ["", "none"].contains(stream["security"].text.lowercased())
            && !stream["sockopt"]["acceptProxyProtocol"].flag
            && !tcp["acceptProxyProtocol"].flag
            && ["", "none"].contains(tcp["header"]["type"].text.lowercased())
            && !masks.contains { ["header-custom", "sudoku", "xmc"].contains($0["type"].text.lowercased()) }
    }

    private static func proxyHost(_ listen: String) -> String? {
        switch listen.lowercased() {
        case "", "0.0.0.0": return "127.0.0.1"
        case "::": return "::1"
        case "localhost", "::1": return listen.lowercased()
        default:
            var ipv4 = in_addr()
            if inet_pton(AF_INET, listen, &ipv4) == 1, UInt32(bigEndian: ipv4.s_addr) >> 24 == 127 { return listen }
            var ipv6 = in6_addr()
            if inet_pton(AF_INET6, listen, &ipv6) == 1, withUnsafeBytes(of: ipv6, { $0.dropLast().allSatisfy { $0 == 0 } && $0.last == 1 }) { return "::1" }
            return nil
        }
    }

    private struct SocketBinding {
        let host: String
        let port: UInt16
        var ipv6: Bool { host.contains(":") }
        var wildcard: Bool { host == "::" || host == "0.0.0.0" }

        // Avoid pre-binding sockets occupied by our own running core.
        func overlaps(_ other: Self) -> Bool {
            guard port == other.port else { return false }
            if ipv6 != other.ipv6 { return host == "::" || other.host == "::" }
            return host == other.host || wildcard || other.wildcard
        }

        func check() throws {
            var hints = addrinfo()
            hints.ai_flags = AI_NUMERICHOST
            hints.ai_socktype = SOCK_STREAM
            var list: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, String(port), &hints, &list) == 0, let address = list else { return }
            defer { freeaddrinfo(address) }
            let fd = socket(address.pointee.ai_family, SOCK_STREAM, 0)
            guard fd >= 0 else { throw ClientFailure("proxy_port_in_use") }
            defer { close(fd) }
            guard bind(fd, address.pointee.ai_addr, address.pointee.ai_addrlen) == 0 else { throw ClientFailure("proxy_port_in_use") }
        }
    }

    /// Limit the early conflict check to listener types whose socket requirements are known.
    /// The actual Xray start/rollback remains authoritative for arbitrary custom transports.
    static func checkNewListeners(before: [SettingsValue], after: [SettingsValue]) throws {
        // SOCKS5 UDP ASSOCIATE allocates its own ephemeral datagram socket for each
        // control connection. All three listener types bind only TCP at the configured port.
        func socketBinding(_ entry: SettingsValue) -> SocketBinding? {
            let kind = entry["protocol"].text.lowercased()
            guard ["mixed", "socks", "http"].contains(kind), plainTCP(entry),
                  let port = UInt16(entry["port"].text), port > 0 else { return nil }
            let host = entry["listen"].text
            return SocketBinding(host: host.isEmpty ? "0.0.0.0" : host, port: port)
        }
        let previous = before.compactMap(socketBinding)
        for binding in after.compactMap(socketBinding) where !previous.contains(where: binding.overlaps) {
            try binding.check()
        }
    }
}
