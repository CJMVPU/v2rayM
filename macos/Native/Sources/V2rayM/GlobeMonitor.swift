import Foundation
import V2rayMKit

/// DNS is resolved through the Mac's configured resolver. Coordinates are local
/// DB-IP estimates, not packet routes or proof of a CDN's serving location.
private actor GlobeResolver {
    private var database: GlobeGeoDatabase?
    private var loaded = false
    private var cache: [String: (Date, GlobePlace?)] = [:]
    func resolve(_ host: String) -> GlobePlace? {
        if let hit = cache[host], Date().timeIntervalSince(hit.0) < 3600 { return hit.1 }
        if !loaded {
            loaded = true
            if let directory = Bundle.module.url(forResource: "Globe", withExtension: nil) {
                database = try? GlobeGeoDatabase(directory: directory)
            }
        }
        guard let database else { return nil }
        var place: GlobePlace?
        if GlobeGeoDatabase.addressBytes(host) != nil { place = database.lookup(host) }
        else if !host.hasSuffix(".local") && !host.hasSuffix(".lan") && host.contains(".") {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
            var info: UnsafeMutablePointer<addrinfo>?
            if getaddrinfo(host, nil, &hints, &info) == 0 {
                defer { freeaddrinfo(info) }
                var cursor = info
                while let current = cursor {
                    var address = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(current.pointee.ai_addr, current.pointee.ai_addrlen, &address, socklen_t(address.count), nil, 0, NI_NUMERICHOST) == 0 {
                        place = database.lookup(String(cString: address))
                        if place != nil { break }
                    }
                    cursor = current.pointee.ai_next
                }
            }
        }
        if cache.count >= 512 { cache.removeAll(keepingCapacity: true) }
        cache[host] = (Date(), place)
        return place
    }
}

@MainActor final class GlobeMonitor: ObservableObject {
    @Published private(set) var connections: [GlobeConnection] = []
    @Published private(set) var nodePlace: GlobePlace?
    private let resolver = GlobeResolver()
    private var nodeAddress = ""
    private var session = ""
    private var lookups: [String: Task<Void, Never>] = [:]
    private var nodeLookup: Task<Void, Never>?
    private var resolved: [String: GlobePlace] = [:]
    private var attempted = Set<String>()

    func update(state: RuntimeStatus, node: Profile?, entries: [LogEntry]) {
        let nextSession = (state.runningProfileId ?? "") + "|" + (state.coreStartedAt ?? "")
        if session != nextSession {
            session = nextSession; connections = []
        }
        let address = node?.address ?? ""
        if address != nodeAddress {
            nodeAddress = address; nodePlace = nil; nodeLookup?.cancel()
            if !address.isEmpty {
                nodeLookup = Task { [weak self, resolver] in
                    let place = await resolver.resolve(address)
                    guard !Task.isCancelled, let self, self.nodeAddress == address else { return }
                    self.nodePlace = place
                }
            }
        }
        let start = DashboardStatus.date(state.coreStartedAt) ?? .distantPast
        var recent = connections
        for entry in entries {
            guard var connection = GlobeConnection.parse(entry), connection.timestamp >= start else { continue }
            connection.place = resolved[connection.host]
            recent.removeAll { $0.id == connection.id }
            recent.insert(connection, at: 0)
        }
        connections = Array(recent.prefix(24))
        // Bound DNS work during bursts. The UI never waits for a lookup.
        for item in connections.prefix(8) where item.route == "proxy" || item.route == "direct" {
            guard lookups.count < 8, !attempted.contains(item.host) else { continue }
            let host = item.host
            attempted.insert(host)
            lookups[host] = Task { [weak self, resolver] in
                let place = await resolver.resolve(host)
                guard !Task.isCancelled, let self else { return }
                if let place { self.resolved[host] = place }
                self.connections = self.connections.map { item in
                    var copy = item; if copy.host == host { copy.place = place }; return copy
                }
                self.lookups[host] = nil
            }
        }
        if attempted.count > 512 {
            attempted = Set(connections.map(\.host)); resolved = resolved.filter { attempted.contains($0.key) }
        }
    }
}

enum GlobeOrigin {
    static let cities: [GlobePlace] = [
        .init(city: "上海", latitude: 31.2304, longitude: 121.4737),
        .init(city: "北京", latitude: 39.9042, longitude: 116.4074),
        .init(city: "深圳", latitude: 22.5431, longitude: 114.0579),
        .init(city: "香港", latitude: 22.3193, longitude: 114.1694),
        .init(city: "东京", latitude: 35.6762, longitude: 139.6503),
        .init(city: "新加坡", latitude: 1.3521, longitude: 103.8198),
        .init(city: "洛杉矶", latitude: 34.0522, longitude: -118.2437),
    ]
    static func place(_ city: String) -> GlobePlace? { cities.first { $0.city == city } }
}
