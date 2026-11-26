import Foundation
import Darwin

/// Only these network parameters cross the privilege boundary. The daemon selects its own utun.
public struct TunnelNetworkPlan: Codable {
    public let token: UUID
    public let mtu: Int
    public let gateway: String
    public let ipv6Gateway: String?
    public let routes: [String]

    public init(token: UUID, mtu: Int, gateway: String, ipv6Gateway: String? = nil, routes: [String]) {
        self.token = token
        self.mtu = mtu
        self.gateway = gateway
        self.ipv6Gateway = ipv6Gateway
        self.routes = routes
    }

    public struct Prefix: Equatable, Hashable {
        public let address: String
        public let bits: Int
        public init(_ value: String) throws {
            try self.init(value, network: false)
        }

        fileprivate init(_ value: String, network: Bool) throws {
            let fields = value.split(separator: "/", omittingEmptySubsequences: false)
            guard fields.count == 2, let bits = Int(fields[1]), !fields[0].contains("\0") else {
                throw HelperFailure("invalid_tunnel_prefix")
            }
            let address = String(fields[0])
            let ipv6 = address.contains(":")
            guard (0...(ipv6 ? 128 : 32)).contains(bits) else { throw HelperFailure("invalid_tunnel_prefix") }
            let family = ipv6 ? AF_INET6 : AF_INET
            var bytes = [UInt8](repeating: 0, count: ipv6 ? 16 : 4)
            guard inet_pton(family, address, &bytes) == 1 else { throw HelperFailure("invalid_tunnel_prefix") }
            self.bits = bits
            if network {
                for i in bytes.indices where (i + 1) * 8 > bits {
                    let retained = max(0, bits - i * 8)
                    bytes[i] &= UInt8.max << (8 - retained)
                }
                var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                guard inet_ntop(family, &bytes, &text, socklen_t(text.count)) != nil else { throw HelperFailure("invalid_tunnel_prefix") }
                self.address = String(cString: text)
            } else {
                self.address = address
            }
        }
    }

    /// The utun local address follows its configured gateway within the same prefix, as for IPv4.
    private func localIPv6() throws -> Prefix? {
        guard let ipv6Gateway else { return nil }
        let gateway = try Prefix(ipv6Gateway)
        var bytes = [UInt8](repeating: 0, count: 16)
        guard (1...127).contains(gateway.bits), inet_pton(AF_INET6, gateway.address, &bytes) == 1,
              bytes[0] != 0xff, !(bytes.dropLast().allSatisfy { $0 == 0 } && bytes[15] <= 1) else {
            throw HelperFailure("invalid_tunnel_gateway")
        }
        // A carry past the first host bit would place the local address outside the configured subnet.
        var bit = 127
        while bit >= gateway.bits {
            let mask: UInt8 = 1 << (7 - bit % 8)
            bytes[bit / 8] ^= mask
            if bytes[bit / 8] & mask != 0 {
                var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                guard inet_ntop(AF_INET6, &bytes, &text, socklen_t(text.count)) != nil else { break }
                return try Prefix(String(cString: text) + "/" + String(gateway.bits))
            }
            bit -= 1
        }
        throw HelperFailure("invalid_tunnel_gateway")
    }

    public func validated() throws -> (gateway: Prefix, routes: [Prefix]) {
        let settings = try interfaceConfiguration()
        return (settings.gateway, settings.routes)
    }

    public func interfaceConfiguration() throws -> (gateway: Prefix, routes: [Prefix], localIPv6: Prefix?) {
        guard (1280...65535).contains(mtu), routes.count <= 16384 else { throw HelperFailure("invalid_tunnel_settings") }
        let gateway = try Prefix(gateway)
        guard !gateway.address.contains(":"), (1...31).contains(gateway.bits) else { throw HelperFailure("invalid_tunnel_gateway") }
        // The device configures the local address immediately after the IPv4 peer.
        var v4 = in_addr()
        guard inet_pton(AF_INET, gateway.address, &v4) == 1 else { throw HelperFailure("invalid_tunnel_gateway") }
        let peer = UInt32(bigEndian: v4.s_addr)
        let mask = UInt32.max << (32 - gateway.bits)
        guard peer != 0, peer >> 24 != 127, peer >> 28 < 14, (peer + 1) & mask == peer & mask else {
            throw HelperFailure("invalid_tunnel_gateway")
        }
        var result = [Prefix]()
        var seen = Set<Prefix>()
        for raw in routes {
            let prefix = try Prefix(raw, network: true)
            if prefix.bits == 0 {
                // Preserve Xray's protected default routes. The system default route stays installed.
                for i in 0..<8 {
                    let value = prefix.address.contains(":") ? String(1 << (8+i), radix: 16) + "::" : String(1 << i) + ".0.0.0"
                    let route = try Prefix(value + "/" + String(8-i))
                    if seen.insert(route).inserted { result.append(route) }
                }
            } else if seen.insert(prefix).inserted { result.append(prefix) }
        }
        return (gateway, result, try localIPv6())
    }
}
