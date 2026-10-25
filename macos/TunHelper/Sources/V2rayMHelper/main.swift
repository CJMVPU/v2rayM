import Foundation
import Darwin
import OSLog
import TunShared

final class SessionEndpoint: NSObject, TunHelperProtocol {
    let session: TunSession
    let updates: TrustedCoreStore
    let queue = DispatchQueue(label: "v2rayM.tun.session")
    let cancellation = HelperCancellation()
    let recovery: SessionRecoveryStore
    private var sessionToken: String?
    init(_ session: TunSession, updates: TrustedCoreStore, recovery: SessionRecoveryStore) {
        self.session = session; self.updates = updates; self.recovery = recovery
    }
    func request(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        queue.async {
            guard !self.cancellation.isCancelled else {
                reply((try? JSONEncoder().encode(HelperResponse(success: false, code: "session_disconnected", state: "unavailable"))) ?? Data())
                return
            }
            let response: HelperResponse
            if data.count <= HelperContract.wireBytes,
               let request = try? JSONDecoder().decode(HelperRequest.self, from: data) {
                if request.action == "cleanup-status" {
                    response = self.recovery.status(request.sessionToken)
                } else if request.action == "start" {
                    if self.sessionToken == nil && self.recovery.begin(request.sessionToken) {
                        self.sessionToken = request.sessionToken
                        response = self.session.handle(data)
                    } else {
                        response = HelperResponse(success: false, code: "session_token_invalid", state: "unavailable")
                    }
                } else if request.action.hasPrefix("update-") {
                    response = self.updates.handle(request, cancellation: self.cancellation)
                } else { response = self.session.handle(data) }
            } else { response = self.session.handle(data) }
            reply((try? JSONEncoder().encode(response)) ?? Data())
        }
    }
    func stopAndWait(requireConfirmedRecovery: Bool = false) -> Bool {
        cancellation.cancel()
        return queue.sync {
            let clean = session.disconnect(requireConfirmedRecovery: requireConfirmedRecovery)
            if clean, let token = sessionToken { recovery.finish(token, confirmed: session.cleanupConfirmed) }
            return clean
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let signing: SigningPolicy
    let policy: LaunchPolicy
    let updates: TrustedCoreStore
    let limiter = SlotLimiter()
    let cleanup = SessionCleanupCoordinator()
    let recovery = SessionRecoveryStore()
    private let lock = NSLock()
    private var sessions: [UUID: SessionEndpoint] = [:]
    private var stopping = false
    init(signing: SigningPolicy) throws {
        guard geteuid() == 0 else { throw HelperFailure("root_daemon_required") }
        self.signing = signing
        let updates = TrustedCoreStore(root: URL(fileURLWithPath: "/Library/Application Support/" + HelperIdentity.app + ".VerifiedCores"))
        self.updates = updates
        let executable = try ExecutableLocation.current()
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard bundle.pathExtension == "app", executable.lastPathComponent == "V2rayMHelper" else {
            throw HelperFailure("signed_app_bundle_required")
        }
        policy = LaunchPolicy(bundle: bundle,
            stateRoot: URL(fileURLWithPath: "/private/var/run/" + HelperIdentity.service),
            validate: { try signing.validateCore($0, kind: $1) }, verifiedCore: updates.source)
        super.init()
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(signing.requirement(identifiers: [HelperIdentity.app, HelperIdentity.app + ".bridge"]))
        let endpoint = SessionEndpoint(TunSession(limiter: limiter, prepare: policy.prepare), updates: updates, recovery: recovery)
        let id = UUID()
        lock.lock()
        guard !stopping else { lock.unlock(); return false }
        sessions[id] = endpoint
        lock.unlock()
        connection.exportedInterface = NSXPCInterface(with: TunHelperProtocol.self)
        connection.exportedObject = endpoint
        connection.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.disconnect(id: id, endpoint: endpoint)
        }
        connection.interruptionHandler = { [weak self] in self?.disconnect(id: id, endpoint: endpoint) }
        connection.resume()
        return true
    }
    private func disconnect(id: UUID, endpoint: SessionEndpoint) {
        endpoint.cancellation.cancel()
        cleanup.disconnect(id: id, cleanup: { endpoint.stopAndWait() }) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.sessions.removeValue(forKey: id); self.lock.unlock()
        }
    }
    func shutdown() -> Bool {
        lock.lock(); stopping = true; let active = Array(sessions.values); lock.unlock()
        for endpoint in active { endpoint.cancellation.cancel() }
        let clean = SessionShutdownCoordinator.stop(active.map { endpoint in { endpoint.stopAndWait(requireConfirmedRecovery: true) } })
        if clean {
            lock.lock(); sessions.removeAll(); lock.unlock()
        }
        // Retain unfinished owners until process exit. Closing the helper's SC
        // session removes temporary DNS; launchd owns remaining process-group
        // members. Neither is proof that the core restored all routes gracefully.
        return clean
    }
}

do {
    let delegate = try ListenerDelegate(signing: SigningPolicy())
    let listener = NSXPCListener(machServiceName: HelperIdentity.service)
    listener.delegate = delegate
    listener.resume()
    let shutdownQueue = DispatchQueue(label: "v2rayM.tun.shutdown")
    let signals = [SIGTERM, SIGINT].map { value -> DispatchSourceSignal in
        signal(value, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: value, queue: shutdownQueue)
        source.setEventHandler {
            if delegate.shutdown() { exit(0) }
            Logger(subsystem: HelperIdentity.service, category: "shutdown")
                .error("Helper shutdown deadline exceeded; network recovery is unconfirmed. Remaining sessions retained until process exit.")
            fputs("V2rayMHelper: shutdown_cleanup_unconfirmed\n", stderr)
            exit(1)
        }
        source.resume()
        return source
    }
    withExtendedLifetime((delegate, signals)) { RunLoop.current.run() }
} catch {
    let failure = (error as? HelperFailure)?.description ?? "initialization_failed"
    Logger(subsystem: HelperIdentity.service, category: "startup")
        .error("Helper initialization failed: \(failure, privacy: .public)")
    fputs("V2rayMHelper: \(failure)\n", stderr)
    exit(78)
}
