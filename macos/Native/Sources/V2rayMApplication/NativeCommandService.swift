import V2rayMDomain

@MainActor public protocol NativeCommandRuntime: AnyObject {
    func observe() async -> Bool
    func synchronizeProxyPort() async throws
    func reconcileFailure(_ error: Error) async
    func disposition(_ error: Error, finishingDisconnect: Bool) -> CommandFailureDisposition
    func scheduleRetry(_ disposition: CommandFailureDisposition, error: Error)
    var shouldDetachSystemProxy: Bool { get }
    func restoreSystemProxy() async throws
}

public enum NativeCommandResult { case completed, deferred }

@MainActor public struct NativeCommandService {
    public init() {}
    public func execute(_ action: @MainActor () async throws -> Void, runtime: any NativeCommandRuntime,
                        finishingDisconnect: Bool = false, allowDeferredRetry: Bool = true) async throws -> NativeCommandResult {
        do {
            try await action()
            if await runtime.observe() { try await runtime.synchronizeProxyPort() }
            return .completed
        } catch {
            await runtime.reconcileFailure(error)
            let disposition = allowDeferredRetry ? runtime.disposition(error, finishingDisconnect: finishingDisconnect) : .report
            if disposition != .report {
                runtime.scheduleRetry(disposition, error: error)
                return .deferred
            }
            if await runtime.observe(), runtime.shouldDetachSystemProxy {
                // Cleanup failure cannot replace the original command failure.
                try? await runtime.restoreSystemProxy()
            }
            throw error
        }
    }
}
