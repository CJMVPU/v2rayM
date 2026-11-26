import XCTest
@testable import V2rayMKit

final class XrayConfigurationTests: XCTestCase {
    func testGeneratedClientMatchesReviewedReference() throws {
        func fixture(_ name: String) throws -> SettingsValue {
            let file = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
            return try JSONDecoder().decode(SettingsValue.self, from: Data(contentsOf: file))
        }
        let sample = try fixture("client-reference")
        let node = sample["node"]
        let source = XrayClientConfiguration(settings: sample["settings"], route: try fixture("dns-routing-reference")["route"],
                                             customDNS: .null, template: .null, systemHosts: [:], nodes: [node])
        let result = try source.generate(for: node, metricsPort: nil, logDirectory: FileManager.default.temporaryDirectory, at: Date())
        XCTAssertEqual(result, sample["expected"])

        var settings = sample["settings"]
        settings["GuiItem"]["EnableStatistics"] = .bool(true)
        let configured = XrayClientConfiguration(settings: settings, route: source.route,
            customDNS: .null, template: .null, systemHosts: [:], nodes: [node])
        let directory = FileManager.default.temporaryDirectory
        let internalStats = try configured.generate(for: node, metricsPort: nil, logDirectory: directory, at: Date())
        XCTAssertEqual(internalStats["stats"], .object([:]))
        XCTAssertTrue(internalStats["policy"]["system"]["statsOutboundUplink"].flag)
        XCTAssertTrue(internalStats["policy"]["system"]["statsOutboundDownlink"].flag)
        XCTAssertEqual(internalStats["metrics"], .null)
        let exported = try configured.generate(for: node, metricsPort: 10456, logDirectory: directory, at: Date())
        XCTAssertEqual(exported["metrics"]["listen"].text, "127.0.0.1:10456")
        let template = try SettingsValue.parse(#"{"metrics":{"listen":"127.0.0.1:13579"},"stats":{}}"#)
        let custom = XrayClientConfiguration(settings: settings, route: source.route, customDNS: .null,
            template: .object(["Enabled": .bool(true), "Config": .string(try template.json())]), systemHosts: [:], nodes: [node])
        let templated = try custom.generate(for: node, metricsPort: nil, logDirectory: directory, at: Date())
        XCTAssertEqual(templated["metrics"], template["metrics"])
    }
}
