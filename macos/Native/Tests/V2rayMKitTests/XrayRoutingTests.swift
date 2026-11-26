import XCTest
@testable import V2rayMKit

final class XrayRoutingTests: XCTestCase {
    func testRuleOrderAndDNSSeparation() throws {
        let rules = """
        [{"Enabled":false,"Port":"42"},{"RuleType":"DNS","Port":"53"},
         {"Domain":["#comment","regexp:a<COMMA>b"],"Ip":["127.0.0.1"],"Process":["self/"],"Port":"123","OutboundTag":"edge"},
         {"Network":"tcp","OutboundTag":"direct"}]
        """
        let profile = SettingsValue.object(["RuleSet": .string(rules), "DomainStrategy": .string("AsIs")])
        let result = try XrayRouting.generate(config: .null, profile: profile, tunProcesses: ["xray/", "self/"],
                                              balancers: ["test-balancer"]) { name, _ in
            XCTAssertEqual(name, "edge")
            return "test"
        }
        let built = result["rules"].items
        XCTAssertEqual(result["domainStrategy"], .string("AsIs"))
        XCTAssertEqual(built.count, 8)
        XCTAssertEqual(built[2]["outboundTag"], .string("dns"))
        XCTAssertEqual(built[2]["port"], .string("53"))
        XCTAssertEqual(built[2]["process"], .null)
        XCTAssertEqual(built[3]["outboundTag"], .string("direct"))
        for rule in built.prefix(4) { XCTAssertEqual(rule["inboundTag"], .array([.string("tun")])) }
        XCTAssertEqual(built[4]["domain"], .array([.string("regexp:a,b")]))
        XCTAssertEqual(built[4]["process"], .null)
        XCTAssertEqual(built[5]["ip"], .array([.string("127.0.0.1")]))
        XCTAssertEqual(built[6]["process"], .array([.string("self/")]))
        for rule in built[4...6] {
            XCTAssertEqual(rule["balancerTag"], .string("test-balancer"))
            XCTAssertEqual(rule["port"], .string("123"))
        }
        XCTAssertEqual(built[7]["outboundTag"], .string("direct"))
    }
}
