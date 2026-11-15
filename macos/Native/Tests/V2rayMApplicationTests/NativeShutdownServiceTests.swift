import XCTest
import V2rayMDomain
@testable import V2rayMApplication

@MainActor private final class ShutdownRuntime: NativeShutdownRuntime {
    var calls: [String] = []
    var requiresTunnelStop = true
    var evidence = TunnelStopEvidence(ownedProcessIDs: [], runtimeState: "stopped")
    var failAt: String?
    var holdDrain = false
    var drain: CheckedContinuation<Void, Never>?
    enum Failure: Error { case injected }
    func step(_ value: String) throws { calls.append(value); if failAt == value { throw Failure.injected } }
    func quiesce() { calls.append("quiesce") }
    func drainPendingWork() async {
        calls.append("drain")
        if holdDrain { await withCheckedContinuation { drain = $0 } }
    }
    func restoreSystemProxy() throws { try step("proxy") }
    func stopTunnel() throws -> TunnelStopEvidence { try step("tun"); return evidence }
    func stopOwnedBackend() throws { try step("backend") }
}

@MainActor final class NativeShutdownServiceTests: XCTestCase {
    func testFailedProxyRestorationNeverStopsTunnelOrBackend() async {
        let runtime = ShutdownRuntime(); runtime.failAt = "proxy"
        do { _ = try await NativeShutdownService().shutdown(runtime); XCTFail("Expected failure") }
        catch { XCTAssertTrue(error is ShutdownRuntime.Failure) }
        XCTAssertEqual(runtime.calls, ["quiesce", "drain", "proxy"])
    }
    func testTunnelNeedsBothStoppedStateAndNoOwnedProcesses() async throws {
        for evidence in [TunnelStopEvidence(ownedProcessIDs: [42], runtimeState: "stopped"),
                         TunnelStopEvidence(ownedProcessIDs: [], runtimeState: "faulted")] {
            let runtime = ShutdownRuntime(); runtime.evidence = evidence
            let result = try await NativeShutdownService().shutdown(runtime)
            XCTAssertEqual(result, .tunnelStopUnconfirmed)
            XCTAssertEqual(runtime.calls, ["quiesce", "drain", "proxy", "tun"])
        }
    }
    func testConfirmedStopReleasesOwnedBackendLast() async throws {
        let runtime = ShutdownRuntime()
        let result = try await NativeShutdownService().shutdown(runtime)
        XCTAssertEqual(result, .stopped)
        XCTAssertEqual(runtime.calls, ["quiesce", "drain", "proxy", "tun", "backend"])
    }
    func testNoNetworkCleanupStartsBeforeOutstandingCommandDrains() async throws {
        let runtime = ShutdownRuntime(); runtime.holdDrain = true; runtime.requiresTunnelStop = false
        let exit = Task { try await NativeShutdownService().shutdown(runtime) }
        for _ in 0..<1000 {
            if runtime.drain != nil { break }
            await Task.yield()
        }
        XCTAssertNotNil(runtime.drain)
        XCTAssertEqual(runtime.calls, ["quiesce", "drain"])
        runtime.drain?.resume(); runtime.drain = nil
        let result = try await exit.value
        XCTAssertEqual(result, .stopped)
        XCTAssertEqual(runtime.calls, ["quiesce", "drain", "proxy", "backend"])
    }
}
