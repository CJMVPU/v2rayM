import XCTest
@testable import V2rayMKit

final class MapParticlesTests: XCTestCase {
    private func route(_ id: String = "up", expiry: Double = .infinity) -> MapParticleRoute {
        .init(id: id, from: .init(city: "上海", latitude: 31, longitude: 121),
              to: .init(city: "洛杉矶", latitude: 34, longitude: -118), style: .upload, expiresAt: expiry)
    }
    func testNewDotStartsAtOriginAndFadesIn() throws {
        var model = MapParticles()
        model.update(routes: [route()], now: 100)
        model.advance(now: 100)
        let dot = try XCTUnwrap(model.particles.first)
        XCTAssertEqual(dot.progress(at: 100), 0)
        XCTAssertEqual(dot.opacity(at: 100), 0)
        XCTAssertGreaterThan(dot.opacity(at: 100.3), 0)
        XCTAssertLessThan(dot.opacity(at: 100.3), 1)
        XCTAssertEqual(dot.opacity(at: 101), 1)
    }
    func testStoppingOrEvictingRouteKeepsInFlightDotUntilFadeOut() throws {
        var model = MapParticles()
        model.update(routes: [route()], now: 0); model.advance(now: 0)
        model.update(routes: [], now: 1); model.advance(now: 1)
        XCTAssertFalse(model.isIdle)
        let dot = try XCTUnwrap(model.particles.first)
        XCTAssertEqual(dot.born, 0)
        XCTAssertGreaterThan(dot.opacity(at: 3.5), 0)
        XCTAssertLessThan(dot.opacity(at: 3.5), 0.1)
        model.advance(now: 3.6)
        XCTAssertTrue(model.isIdle)
    }
    func testExpiryStopsEmissionButDoesNotCutOffParticles() {
        var model = MapParticles()
        model.update(routes: [route(expiry: 1)], now: 0); model.advance(now: 0)
        model.advance(now: 1.1)
        XCTAssertEqual(model.particles.count, 1)
        model.advance(now: 4)
        XCTAssertTrue(model.isIdle)
    }
    func testRepeatedStatusUpdatesDoNotRestartCadence() {
        var model = MapParticles()
        model.update(routes: [route()], now: 0); model.advance(now: 0)
        for i in 1...10 {
            let time = Double(i) / 10
            model.update(routes: [route()], now: time); model.advance(now: time)
        }
        XCTAssertEqual(model.particles.count, 1)
        model.advance(now: 1.2)
        XCTAssertEqual(model.particles.count, 2)
    }
    func testSuspendResumesAtOriginWithoutCatchUpBurst() throws {
        var model = MapParticles()
        model.update(routes: [route()], now: 0); model.advance(now: 0)
        model.suspend(now: 1); model.advance(now: 500)
        XCTAssertEqual(model.particles.count, 1)
        XCTAssertEqual(try XCTUnwrap(model.particles.first).born, 500)
    }
    func testEndpointChangeDoesNotTeleportExistingDot() throws {
        var model = MapParticles()
        model.update(routes: [route()], now: 0); model.advance(now: 0)
        let changed = MapParticleRoute(id: "up", from: route().from, to: .init(city: "东京", latitude: 35, longitude: 139), style: .upload)
        model.update(routes: [changed], now: 0.5); model.advance(now: 1.2)
        XCTAssertEqual(model.particles.first?.route.to.city, "洛杉矶")
        XCTAssertEqual(model.particles.last?.route.to.city, "东京")
    }
}
