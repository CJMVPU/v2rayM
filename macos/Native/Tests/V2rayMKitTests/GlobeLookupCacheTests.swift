import Foundation
import XCTest
@testable import V2rayMKit

private final class LookupClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: Double) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(seconds) }
}
private actor LookupFixture {
    var calls = 0
    func lookup(_ host: String) -> GlobePlace? {
        calls += 1
        return calls == 1 ? nil : GlobePlace(city: "Location \(calls)", latitude: 1, longitude: 2)
    }
}
final class GlobeLookupCacheTests: XCTestCase {
    func testFailureRetriesThenSuccessfulLocationExpiresForTheSameHost() async {
        let clock = LookupClock(), fixture = LookupFixture()
        let cache = GlobeLookupCache(successTTL: 100, failureTTL: 10, now: { clock.now() }) { await fixture.lookup($0) }
        let first = await cache.resolve("example.com")
        XCTAssertNil(first)
        clock.advance(9)
        let retainedFailure = await cache.resolve("example.com"), count = await fixture.calls
        XCTAssertNil(retainedFailure); XCTAssertEqual(count, 1)
        clock.advance(1)
        let recovered = await cache.resolve("example.com")
        XCTAssertEqual(recovered?.city, "Location 2")
        clock.advance(99)
        let cached = await cache.resolve("example.com")
        XCTAssertEqual(cached, recovered)
        clock.advance(1)
        let refreshed = await cache.resolve("example.com"), finalCount = await fixture.calls
        XCTAssertEqual(refreshed?.city, "Location 3"); XCTAssertEqual(finalCount, 3)
    }
    func testCapacityEvictsOldestWithoutClearingOtherCachedHosts() async {
        let clock = LookupClock(), fixture = LookupFixture()
        let cache = GlobeLookupCache(capacity: 2, now: { clock.now() }) { await fixture.lookup($0) }
        _ = await cache.resolve("first.example"); clock.advance(1)
        _ = await cache.resolve("second.example"); clock.advance(1)
        _ = await cache.resolve("third.example")
        _ = await cache.resolve("second.example")
        let retainedCount = await fixture.calls
        XCTAssertEqual(retainedCount, 3)
        _ = await cache.resolve("first.example")
        let reloadedCount = await fixture.calls
        XCTAssertEqual(reloadedCount, 4)
    }
}
