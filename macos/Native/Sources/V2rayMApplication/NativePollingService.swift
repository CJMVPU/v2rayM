import Foundation
import V2rayMDomain

@MainActor public protocol NativePollingRuntime: AnyObject {
    var canObserve: Bool { get }
    var connection: ConnectionCoordinator { get }
    var observation: RecoveryObservation { get }
    var now: Date { get }
    var moduleUpdateActive: Bool { get }
    var pendingDisconnect: Bool { get }
    var disconnectRetryDue: Bool { get }
    var operationsObservationValid: Bool { get }
    func backendIsRunning() async -> Bool
    func setBusy(_ busy: Bool)
    func cancelRecoveryAndObservations()
    func publishBackendExited()
    func restoreSystemProxy() async throws
    func retryDisconnect()
    func attemptRecovery() async throws
    func refresh() async throws
    func freshUpdateActivity() async throws -> Bool
    func synchronizeProxyPort() async throws
    func beginRecovery(restart: Bool)
    func retryRecovery()
    func reportObservationFailure(_ error: Error)
    func reportUpdateWaiting()
    func isTransient(_ error: Error) -> Bool
}

/// Polling observes first. Only owned-host exit or fresh terminal state can
/// initiate cleanup; failed observations preserve the last known connection.
@MainActor public struct NativePollingService {
    public init() {}
    public func poll(_ runtime: any NativePollingRuntime) async {
        guard runtime.canObserve else { return }
        let captured = runtime.connection
        func current() -> Bool {
            !Task.isCancelled && runtime.connection.isCurrent(revision: captured.revision,
                recoveryGeneration: captured.recovery.generation)
        }
        let running = await runtime.backendIsRunning()
        guard runtime.canObserve, current() else { return }
        if !running {
            runtime.setBusy(true); defer { runtime.setBusy(false) }
            runtime.cancelRecoveryAndObservations()
            if runtime.observation.systemProxyEnabled { try? await runtime.restoreSystemProxy() }
            runtime.publishBackendExited()
            return
        }
        if runtime.pendingDisconnect {
            if runtime.disconnectRetryDue { runtime.retryDisconnect() }
            return
        }
        do {
            if runtime.connection.recovery.active && !runtime.moduleUpdateActive {
                let observed = runtime.observation
                if runtime.connection.recovery.canAttempt(awake: observed.awake, networkAvailable: observed.networkAvailable, now: runtime.now) {
                    try await runtime.attemptRecovery()
                } else {
                    // Physical connectivity gates mutation, not local diagnosis.
                    try await runtime.refresh()
                }
                return
            }
            try await runtime.refresh()
            guard runtime.canObserve, current() else { return }
            let observed = runtime.observation
            if runtime.connection.requested, !observed.updating, observed.coreStopped || observed.lostTun {
                // Recheck an inactive helper after debounce. It may recover while the core is still alive.
                runtime.beginRecovery(restart: observed.coreStopped)
                return
            }
            if !observed.updating && observed.systemProxyEnabled && runtime.operationsObservationValid {
                runtime.setBusy(true); defer { runtime.setBusy(false) }
                if observed.coreStopped {
                    let updating = try await runtime.freshUpdateActivity()
                    guard current(), !updating else { return }
                    try await runtime.restoreSystemProxy()
                } else if observed.coreRunning { try await runtime.synchronizeProxyPort() }
            }
        } catch {
            guard runtime.canObserve, current() else { return }
            runtime.reportObservationFailure(error)
            if runtime.observation.updating {
                runtime.reportUpdateWaiting()
            } else if runtime.isTransient(error), runtime.connection.requested {
                if !runtime.connection.recovery.active { runtime.beginRecovery(restart: false) }
                runtime.retryRecovery()
            } else if runtime.connection.recovery.active {
                runtime.retryRecovery()
            }
        }
    }
}
