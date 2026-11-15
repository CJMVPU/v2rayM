import Foundation
import V2rayMDomain

@MainActor public protocol NativeRecoveryRuntime: AnyObject {
    var recovery: NetworkRecovery { get set }
    var observation: RecoveryObservation { get }
    func refresh(generation: Int, includeOperations: Bool) async throws
    func reconcileMode() async throws
    func checkBeforeConnecting() async throws
    func startOrRestartCore(restart: Bool) async throws
    func synchronizeProxyPort() async throws
}

public enum RecoveryAttemptResult: Equatable { case waiting, completed, proxyRecoveryRequired, coreStartFailed }

/// The host serializes this use case with user mutations and owns task lifetime.
/// Every external suspension is followed by cancellation/generation validation.
@MainActor public struct NetworkRecoveryService {
    public init() {}
    public func attempt(_ runtime: any NativeRecoveryRuntime, now: Date) async throws -> RecoveryAttemptResult {
        var state = runtime.observation
        guard runtime.recovery.canAttempt(awake: state.awake, networkAvailable: state.networkAvailable, now: now) else { return .waiting }
        let generation = runtime.recovery.generation
        func current() throws -> Bool {
            try Task.checkCancellation()
            let observed = runtime.observation
            return generation == runtime.recovery.generation && observed.awake && observed.networkAvailable
        }
        try await runtime.refresh(generation: generation, includeOperations: true)
        guard try current() else { return .waiting }
        state = runtime.observation
        guard state.desiredMode != .off else { runtime.recovery.cancel(); return .waiting }
        guard !state.updating else { return .waiting }
        let action = runtime.recovery.action(desiredMode: state.desiredMode, systemProxyEnabled: state.systemProxyEnabled,
            tunEnabled: state.tunEnabled, coreRunning: state.coreRunning, runtimeState: state.runtimeState, coreStartedAt: state.coreStartedAt)
        let previousCoreStart = state.coreStartedAt
        switch action {
        case .wait: return .waiting
        case .reconcileMode:
            guard !state.proxyNeedsRecovery else { return .proxyRecoveryRequired }
            try await runtime.reconcileMode()
        case .restart:
            try await runtime.checkBeforeConnecting()
            guard try current() else { return .waiting }
            state = runtime.observation
            runtime.recovery.submitted(startedAt: state.coreStartedAt, generation: generation)
            try await runtime.startOrRestartCore(restart: state.runtimeState == "running" || state.runtimeState == "faulted")
            guard try current() else { return .waiting }
            runtime.recovery.restarted(generation: generation)
        case .verify: break
        }
        if action == .restart || action == .reconcileMode {
            guard try current() else { return .waiting }
            try await runtime.refresh(generation: generation, includeOperations: false)
            guard try current() else { return .waiting }
            if action == .reconcileMode, runtime.recovery.needsRestart {
                // Reattaching a system preference may reuse the same Core. A
                // physical network change still requires a new process instance.
                guard let started = runtime.observation.coreStartedAt, started != previousCoreStart else { return .waiting }
                runtime.recovery.restarted(generation: generation)
            }
        }
        guard try current() else { return .waiting }
        guard runtime.observation.modeHealthy else { return .coreStartFailed }
        try await runtime.synchronizeProxyPort()
        guard try current() else { return .waiting }
        runtime.recovery.complete(generation: generation)
        return .completed
    }
}
