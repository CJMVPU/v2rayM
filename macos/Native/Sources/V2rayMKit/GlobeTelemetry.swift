import Foundation
import Darwin

public struct GlobePlace: Codable, Equatable, Sendable {
    public var country: String
    public var city: String
    public var latitude: Double
    public var longitude: Double
    public init(country: String = "", city: String, latitude: Double, longitude: Double) {
        self.country = country; self.city = city; self.latitude = latitude; self.longitude = longitude
    }
    public var displayCity: String {
        let name = city.replacingOccurrences(of: #"\([^)]*\)|（[^）]*）"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let names = ["losangeles": "洛杉矶", "shanghai": "上海", "tokyo": "东京", "singapore": "新加坡",
                     "hongkong": "香港", "sanjose": "圣何塞", "sanfrancisco": "旧金山", "seoul": "首尔",
                     "beijing": "北京", "taipei": "台北", "london": "伦敦", "frankfurtammain": "法兰克福"]
        let key = name.lowercased().filter { !$0.isWhitespace }
        return names[key] ?? (name.isEmpty ? country : name)
    }
}

/// The range files are generated from DB-IP Lite. Unaligned reads are avoided;
/// Data maps the large tables read-only rather than eagerly copying them.
public struct GlobeGeoDatabase: Sendable {
    private let ipv4: Data
    private let ipv6: Data
    private let places: GlobePlaceTable
    public init(directory: URL) throws {
        ipv4 = try Data(contentsOf: directory.appendingPathComponent("ipv4.bin"), options: .mappedIfSafe)
        ipv6 = try Data(contentsOf: directory.appendingPathComponent("ipv6.bin"), options: .mappedIfSafe)
        places = try GlobePlaceTable(url: directory.appendingPathComponent("places.bin"))
        guard ipv4.count % 12 == 0, ipv6.count % 36 == 0 else { throw CocoaError(.fileReadCorruptFile) }
    }
    public func lookup(_ ip: String) -> GlobePlace? {
        guard let bytes = Self.addressBytes(ip), Self.isPublic(bytes) else { return nil }
        let data = bytes.count == 4 ? ipv4 : ipv6
        let width = bytes.count, stride = width * 2 + 4
        var low = 0, high = data.count / stride
        while low < high {
            let mid = (low + high) / 2, offset = mid * stride
            let start = data[offset..<(offset + width)]
            if bytes.lexicographicallyPrecedes(start) { high = mid }
            else { low = mid + 1 }
        }
        guard low > 0 else { return nil }
        let offset = (low - 1) * stride
        guard !data[(offset + width)..<(offset + 2 * width)].lexicographicallyPrecedes(bytes) else { return nil }
        let index = data[(offset + 2 * width)..<(offset + stride)].reduce(0) { ($0 << 8) | Int($1) }
        return places.place(at: index)
    }
    public static func addressBytes(_ ip: String) -> [UInt8]? {
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, ip, &v4) == 1 { return withUnsafeBytes(of: v4) { Array($0) } }
        if inet_pton(AF_INET6, ip, &v6) == 1 {
            let bytes = withUnsafeBytes(of: v6) { Array($0) }
            if bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 255 && bytes[11] == 255 { return Array(bytes.suffix(4)) }
            return bytes
        }
        return nil
    }
    public static func isPublic(_ b: [UInt8]) -> Bool {
        if b.count == 4 {
            return !(b[0] == 0 || b[0] == 10 || b[0] == 127 || b[0] >= 224
                || (b[0] == 169 && b[1] == 254) || (b[0] == 172 && (16...31).contains(b[1]))
                || (b[0] == 192 && b[1] == 168) || (b[0] == 100 && (64...127).contains(b[1]))
                || (b[0] == 198 && (18...19).contains(b[1])))
        }
        return b.count == 16 && (b[0] & 0xe0) == 0x20 // global unicast only
            && !(b[0...3] == [0x20, 0x01, 0x0d, 0xb8][...])
    }
}

public struct GlobeConnection: Identifiable, Equatable, Sendable {
    public var id: String { host + "|" + route }
    public let host: String
    public let port: Int
    public let route: String
    public let timestamp: Date
    public var place: GlobePlace?
    public var isProxy: Bool { route == "proxy" }
    public var routeTitle: String { route == "proxy" ? "代理" : route == "direct" ? "直连" : route == "block" ? "阻断" : route }
    public static func parse(_ entry: LogEntry) -> Self? {
        // Xray access events only: never treat errors or arbitrary log domains as connections.
        guard let range = entry.message.range(of: " accepted ") else { return nil }
        let tail = String(entry.message[range.upperBound...])
        guard let target = tail.split(separator: " ").first,
              target.hasPrefix("tcp:") || target.hasPrefix("udp:"),
              let bracket = tail.firstIndex(of: "["), let end = tail[bracket...].firstIndex(of: "]") else { return nil }
        let routeText = tail[tail.index(after: bracket)..<end]
        guard let route = routeText.split(whereSeparator: { $0 == ">" || $0 == " " }).last else { return nil }
        let value = String(target.dropFirst(4))
        guard let colon = value.lastIndex(of: ":"), let port = Int(value[value.index(after: colon)...]),
              (1...65535).contains(port), port != 53 else { return nil }
        let host = String(value[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        guard !host.isEmpty, host.count <= 253, route != "dns" else { return nil }
        return Self(host: host, port: port, route: String(route), timestamp: DashboardStatus.date(entry.timestamp) ?? .distantPast)
    }
}
