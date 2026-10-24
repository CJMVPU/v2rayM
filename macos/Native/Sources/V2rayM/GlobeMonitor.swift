import Foundation
import V2rayMKit

/// DNS is resolved through the Mac's configured resolver. Coordinates are local
/// DB-IP estimates, not packet routes or proof of a CDN's serving location.
private actor GlobeResolver {
    private var database: GlobeGeoDatabase?
    private var loaded = false
    func resolve(_ host: String) -> GlobePlace? {
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
        return place
    }
}

@MainActor final class GlobeMonitor: ObservableObject {
    @Published private(set) var connections: [GlobeConnection] = []
    @Published private(set) var nodePlace: GlobePlace?
    private let resolver: GlobeLookupCache
    private var nodeAddress = ""
    private var session = ""
    private var lookups: [String: Task<Void, Never>] = [:]
    private var nodeLookup: Task<Void, Never>?
    init(resolver: GlobeLookupCache? = nil) {
        let database = GlobeResolver()
        self.resolver = resolver ?? GlobeLookupCache { host in await database.resolve(host) }
    }

    func update(state: RuntimeStatus, node: Profile?, entries: [LogEntry]) {
        let nextSession = (state.runningProfileId ?? "") + "|" + (state.coreStartedAt ?? "")
        if session != nextSession {
            session = nextSession; connections = []
        }
        let address = node?.address ?? ""
        if address != nodeAddress {
            nodeAddress = address; nodePlace = nil; nodeLookup?.cancel(); nodeLookup = nil
        }
        if !address.isEmpty, nodeLookup == nil {
            nodeLookup = Task { [weak self, resolver] in
                let place = await resolver.resolve(address)
                guard !Task.isCancelled, let self, self.nodeAddress == address else { return }
                if self.nodePlace != place { self.nodePlace = place }
                self.nodeLookup = nil
            }
        }
        let start = DashboardStatus.date(state.coreStartedAt) ?? .distantPast
        let recent = GlobeConnection.recent(entries, previous: connections, since: start)
        if recent != connections { connections = recent }
        // Bound DNS work during bursts. The UI never waits for a lookup.
        for item in connections.prefix(8) where item.route == "proxy" || item.route == "direct" {
            guard lookups.count < 8, lookups[item.host] == nil else { continue }
            let host = item.host
            lookups[host] = Task { [weak self, resolver] in
                let place = await resolver.resolve(host)
                guard !Task.isCancelled, let self else { return }
                let updated = self.connections.map { item in
                    var copy = item; if copy.host == host { copy.place = place }; return copy
                }
                if updated != self.connections { self.connections = updated }
                self.lookups[host] = nil
            }
        }

    }
}
