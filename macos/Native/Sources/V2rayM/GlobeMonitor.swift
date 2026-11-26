import Foundation
import V2rayMKit

/// Node hostnames use the Mac’s resolver. Connection destinations reach the
/// local DB-IP lookup only when the access record already contains an IP.
private final class GlobeResolver: @unchecked Sendable {
    private var database: GlobeGeoDatabase?
    private var loaded = false
    private let lock = NSLock()
    private let executor = BoundedLookupExecutor()
    private func loadDatabase() -> GlobeGeoDatabase? {
        lock.lock(); defer { lock.unlock() }
        if !loaded {
            database = Bundle.module.url(forResource: "Globe", withExtension: nil)
                .flatMap { try? GlobeGeoDatabase(directory: $0) }
            loaded = true
        }
        return database
    }
    func resolve(_ host: String) async -> GlobePlace? {
        await executor.run { [self] in
            guard let database = loadDatabase() else { return nil }
            return Self.lookup(host, database: database)
        }
    }
    private static func lookup(_ host: String, database: GlobeGeoDatabase) -> GlobePlace? {
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

protocol RecentConnectionParsing: Sendable {
    func recent(_ entries: [LogEntry], since start: Date) async -> [GlobeConnection]
}

/// Parsing dense batches must yield the UI executor. Log polls are single-flight
/// and commit their cursor only after checking the session again.
actor RecentConnectionParser: RecentConnectionParsing {
    func recent(_ entries: [LogEntry], since start: Date) -> [GlobeConnection] {
        GlobeConnection.recent(entries, previous: [], since: start)
    }
}

@MainActor final class GlobeMonitor: ObservableObject {
    struct Session: Equatable {
        let id: UUID?
        let profile: String?
        let startedAt: String?
        init(_ state: RuntimeStatus?) {
            id = state?.coreSessionID
            profile = state?.runningProfileId
            startedAt = state?.coreStartedAt
        }
        var start: Date { DashboardStatus.date(startedAt) ?? .distantPast }
    }
    @Published private(set) var connections: [GlobeConnection] = []
    @Published private(set) var nodePlace: GlobePlace?
    private let resolver: GlobeLookupCache
    private var nodeAddress = ""
    private var session = Session(nil)
    private var lookups: [String: Task<Void, Never>] = [:]
    private var nodeLookup: Task<Void, Never>?
    init(resolver: GlobeLookupCache? = nil) {
        let database = GlobeResolver()
        self.resolver = resolver ?? GlobeLookupCache { host in await database.resolve(host) }
    }

    func update(state: RuntimeStatus, node: Profile?, recent: [GlobeConnection]) {
        let nextSession = Session(state)
        if session != nextSession {
            session = nextSession; connections = []
            lookups.values.forEach { $0.cancel() }; lookups.removeAll()
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
        if !recent.isEmpty {
            let merged = GlobeConnection.merging(recent, previous: connections, since: nextSession.start)
            if merged != connections { connections = merged }
        }
        // Resolving an access-log hostname here would send browsing destinations
        // to the system resolver independently of the active proxy’s DNS policy.
        for item in connections.prefix(8) where item.route == "proxy" || item.route == "direct" {
            guard lookups.count < 8, lookups[item.host] == nil, item.place == nil,
                  GlobeGeoDatabase.addressBytes(item.host) != nil else { continue }
            let host = item.host
            lookups[host] = Task { [weak self, resolver] in
                let place = await resolver.resolve(host)
                guard !Task.isCancelled, let self, self.session == nextSession else { return }
                let updated = self.connections.map { item in
                    var copy = item; if copy.host == host { copy.place = place }; return copy
                }
                if updated != self.connections { self.connections = updated }
                self.lookups[host] = nil
            }
        }

    }
}
