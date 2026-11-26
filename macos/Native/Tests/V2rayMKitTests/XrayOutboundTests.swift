import Foundation
import XCTest
@testable import V2rayMKit

final class XrayOutboundTests: XCTestCase {
    func testMatchesIsolatedCSharpExport() throws {
        try compare("outbound-reference", expectedCount: 3)
        try compare("extended-outbounds", expectedCount: 6)
        try compare("transport-reference", expectedCount: 3)
    }

    func testWireGuardMultilineAddressDNSAndReservedRetainTheirBoundaries() throws {
        let options: SettingsValue = .object(["WgInterfaceAddress": .string("172.16.0.2/32\nfd00::1/128"),
            "WgReserved": .string("7, 12\r\n45"), "WgDns": .string("1.1.1.1,\n 2606:4700:4700::1111")])
        let node: SettingsValue = .object(["address": .string("127.0.0.1"), "port": .number(51820),
            "configType": .string("wireGuard"), "protoExtra": .string(try options.json())])
        let settings = try XrayOutbound(node: node, config: .null).build()["settings"]
        XCTAssertEqual(settings["address"].items.map(\.text), ["172.16.0.2/32", "fd00::1/128"])
        XCTAssertEqual(settings["reserved"].items.map(\.text), ["7", "12", "45"])
        XCTAssertEqual(settings["remoteDNS"].items.map(\.text), ["1.1.1.1", "2606:4700:4700::1111"])
    }

    func testCommaSeparatedTransportValuesIgnoreEmptyAlternatives() throws {
        let transport: SettingsValue = .object(["Host": .string(", a.invalid, b.invalid, "), "RawHeaderType": .string("http"),
            "Path": .string("/one, /two, ")])
        let node: SettingsValue = .object(["address": .string("127.0.0.1"), "port": .number(443), "configType": .string("vless"),
            "password": .string("fixture-id"), "transportExtra": .string(try transport.json()), "streamSecurity": .string("tls"), "alpn": .string("h2, ,http/1.1")])
        let stream = try XrayOutbound(node: node, config: .null).build()["streamSettings"]
        let request = stream["rawSettings"]["header"]["request"]
        XCTAssertEqual(request["path"].items.map(\.text), ["/one", "/two"])
        XCTAssertEqual(request["headers"]["Host"].items.map(\.text), ["a.invalid", "b.invalid"])
        XCTAssertEqual(stream["tlsSettings"]["serverName"].text, "a.invalid")
        XCTAssertEqual(stream["tlsSettings"]["alpn"].items.map(\.text), ["h2","http/1.1"])
    }

    private func compare(_ resource: String, expectedCount: Int) throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: resource, withExtension: "json", subdirectory: "Fixtures"))
        let samples = try JSONDecoder().decode([SettingsValue].self, from: Data(contentsOf: file))
        XCTAssertEqual(samples.count, expectedCount)
        for sample in samples {
            let generator = try XrayOutbound(node: sample["node"], config: sample["settings"])
            XCTAssertEqual(try generator.build(), sample["expected"], sample["node"]["remarks"].text)
        }
    }
}
