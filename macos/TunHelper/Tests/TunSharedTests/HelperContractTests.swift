import XCTest
@testable import TunShared

final class HelperContractTests: XCTestCase {
    private var fixtures: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("contracts/tun-helper")
    }
    func testCSharpStartFixtureDecodesAndRoundTrips() throws {
        let input = try Data(contentsOf: fixtures.appendingPathComponent("start-request.json"))
        let request = try JSONDecoder().decode(HelperRequest.self, from: input)
        XCTAssertEqual(request.action, "start"); XCTAssertEqual(request.core, "xray")
        XCTAssertEqual(request.resources?["certificate.pem"], Data("cert".utf8))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: input) as? NSDictionary)
    }
    func testSwiftResponseUsesTheSharedWireFixture() throws {
        let input = try Data(contentsOf: fixtures.appendingPathComponent("running-response.json"))
        var response = HelperResponse(state: "running")
        response.pid = 42; response.executablePath = "/private/var/run/fixture/xray"
        response.logs = ["fixture started"]; response.updateToken = "fixture-token"
        response.coreVersion = "Xray 26.10.21 fixture"; response.verifiedSHA256 = "fixture-digest"
        response.previousVersionPresent = true
        XCTAssertEqual(try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: input) as? NSDictionary)
        XCTAssertEqual(response.protocolVersion, HelperContract.version)
        XCTAssertFalse(HelperContract.resourceExtensions.contains("srs"))
    }
}
