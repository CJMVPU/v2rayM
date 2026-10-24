import XCTest
@testable import V2rayMKit

final class GlobeTelemetryTests: XCTestCase {
    private func log(_ message: String) -> LogEntry {
        LogEntry(timestamp: "2026-10-22T12:00:00Z", source: "core", message: message, sequence: 1)
    }
    func testAccessEventsIPv6AndRouting() {
        let domain = GlobeConnection.parse(log("from tcp:127.0.0.1:1234 accepted tcp:example.com:443 [socks >> proxy]"))
        XCTAssertEqual(domain?.host, "example.com"); XCTAssertEqual(domain?.routeTitle, "代理")
        let v6 = GlobeConnection.parse(log("from udp:[::1]:1234 accepted udp:[2606:4700::1111]:443 [tun -> direct]"))
        XCTAssertEqual(v6?.host, "2606:4700::1111"); XCTAssertEqual(v6?.port, 443); XCTAssertEqual(v6?.route, "direct"); XCTAssertEqual(v6?.routeTitle, "直连")
        XCTAssertNil(GlobeConnection.parse(log("failed to connect to example.com:443")))
        XCTAssertNil(GlobeConnection.parse(log("accepted tcp:example.com:443 [proxy]")))
        XCTAssertNil(GlobeConnection.parse(log("from udp:127.0.0.1:1 accepted udp:8.8.8.8:53 [tun -> dns]")))
    }
    func testBurstKeepsLatestUniqueConnectionsInOrder() {
        let entries = (0..<10_000).map { log("from tcp:127.0.0.1:1 accepted tcp:host\($0).example:443 [socks >> proxy]") }
        let recent = GlobeConnection.recent(entries, previous: [], since: .distantPast)
        XCTAssertEqual(recent.count, 24)
        XCTAssertEqual(recent.first?.host, "host9999.example")
        XCTAssertEqual(recent.last?.host, "host9976.example")
        let duplicate = log("from tcp:127.0.0.1:1 accepted tcp:host9990.example:8443 [socks >> proxy]")
        let updated = GlobeConnection.recent([duplicate], previous: recent, since: .distantPast)
        XCTAssertEqual(updated.count, 24); XCTAssertEqual(updated.first?.port, 8443)
        XCTAssertEqual(updated.filter { $0.host == "host9990.example" }.count, 1)
        XCTAssertTrue(GlobeConnection.recent(entries, previous: recent, since: .distantFuture).isEmpty)
    }
    func testPrivateAndFakeIPDoNotGetInventedLocations() {
        for ip in ["127.0.0.1", "10.1.1.1", "198.18.0.1", "172.18.0.2", "192.168.0.1", "::1", "fc00::1", "fe80::1", "::ffff:192.168.1.1"] {
            XCTAssertFalse(GlobeGeoDatabase.isPublic(GlobeGeoDatabase.addressBytes(ip)!))
        }
        XCTAssertTrue(GlobeGeoDatabase.isPublic(GlobeGeoDatabase.addressBytes("1.1.1.1")!))
        XCTAssertNil(GlobeGeoDatabase.addressBytes("example.com"))
    }
    func testRangeBoundariesAndMissingRanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ranges: [UInt8] = [1,1,1,0, 1,1,1,255, 0,0,0,0, 8,8,8,8, 8,8,8,8, 0,0,0,1]
        try Data(ranges).write(to: root.appendingPathComponent("ipv4.bin"))
        try Data().write(to: root.appendingPathComponent("ipv6.bin"))
        try encodePlaces([GlobePlace(city: "A", latitude: 1, longitude: 2), GlobePlace(city: "B", latitude: 3, longitude: 4)])
            .write(to: root.appendingPathComponent("places.bin"))
        let db = try GlobeGeoDatabase(directory: root)
        XCTAssertEqual(db.lookup("1.1.1.0")?.city, "A")
        XCTAssertEqual(db.lookup("1.1.1.255")?.city, "A")
        XCTAssertEqual(db.lookup("8.8.8.8")?.city, "B")
        XCTAssertNil(db.lookup("8.8.8.9")); XCTAssertNil(db.lookup("1.1.0.255"))
    }
}
