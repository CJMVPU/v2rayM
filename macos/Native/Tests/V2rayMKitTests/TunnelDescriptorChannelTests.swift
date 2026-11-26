import Darwin
import Foundation
import TunShared
import XCTest
@testable import V2rayMKit

/// Anonymous XPC exercises Foundation's real file-descriptor transport without a registered system service.
private final class DescriptorFixture: NSObject, NSXPCListenerDelegate, TunHelperProtocol {
    let reader: FileHandle
    let supportsTunnelDescriptor: Bool?
    private let lock = NSLock()
    private var openReplies: [Data]
    private var receiptTokens: [String] = []
    private var cleanupReplies = [HelperResponse]()
    private var openedPlans = [TunnelNetworkPlan]()
    private var holdStatus: XCTestExpectation?
    private var delayedStatus: ((Data) -> Void)?
    let supportsIPv6: Bool?
    var plans: [TunnelNetworkPlan] { lock.withLock { openedPlans } }

    func holdNextStatus(_ expectation: XCTestExpectation) { lock.withLock { holdStatus = expectation } }
    func releaseStatus() {
        let reply = lock.withLock { defer { delayedStatus = nil }; return delayedStatus }
        reply?((try? JSONEncoder().encode(HelperResponse())) ?? Data())
    }
    func returnReceipts(_ values: [HelperResponse]) { lock.withLock { cleanupReplies = values } }
    var receipts: [String] { lock.withLock { receiptTokens } }

    init(reader: FileHandle, supportsTunnelDescriptor: Bool? = true, supportsIPv6: Bool? = true, openReplies: [Data] = []) {
        self.openReplies = openReplies
        self.supportsIPv6 = supportsIPv6
        self.reader = reader
        self.supportsTunnelDescriptor = supportsTunnelDescriptor
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: TunHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func request(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        var response = HelperResponse()
        response.supportsTunnelDescriptor = supportsTunnelDescriptor
        response.supportsTunnelIPv6Address = supportsIPv6
        let request = try? JSONDecoder().decode(HelperRequest.self, from: data)
        switch request?.action {
        case "status":
            let held = lock.withLock { () -> XCTestExpectation? in
                guard let expectation = holdStatus else { return nil }
                holdStatus = nil
                delayedStatus = reply
                return expectation
            }
            if let held { held.fulfill(); return }
        case "activate-tunnel": response.state = "running"
        case "cleanup-status":
            response = lock.withLock {
                receiptTokens.append(request?.sessionToken ?? "")
                return cleanupReplies.isEmpty ? HelperResponse(code: "session_cleanup_confirmed", state: "stopped") : cleanupReplies.removeFirst()
            }
        default: break
        }
        reply((try? JSONEncoder().encode(response)) ?? Data())
    }

    func openTunnel(_ parameters: Data, withReply reply: @escaping (Data, FileHandle?) -> Void) {
        guard let plan = try? JSONDecoder().decode(TunnelNetworkPlan.self, from: parameters),
              (try? plan.validated()) != nil else { reply(Data(), nil); return }
        lock.withLock { openedPlans.append(plan) }
        if let payload = lock.withLock({ openReplies.isEmpty ? nil : openReplies.removeFirst() }) {
            reply(payload, nil)
            return
        }
        var response = HelperResponse(state: "prepared")
        response.tunnelInterface = "utun900"
        reply((try? JSONEncoder().encode(response)) ?? Data(), reader)
    }
}

final class TunnelDescriptorChannelTests: XCTestCase {
    private func tunnelConfig(ipv6: Bool = false) throws -> SettingsValue {
        let settings: SettingsValue = .object(["EnableIPv6Address": .bool(ipv6), "IPv6Address": .string("fd00:2::1/126")])
        let tun = try XrayInbound.tunnel(settings: settings, interface: "utun900", bindInterface: "", hasGlobalIPv6: true, sniffing: .object([:]))
        return .object(["inbounds": .array([tun])])
    }

    func testReadOnlyKernelRouteSnapshotCanBeDecoded() throws {
        _ = try TunnelConflict.hasRoutedTunnel()
    }

    func testConflictDistinguishesSplitRoutesFromIdleScopedTunnels() {
        let scoped = Int32(RTF_UP | RTF_IFSCOPE)
        let up = Int32(RTF_UP)
        XCTAssertTrue(TunnelConflict.capturesTraffic(interface: "utun3", flags: up, family: AF_INET, address: [10,20,0,0]))
        XCTAssertFalse(TunnelConflict.capturesTraffic(interface: "en0", flags: up, family: AF_INET, address: [10,20,0,0]))
        let global = [UInt8](repeating: 0x20, count: 16)
        XCTAssertTrue(TunnelConflict.capturesTraffic(interface: "utun3", flags: up, family: AF_INET6, address: global))
        XCTAssertFalse(TunnelConflict.capturesTraffic(interface: "utun3", flags: scoped, family: AF_INET6, address: global))
        XCTAssertFalse(TunnelConflict.capturesTraffic(interface: "utun3", flags: up, family: AF_INET6, address: [0xfe,0x80] + Array(repeating: 0, count: 14)))
    }

    func testCancellingStatusLeavesActiveTunnelOwnerAndDescriptorUsable() async throws {
        let pipe = Pipe()
        let fixture = DescriptorFixture(reader: pipe.fileHandleForReading)
        let listener = NSXPCListener.anonymous()
        listener.delegate = fixture; listener.resume()
        defer { listener.invalidate() }
        let session = NativeHelperSession { callback in
            NativeHelperChannel(connection: NSXPCConnection(listenerEndpoint: listener.endpoint), onDisconnect: callback)
        }
        let disconnected = expectation(description: "Actual owner disconnection")
        let token = UUID()
        let (_, fd) = try await session.prepare(config: tunnelConfig(ipv6: true), token: token) { disconnected.fulfill() }
        try await session.activate(token: token)
        XCTAssertEqual(fixture.plans.first?.ipv6Gateway, "fd00:2::1/126")
        let started = expectation(description: "Pending owner status")
        fixture.holdNextStatus(started)
        let read = Task { await session.status() }
        await fulfillment(of: [started], timeout: 2)
        read.cancel()
        _ = await read.value
        fixture.releaseStatus()
        let current = await session.status(fresh: true)
        XCTAssertTrue(current.success)
        try await session.activate(token: token)
        let data = Data("owned".utf8)
        try pipe.fileHandleForWriting.write(contentsOf: data)
        XCTAssertEqual(try fd.read(upToCount: data.count), data)
        try fd.close()
        try await session.stop()
        await fulfillment(of: [disconnected], timeout: 2)
        XCTAssertEqual(fixture.receipts, [token.uuidString])
    }

    func testLegacyDescriptorHelperRejectsOnlyExplicitIPv6BeforeOpening() async throws {
        let fixture = DescriptorFixture(reader: Pipe().fileHandleForReading, supportsIPv6: nil)
        let listener = NSXPCListener.anonymous()
        listener.delegate = fixture; listener.resume()
        defer { listener.invalidate() }
        let session = NativeHelperSession { callback in
            NativeHelperChannel(connection: NSXPCConnection(listenerEndpoint: listener.endpoint), onDisconnect: callback)
        }
        let capability = await session.status(requiresIPv6: true)
        XCTAssertEqual(capability.code, "helper_protocol_mismatch")
        do {
            _ = try await session.prepare(config: tunnelConfig(ipv6: true), token: UUID(), onDisconnect: {})
            XCTFail("An older helper would silently discard the IPv6 address")
        } catch let error as ClientFailure { XCTAssertEqual(error.code, "helper_protocol_mismatch") }
        XCTAssertTrue(fixture.plans.isEmpty)
        let basic = await session.status()
        XCTAssertTrue(basic.success)
        let (_, fd) = try await session.prepare(config: tunnelConfig(), token: UUID(), onDisconnect: {})
        try fd.close()
        XCTAssertEqual(fixture.plans.count, 1)
        XCTAssertNil(fixture.plans.first?.ipv6Gateway)
        try await session.stop()
    }

    func testContradictoryReceiptsRetainOriginalTokenForRetry() async throws {
        let fixture = DescriptorFixture(reader: Pipe().fileHandleForReading)
        var forced = HelperResponse(code: "session_cleanup_confirmed", state: "stopped")
        forced.forced = true
        fixture.returnReceipts([forced, HelperResponse(code: "session_cleanup_confirmed", state: "running")])
        let listener = NSXPCListener.anonymous()
        listener.delegate = fixture; listener.resume()
        defer { listener.invalidate() }
        let session = NativeHelperSession { callback in
            NativeHelperChannel(connection: NSXPCConnection(listenerEndpoint: listener.endpoint), onDisconnect: callback)
        }
        let token = UUID()
        let (_, fd) = try await session.prepare(config: tunnelConfig(), token: token, onDisconnect: {})
        try fd.close()
        for _ in 0..<2 {
            do { try await session.stop(); XCTFail("Contradictory cleanup evidence") }
            catch let error as ClientFailure { XCTAssertEqual(error.code, "tun_stop_unconfirmed") }
        }
        try await session.stop()
        XCTAssertEqual(fixture.receipts, [String](repeating: token.uuidString, count: 3))
    }

    func testTransientObservationRecoversOnlyWithinItsSessionAndIgnoresLateReplies() {
        var observation = TunSessionObservation()
        let first = UUID(), next = UUID()
        let timeout = HelperResponse(success: false, code: "helper_timeout", state: "unavailable")
        let healthy = HelperResponse(success: true, code: "ok", state: "running")
        let poll = observation.begin()
        XCTAssertTrue(observation.record(timeout, for: first, poll: poll))
        XCTAssertEqual(observation.failure(for: first), "helper_timeout")
        XCTAssertNil(observation.failure(for: next))
        XCTAssertNil(observation.failure(for: nil))
        let recovery = observation.begin()
        XCTAssertTrue(observation.record(healthy, for: first, poll: recovery))
        XCTAssertNil(observation.failure(for: first))
        XCTAssertFalse(observation.record(timeout, for: first, poll: poll))
        let nextPoll = observation.begin()
        XCTAssertTrue(observation.record(timeout, for: next, poll: nextPoll))
        XCTAssertFalse(observation.record(healthy, for: first, poll: recovery))
        XCTAssertEqual(observation.failure(for: next), "helper_timeout")
        let ready = observation.begin()
        XCTAssertTrue(observation.record(HelperResponse(success: true, code: "ok", state: "ready"), for: next, poll: ready))
        XCTAssertEqual(observation.failure(for: next), "helper_tunnel_not_running")
    }

    func testRefusedOpenCanRetryAndUncertainOpenRequiresOriginalReceipt() async throws {
        let refusal = HelperResponse(success: false, code: "tunnel_busy")
        var rejected = HelperResponse(success: false, code: "tunnel_plan_invalid")
        rejected.leaseAccepted = false
        var afterAcceptance = HelperResponse(success: false, code: "device_open_failed")
        afterAcceptance.leaseAccepted = true
        let encoder = JSONEncoder()
        let fixture = DescriptorFixture(reader: Pipe().fileHandleForReading, openReplies: [
            try encoder.encode(refusal), try encoder.encode(rejected), Data(), try encoder.encode(afterAcceptance)
        ])
        let listener = NSXPCListener.anonymous()
        listener.delegate = fixture
        listener.resume()
        defer { listener.invalidate() }
        let session = NativeHelperSession { onDisconnect in
            NativeHelperChannel(connection: NSXPCConnection(listenerEndpoint: listener.endpoint), onDisconnect: onDisconnect)
        }
        let config = try SettingsValue.parse(#"{"inbounds":[{"protocol":"tun","settings":{"MTU":1500,"gateway":["172.18.0.1/30"],"autoSystemRoutingTable":["0.0.0.0/0"]}}]}"#)
        var receipts = [String]()
        for (i, code) in ["tunnel_busy", "tunnel_plan_invalid", "", "device_open_failed"].enumerated() {
            let token = UUID()
            do {
                _ = try await session.prepare(config: config, token: token, onDisconnect: {})
                XCTFail("Fixture must reject or interrupt this open")
            } catch {
                if !code.isEmpty { XCTAssertEqual((error as? ClientFailure)?.code, code) }
            }
            try await session.stop()
            if i >= 2 { receipts.append(token.uuidString) }
            XCTAssertEqual(fixture.receipts, receipts)
        }
        let token = UUID()
        let (name, descriptor) = try await session.prepare(config: config, token: token, onDisconnect: {})
        XCTAssertEqual(name, "utun900")
        try descriptor.close()
        try await session.stop()
        XCTAssertEqual(fixture.receipts, receipts + [token.uuidString])
    }

    func testNetworkCleanupRunsEvenIfCoreStopFails() async throws {
        var restored = false
        do {
            try await RuntimeSessionCleanup.run(stopCore: { throw ClientFailure("fixture_core") },
                                                restoreNetwork: { restored = true })
            XCTFail("The core failure must reach the caller")
        } catch let error as ClientFailure { XCTAssertEqual(error.code, "fixture_core") }
        XCTAssertTrue(restored)
        do {
            try await RuntimeSessionCleanup.run(stopCore: { throw ClientFailure("fixture_core", "core detail") },
                                                restoreNetwork: { throw ClientFailure("fixture_helper", "helper detail") })
            XCTFail("Both failures must reach the caller")
        } catch let error as ClientFailure {
            XCTAssertEqual(error.code, "fixture_helper")
            XCTAssertTrue(error.detail?.contains("core detail") == true)
            XCTAssertTrue(error.detail?.contains("helper detail") == true)
        }
    }

    func testLegacyHelperStatusCannotAuthorizeDescriptorTransfer() async throws {
        let fixture = DescriptorFixture(reader: Pipe().fileHandleForReading, supportsTunnelDescriptor: nil)
        let listener = NSXPCListener.anonymous()
        listener.delegate = fixture
        listener.resume()
        defer { listener.invalidate() }
        let channel = NativeHelperChannel(connection: NSXPCConnection(listenerEndpoint: listener.endpoint))
        defer { channel.invalidate() }
        do {
            _ = try await channel.checkCapability()
            XCTFail("A 0.7.7 helper cannot supply a tunnel descriptor")
        } catch let failure as ClientFailure { XCTAssertEqual(failure.code, "helper_protocol_mismatch") }
    }

    func testReceiverOwnsWorkingDescriptorAfterSenderCloses() async throws {
        let pipe = Pipe()
        let fixture = DescriptorFixture(reader: pipe.fileHandleForReading)
        let listener = NSXPCListener.anonymous()
        listener.delegate = fixture
        listener.resume()
        defer { listener.invalidate() }
        let channel = NativeHelperChannel(connection: NSXPCConnection(listenerEndpoint: listener.endpoint))
        defer { channel.invalidate() }
        let capability = try await channel.checkCapability()
        XCTAssertEqual(capability.supportsTunnelDescriptor, true)
        let plan = TunnelNetworkPlan(token: UUID(), mtu: 1500, gateway: "172.18.0.1/30", routes: ["0.0.0.0/0", "::/0"])
        let (name, readEnd) = try await channel.open(plan)
        XCTAssertEqual(name, "utun900")
        try pipe.fileHandleForReading.close()
        let marker = Data(UUID().uuidString.utf8)
        try pipe.fileHandleForWriting.write(contentsOf: marker)
        try pipe.fileHandleForWriting.close()
        XCTAssertEqual(try readEnd.readToEnd(), marker)
        try readEnd.close()
    }

    func testUnprivilegedKernelLookupReturnsLoopbackInterface() throws {
        XCTAssertEqual(try TunnelConflict.routeInterface(to: "127.0.0.1"), "lo0")
    }

    func testProtectedDefaultRoutesAndRejectedInputs() throws {
        let plan = TunnelNetworkPlan(token: UUID(), mtu: 65535, gateway: "172.18.0.1/30", routes: ["0.0.0.0/0", "::/0", "128.0.0.0/1"])
        let (_, routes) = try plan.validated()
        XCTAssertEqual(routes.count, 16)
        XCTAssertEqual(routes.first?.address, "1.0.0.0")
        XCTAssertEqual(routes.last?.address, "8000::")
        XCTAssertFalse(routes.contains { $0.bits == 0 })
        for (mtu, gateway, routes) in [(1279,"172.18.0.1/30",["::/0"]), (1500,"lo0/24",[]), (1500,"172.18.0.1/30",["::/129"])] {
            XCTAssertThrowsError(try TunnelNetworkPlan(token: UUID(), mtu: mtu, gateway: gateway, routes: routes).validated())
        }
    }
}
