import Darwin
import XCTest
import SystemConfiguration
@testable import TunShared
@testable import TunNetworkControl

final class NetworkLeaseTests: XCTestCase {
    private final class DNS: ManagedTunNetwork {
        var settings: TunDNSSettings?
        func install(_ settings: TunDNSSettings?) throws { self.settings = settings }
        func restore() throws { settings = nil }
    }

    func testFailedActivationAndRetryRemoveOnlySuccessfullyAddedRoutes() throws {
        let plan = TunnelNetworkPlan(token: UUID(), mtu: 1500, gateway: "172.18.0.1/30",
                                     routes: ["10.0.0.0/8", "192.0.2.0/24", "2001:db8::/32"])
        let (gateway, routes) = try plan.validated()
        var changes = [String](), failRemoval = true
        let dns = DNS()
        let lease = NetworkLease(handle: FileHandle.nullDevice, name: "utun900", gateway: gateway, desired: routes, dns: dns) {
            return { add, route in
                let address = route.address
                changes.append((add ? "+" : "-") + address)
                if add && address == "2001:db8::" { return EEXIST }
                if !add && address == "192.0.2.0" && failRemoval { return EBUSY }
                return 0
            }
        }
        XCTAssertThrowsError(try lease.activate { false })
        XCTAssertNil(dns.settings)
        XCTAssertThrowsError(try lease.restore())
        failRemoval = false
        try lease.restore()
        XCTAssertEqual(changes, ["+10.0.0.0", "+192.0.2.0", "+2001:db8::", "-192.0.2.0", "-10.0.0.0", "-192.0.2.0"])
        XCTAssertFalse(lease.active)
    }

    func testSessionHoldsDNSUntilStopAndCancellationLeavesRestorableRoutes() throws {
        let plan = TunnelNetworkPlan(token: UUID(), mtu: 1280, gateway: "172.18.0.1/30", routes: ["10.0.0.0/8", "::/1"])
        let (gateway, routes) = try plan.validated()
        let dns = DNS()
        var owned = Set<String>()
        let lease = NetworkLease(handle: FileHandle.nullDevice, name: "utun900", gateway: gateway, desired: routes, dns: dns) {
            return { add, route in
                let address = route.address
                if add { owned.insert(address) } else { owned.remove(address) }
                return 0
            }
        }
        XCTAssertThrowsError(try lease.activate { !owned.isEmpty })
        try lease.restore()
        XCTAssertTrue(owned.isEmpty)
        try lease.activate { false }
        XCTAssertEqual(dns.settings?.interface, "utun900")
        XCTAssertEqual(dns.settings?.resolver, "172.18.0.1")
        XCTAssertTrue(lease.active)
        try lease.restore()
        XCTAssertNil(dns.settings)
        XCTAssertTrue(owned.isEmpty)
    }

    func testOneWriterPerBatchAndCleanupAfterWriterFailure() throws {
        let plan = TunnelNetworkPlan(token: UUID(), mtu: 1500, gateway: "172.18.0.1/30",
                                     routes: (1...128).map { "2001:db8::" + String($0, radix: 16) + "/128" })
        let (gateway, routes) = try plan.validated()
        let dns = DNS()
        var opens = 0, adds = 0, deletes = 0
        let lease = NetworkLease(handle: .nullDevice, name: "utun900", gateway: gateway, desired: routes, dns: dns) {
            opens += 1
            if opens == 2 { throw HelperFailure("simulated_socket_error") }
            return { add, _ in
                if add { adds += 1 } else { deletes += 1 }
                return 0
            }
        }
        try lease.activate { false }
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(adds, 128)
        XCTAssertThrowsError(try lease.restore())
        XCTAssertNil(dns.settings)
        XCTAssertEqual(deletes, 0)
        try lease.restore()
        XCTAssertEqual(opens, 3)
        XCTAssertEqual(deletes, 128)
        try lease.restore()
        XCTAssertEqual(opens, 3)
    }

    func testEquivalentCIDRsInstallAndRemoveOncePerKernelPrefix() throws {
        let plan = TunnelNetworkPlan(token: UUID(), mtu: 1500, gateway: "172.18.0.1/30", routes: [
            "192.0.2.9/25", "192.0.2.1/25", "192.0.2.129/25",
            "2001:0db8::1/33", "2001:db8:7fff::1/33", "2001:db8:ffff::1/33"
        ])
        let (gateway, routes) = try plan.validated()
        XCTAssertEqual(routes.map(\.address), ["192.0.2.0", "192.0.2.128", "2001:db8::", "2001:db8:8000::"])
        var installed = Set<TunnelNetworkPlan.Prefix>()
        let lease = NetworkLease(handle: .nullDevice, name: "utun900", gateway: gateway, desired: routes, dns: DNS()) {
            { add, route in
                if add { return installed.insert(route).inserted ? 0 : EEXIST }
                return installed.remove(route) == nil ? ESRCH : 0
            }
        }
        try lease.activate { false }
        XCTAssertEqual(installed.count, 4)
        try lease.restore()
        XCTAssertTrue(installed.isEmpty)
    }

    func testIPv4PreflightRequiresDeviceSupportedAdjacentAddress() throws {
        func validate(_ address: String) throws {
            _ = try TunnelNetworkPlan(token: UUID(), mtu: 1500, gateway: address, routes: []).validated()
        }
        for address in ["0.0.0.0/8", "127.0.0.1/8", "224.0.0.1/24", "172.18.0.3/30", "172.18.0.1/31"] {
            XCTAssertThrowsError(try validate(address), address)
        }
        for address in ["172.18.0.1/30", "10.0.0.0/31", "192.0.2.254/23"] {
            XCTAssertNoThrow(try validate(address), address)
        }
    }

    func testDNSCleanupRetriesConfigdErrorsUntilRemovedOrExplicitlyMissing() throws {
        final class ControlledDNS: ManagedTunNetwork {
            var status = kSCStatusFailed
            var owned = false
            func install(_ settings: TunDNSSettings?) throws { owned = true }
            func restore() throws {
                try TemporaryTunDNS.removeOwnedResolver(remove: { self.status == kSCStatusOK }, status: { Int32(self.status) })
                owned = false
            }
        }
        let gateway = try TunnelNetworkPlan.Prefix("172.18.0.1/30")
        for terminal in [kSCStatusNoKey, kSCStatusOK] {
            let dns = ControlledDNS()
            let lease = NetworkLease(handle: .nullDevice, name: "unused", gateway: gateway, desired: [], dns: dns) {
                { _, _ in 0 }
            }
            try lease.activate { false }
            for status in [kSCStatusFailed, kSCStatusNoStoreSession, kSCStatusAccessError] {
                dns.status = status
                XCTAssertThrowsError(try lease.restore())
                XCTAssertTrue(dns.owned)
                XCTAssertTrue(lease.active)
            }
            dns.status = terminal
            try lease.restore()
            XCTAssertFalse(dns.owned)
            XCTAssertFalse(lease.active)
        }
    }

    func testDisconnectDuringDNSInstallationNeverAcknowledgesAnActiveLease() throws {
        let dns = DNS()
        let gateway = try TunnelNetworkPlan.Prefix("172.18.0.1/30")
        var routeInstalled = false
        let lease = NetworkLease(handle: .nullDevice, name: "unused", gateway: gateway,
            desired: [try .init("192.0.2.0/24")], dns: dns) {
            { add, _ in routeInstalled = add; return 0 }
        }
        XCTAssertThrowsError(try lease.activate { dns.settings != nil })
        XCTAssertFalse(lease.active)
        try lease.restore()
        XCTAssertFalse(routeInstalled)
        XCTAssertNil(dns.settings)
    }

    func testIPv6UsesAdjacentLocalAddressWithinConfiguredPrefix() throws {
        func local(_ raw: String?) throws -> TunnelNetworkPlan.Prefix? {
            try TunnelNetworkPlan(token: UUID(), mtu: 1500, gateway: "172.18.0.1/30", ipv6Gateway: raw, routes: []).interfaceConfiguration().localIPv6
        }
        XCTAssertNil(try local(nil))
        XCTAssertEqual(try local("fd12:3456::1/126"), try .init("fd12:3456::2/126"))
        XCTAssertEqual(try local("2001:db8::ff/64"), try .init("2001:db8::100/64"))
        XCTAssertEqual(try local("fd12::2/127"), try .init("fd12::3/127"))
        for invalid in ["fd12::3/126", "fd12::1/128", "192.0.2.1/30", "::/64", "::1/64", "ff02::1/64"] {
            XCTAssertThrowsError(try local(invalid), invalid)
        }
    }
}
