import V2rayMDomain

@MainActor public protocol NativeShutdownRuntime: AnyObject {
    func quiesce()
    func drainPendingWork() async
    func restoreSystemProxy() async throws
    var requiresTunnelStop: Bool { get }
    func stopTunnel() async throws -> TunnelStopEvidence
    func stopOwnedBackend() async throws
}

public enum NativeShutdownResult: Equatable { case stopped, tunnelStopUnconfirmed }

@MainActor public struct NativeShutdownService {
    public init() {}
    public func shutdown(_ runtime: any NativeShutdownRuntime) async throws -> NativeShutdownResult {
        runtime.quiesce()
        await runtime.drainPendingWork()
        // Do not stop the listener while system preferences still point to it.
        try await runtime.restoreSystemProxy()
        if runtime.requiresTunnelStop {
            guard try await runtime.stopTunnel().confirmed else { return .tunnelStopUnconfirmed }
        }
        try await runtime.stopOwnedBackend()
        return .stopped
    }
}
