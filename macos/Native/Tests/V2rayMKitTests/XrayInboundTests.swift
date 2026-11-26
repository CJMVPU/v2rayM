import Darwin
import XCTest
@testable import V2rayMKit

final class XrayInboundTests: XCTestCase {
    func testHighestBasePortMatchesActualListeners() throws {
        for (second, lan, maximum) in [(false,false,65535), (true,false,65534), (false,true,65533), (true,true,65533)] {
            XCTAssertEqual(XrayInbound.maximumBasePort(secondLocal: second, separateLAN: lan), maximum)
            let input: SettingsValue = .object(["localPort": .number(Double(maximum)), "secondLocalPortEnabled": .bool(second),
                "allowLANConn": .bool(lan), "newPort4LAN": .bool(lan)])
            let defaults: SettingsValue = .object(["Inbound": .array([.object([:])])])
            _ = try NativeSettings.applying(input, section: "inbound", to: defaults, options: .null)
            var overflow = input
            overflow["localPort"] = .number(Double(maximum + 1))
            XCTAssertThrowsError(try NativeSettings.applying(overflow, section: "inbound", to: defaults, options: .null))
        }
    }

    func testSocksUDPAssociationUsesEphemeralPortAndOnlyTCPIsPreflighted() throws {
        let udp = socket(AF_INET, SOCK_DGRAM, 0)
        guard udp >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(udp) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        func bindSocket(_ fd: Int32) -> Int32 {
            withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
            }
        }

        // Reserve TCP first: a port chosen by the UDP allocator can already be in use by TCP.
        func reserveBothProtocols() throws -> Int32 {
            for _ in 0..<16 {
                let tcp = socket(AF_INET, SOCK_STREAM, 0)
                guard tcp >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                var reserved = false
                defer { if !reserved { close(tcp) } }
                address.sin_port = 0
                guard bindSocket(tcp) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                let result = withUnsafeMutablePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(tcp, $0, &length) }
                }
                guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                if bindSocket(udp) == 0 {
                    reserved = true
                    return tcp
                }
                guard errno == EADDRINUSE else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            }
            throw POSIXError(.EADDRINUSE)
        }

        var entry = try SettingsValue.parse("""
        {"protocol":"mixed","listen":"127.0.0.1","settings":{"udp":false}}
        """)
        let occupiedTCP = try reserveBothProtocols()
        entry["port"] = .number(Double(UInt16(bigEndian: address.sin_port)))
        XCTAssertThrowsError(try XrayInbound.checkNewListeners(before: [], after: [entry])) {
            XCTAssertEqual(($0 as? ClientFailure)?.code, "proxy_port_in_use")
        }
        close(occupiedTCP)
        XCTAssertNoThrow(try XrayInbound.checkNewListeners(before: [], after: [entry]))
        let tcpOnly = entry
        entry["settings"]["udp"] = .bool(true)
        XCTAssertNoThrow(try XrayInbound.checkNewListeners(before: [tcpOnly], after: [entry]))
        XCTAssertNoThrow(try XrayInbound.checkNewListeners(before: [], after: [entry]))
    }

    func testSystemProxySeparatesProtocolAndAddressAndSkipsIncompatibleListeners() throws {
        let entries = try SettingsValue.parse("""
        [{"protocol":"mixed","listen":"::1","port":8100,"settings":{"auth":"password"}},
         {"protocol":"http","port":8101,"streamSettings":{"security":"tls"}},
         {"protocol":"socks","listen":"::","port":8102},
         {"protocol":"http","listen":"127.0.0.1","port":8103}]
        """).items
        let endpoints = try XCTUnwrap(XrayInbound.proxyEndpoints(entries))
        XCTAssertEqual(endpoints.socks, ProxyEndpoint(host: "::1", port: 8102))
        XCTAssertEqual(endpoints.http, ProxyEndpoint(host: "127.0.0.1", port: 8103))
        XCTAssertNil(XrayInbound.proxyEndpoints(Array(entries.prefix(2))))
        XCTAssertNil(XrayInbound.proxyEndpoints([entries[3]])?.socks)
        XCTAssertEqual(XrayInbound.proxyEndpoints([entries[2]])?.http, endpoints.socks)
        let dictionary = SystemProxyController.connectionProxyDictionary(endpoints)
        XCTAssertEqual(dictionary["SOCKSProxy"] as? String, "::1")
        XCTAssertEqual(dictionary["HTTPSPort"] as? Int, 8103)
    }

    func testCustomHTTPUsesEffectiveAccountsRawHeaderAndFirstUsablePort() throws {
        let auth = try SettingsValue.parse(#"{"protocol":"http","port":8100,"settings":{"users":[{"user":"local","pass":"fixture"}]}}"#)
        let wrapper = try SettingsValue.parse(#"{"protocol":"http","port":8101,"streamSettings":{"rawSettings":{"header":{"type":"http"}}}}"#)
        let multi = try SettingsValue.parse(#"{"protocol":"http","port":"8102-8103,8105"}"#)
        XCTAssertNil(XrayInbound.proxyEndpoints([auth]))
        XCTAssertNil(XrayInbound.proxyEndpoints([wrapper]))
        let masked = try SettingsValue.parse(#"{"protocol":"mixed","port":8106,"streamSettings":{"finalmask":{"tcp":[{"type":"sudoku"}]}}}"#)
        XCTAssertNil(XrayInbound.proxyEndpoints([masked]))
        var segmented = masked
        segmented["streamSettings"]["finalmask"]["tcp"] = .array([.object(["type": .string("fragment")])])
        XCTAssertEqual(XrayInbound.proxyEndpoints([segmented])?.socks?.port, 8106)
        XCTAssertEqual(XrayInbound.proxyEndpoints([multi])?.http?.port, 8102)
        XCTAssertEqual(XrayInbound.proxyEndpoints([auth, wrapper, multi])?.http?.port, 8102)
        var alias = auth
        alias["settings"]["accounts"] = .array([])
        XCTAssertEqual(XrayInbound.proxyEndpoints([alias])?.http?.port, 8100)
        var overridden = wrapper
        overridden["streamSettings"]["tcpSettings"] = overridden["streamSettings"]["rawSettings"]
        overridden["streamSettings"]["rawSettings"] = .object(["header": .object(["type": .string("none")])])
        XCTAssertEqual(XrayInbound.proxyEndpoints([overridden])?.http?.port, 8101)
    }

    func testLANCredentialsStayOnSeparatePortAndFakeDNSLeavesSettingsUntouched() throws {
        let input = try SettingsValue.parse("""
        {"LocalPort":31080,"AllowLANConn":true,"NewPort4LAN":true,"SecondLocalPortEnabled":true,
        "User":"sample","Pass":"test","UdpEnabled":true,"DestOverride":["http","tls"],"RouteOnly":true}
        """)
        let listeners = try XrayInbound.mixed(settings: input, fakeDNS: true, usingTunnel: false, node: .null)
        XCTAssertEqual(listeners.map { $0["listen"].text }, ["127.0.0.1", "127.0.0.1", "0.0.0.0"])
        XCTAssertEqual(listeners.map { $0["port"].text }, ["31080", "31081", "31082"])
        XCTAssertEqual(listeners.map { $0["settings"]["auth"].text }, ["noauth", "noauth", "password"])
        XCTAssertEqual(listeners[2]["settings"]["accounts"].items.first?["user"], .string("sample"))
        XCTAssertTrue(listeners[0]["sniffing"]["destOverride"].items.contains(.string("fakedns")))
        XCTAssertFalse(input["DestOverride"].items.contains(.string("fakedns")))
        var broken = input
        broken["Pass"] = .string("")
        XCTAssertThrowsError(try XrayInbound.mixed(settings: broken, fakeDNS: false, usingTunnel: false, node: .null))
    }
}
