import Foundation

/// Each dot owns its route and birth time. Removing an emitter never removes
/// dots already in flight. Callers supply a monotonic clock, not wall time.
public struct MapParticleRoute: Equatable {
    public enum Style { case upload, download, proxy, direct }
    public let id: String
    public let from: GlobePlace
    public let to: GlobePlace
    public let style: Style
    public let expiresAt: Double
    public init(id: String, from: GlobePlace, to: GlobePlace, style: Style, expiresAt: Double = .infinity) {
        self.id = id; self.from = from; self.to = to; self.style = style; self.expiresAt = expiresAt
    }
}

public struct MapParticle {
    public let route: MapParticleRoute
    public let born: Double
    public static let lifetime = 3.6
    public func progress(at now: Double) -> Double { min(1, max(0, (now - born) / Self.lifetime)) }
    public func opacity(at now: Double) -> Double {
        let t = progress(at: now)
        func smooth(_ x: Double) -> Double { let v = min(1, max(0, x)); return v * v * (3 - 2 * v) }
        return smooth(t / 0.12) * smooth((1 - t) / 0.18)
    }
}

public struct MapParticles {
    private struct Emitter { var route: MapParticleRoute; var next: Double }
    private var emitters: [String: Emitter] = [:]
    public private(set) var particles: [MapParticle] = []
    public var isIdle: Bool { emitters.isEmpty && particles.isEmpty }
    public init() {}
    public mutating func update(routes: [MapParticleRoute], now: Double) {
        let usable = routes.prefix(10).filter { $0.expiresAt > now }
        let ids = Set(usable.map(\.id))
        emitters = emitters.filter { ids.contains($0.key) }
        for route in usable {
            // Keep cadence through rate updates and DNS changes. In-flight dots
            // retain the original endpoint even if a node resolves elsewhere.
            let next = emitters[route.id]?.next ?? now
            emitters[route.id] = Emitter(route: route, next: next)
        }
    }
    public mutating func advance(now: Double) {
        particles.removeAll { now - $0.born >= MapParticle.lifetime }
        emitters = emitters.filter { $0.value.route.expiresAt > now }
        for id in emitters.keys.sorted() {
            guard var emitter = emitters[id], now >= emitter.next else { continue }
            if particles.count < 64 { particles.append(MapParticle(route: emitter.route, born: now)) }
            // No catch-up bursts after a suspended/occluded window resumes.
            emitter.next = now + 1.15
            emitters[id] = emitter
        }
    }
    public mutating func suspend(now: Double) {
        particles.removeAll(keepingCapacity: true)
        for id in Array(emitters.keys) { emitters[id]?.next = now }
    }
}
