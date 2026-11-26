import XCTest
@testable import V2rayMKit

final class TunnelRouteSetTests: XCTestCase {
    func testComplementUsesNetworkBitsAndHandlesNestedOrOverlappingExclusions() throws {
        let result = try TunnelRouteSet.included(excluding: ["128.0.0.42/1", "192.0.0.1/2", "8000::/1", "4000::/2"], ipv6: true)
        XCTAssertEqual(result, ["0.0.0.0/1", "::/2"])
        XCTAssertEqual(try TunnelRouteSet.included(excluding: ["0.0.0.0/0", "::/0"], ipv6: true), [])
        XCTAssertEqual(try TunnelRouteSet.included(excluding: ["::/0"], ipv6: false), ["0.0.0.0/0"])
        for invalid in ["::/129", "10.0.0.1", "bad/32", "192.1.1.1/-1",
                        "192.0.2.7\0obsolete/24", "fd00::1\0obsolete/64"] {
            XCTAssertThrowsError(try TunnelRouteSet.included(excluding: [invalid], ipv6: true))
        }
    }

    func testGlobalIPv6RouteWithoutAssigningIPv6Gateway() throws {
        let config = try SettingsValue.parse(#"{"EnableIPv6Address":false,"Mtu":65535}"#)
        let inbound = try XrayInbound.tunnel(settings: config, interface: "utun42", bindInterface: "en0",
                                             hasGlobalIPv6: true, sniffing: .object(["enabled": .bool(true)]))
        XCTAssertEqual(inbound["settings"]["gateway"].items.count, 1)
        XCTAssertEqual(inbound["settings"]["autoSystemRoutingTable"].items.map(\.text), ["0.0.0.0/0", "::/0"])
        XCTAssertEqual(inbound["sniffing"]["routeOnly"], .bool(true))
    }
}
