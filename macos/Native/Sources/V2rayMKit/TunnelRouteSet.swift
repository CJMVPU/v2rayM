import Darwin
import Foundation

/// Covers the default routes with the minimum CIDR prefixes outside the excluded networks.
struct TunnelRouteSet {
    private struct Prefix {
        var bytes: [UInt8]
        var length: Int

        init(bytes: [UInt8], length: Int) {
            self.bytes = bytes
            self.length = length
        }

        init(_ cidr: String) throws {
            let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, let length = Int(parts[1]) else { throw ClientFailure("mac_tun_settings_invalid") }
            let ip = String(parts[0])
            let ipv6 = ip.contains(":")
            var bytes = [UInt8](repeating: 0, count: ipv6 ? 16 : 4)
            guard !ip.contains("\0"), (0...bytes.count * 8).contains(length),
                  inet_pton(ipv6 ? AF_INET6 : AF_INET, ip, &bytes) == 1 else {
                throw ClientFailure("mac_tun_settings_invalid")
            }
            self.init(bytes: bytes, length: length)
        }

        func bit(at index: Int) -> UInt8 { (bytes[index / 8] >> (7 - index % 8)) & 1 }

        func allowed(excluding: [Prefix], into result: inout [String]) {
            if excluding.contains(where: { $0.length <= length }) { return }
            if excluding.isEmpty {
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                bytes.withUnsafeBytes { address in
                    _ = inet_ntop(bytes.count == 4 ? AF_INET : AF_INET6, address.baseAddress, &buffer, socklen_t(buffer.count))
                }
                result.append(String(cString: buffer) + "/\(length)")
                return
            }
            let left = Prefix(bytes: bytes, length: length + 1)
            left.allowed(excluding: excluding.filter { $0.bit(at: length) == 0 }, into: &result)
            var right = left
            right.bytes[length / 8] |= 1 << (7 - length % 8)
            right.allowed(excluding: excluding.filter { $0.bit(at: length) == 1 }, into: &result)
        }
    }

    static func included(excluding cidrs: [String], ipv6: Bool) throws -> [String] {
        guard cidrs.count <= 128 else { throw ClientFailure("mac_tun_settings_invalid") }
        let exclusions = try cidrs.map(Prefix.init)
        var result: [String] = []
        for width in ipv6 ? [4, 16] : [4] {
            let root = Prefix(bytes: [UInt8](repeating: 0, count: width), length: 0)
            root.allowed(excluding: exclusions.filter { $0.bytes.count == width }, into: &result)
        }
        return result
    }
}
