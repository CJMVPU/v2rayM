import Foundation
import Darwin
import OSLog
import TunShared
import TunNetworkControl

final class SessionEndpoint: NSObject, TunHelperProtocol {
    let queue = DispatchQueue(label: "v2rayM.tun.session")
    let cancellation = HelperCancellation()
    let recovery: SessionRecoveryStore
    let limiter: SlotLimiter
    private let owner: uid_t
    private let slot = UUID()
    private var sessionToken: String?
    private var lease: NetworkLease?
    init(limiter: SlotLimiter, recovery: SessionRecoveryStore, owner: uid_t) {
        self.owner = owner
        self.limiter = limiter
        self.recovery = recovery
    }

    func openTunnel(_ parameters: Data, withReply reply: @escaping (Data, FileHandle?) -> Void) {
        queue.async {
            var accepted = false
            do {
                guard !self.cancellation.isCancelled, self.sessionToken == nil, parameters.count <= 1024 * 1024 else {
                    throw HelperFailure("tunnel_request_invalid")
                }
                let plan = try JSONDecoder().decode(TunnelNetworkPlan.self, from: parameters)
                guard self.limiter.acquire(self.slot) else { throw HelperFailure("tunnel_busy") }
                do {
                    guard try self.recovery.begin(plan.token.uuidString, owner: self.owner) else {
                        throw HelperFailure("session_token_invalid")
                    }
                } catch {
                    self.limiter.release(self.slot)
                    throw error
                }
                accepted = true
                self.sessionToken = plan.token.uuidString
                let lease = try NetworkLease(plan)
                self.lease = lease
                var response = HelperResponse(state: "prepared")
                response.leaseAccepted = true
                response.tunnelInterface = lease.name
                reply(try JSONEncoder().encode(response), lease.handle)
            } catch {
                var failure = HelperResponse(success: false, code: (error as? HelperFailure)?.description ?? "tunnel_prepare_failed", state: "faulted")
                failure.leaseAccepted = accepted
                reply((try? JSONEncoder().encode(failure)) ?? Data(), nil)
            }
        }
    }

    func request(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        queue.async {
            let response: HelperResponse
            do {
                guard !self.cancellation.isCancelled, data.count <= 8192 else { throw HelperFailure("tunnel_request_invalid") }
                let request = try DecodedHelperRequest(data: data).request
                switch request.action {
                case "status":
                    var status = HelperResponse(state: self.lease?.active == true ? "running" : "idle")
                    status.supportsTunnelDescriptor = true
                    status.supportsTunnelIPv6Address = true
                    response = status
                case "activate-tunnel":
                    guard let lease = self.lease, self.sessionToken == request.sessionToken else { throw HelperFailure("session_token_invalid") }
                    try lease.activate(cancelled: { self.cancellation.isCancelled })
                    response = HelperResponse(state: "running")
                case "stop":
                    try self.restore()
                    response = HelperResponse(state: "stopped")
                case "cleanup-status":
                    response = self.recovery.status(request.sessionToken, owner: self.owner)
                default: throw HelperFailure("unsupported_helper_action")
                }
            } catch {
                response = HelperResponse(success: false, code: (error as? HelperFailure)?.description ?? "helper_operation_failed", state: "faulted")
            }
            reply((try? JSONEncoder().encode(response)) ?? Data())
        }
    }

    private func restore() throws {
        guard let token = sessionToken else { return }
        try lease?.restore()
        lease = nil
        try recovery.finish(token, confirmed: true, owner: owner)
        limiter.release(slot)
        sessionToken = nil
    }

    func stopAndWait() -> Bool {
        cancellation.cancel()
        return queue.sync {
            do { try restore(); return true } catch { return false }
        }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let signing: SigningPolicy
    let limiter = SlotLimiter(capacity: 1)
    let cleanup = SessionCleanupCoordinator()
    let recovery: SessionRecoveryStore
    private let lock = NSLock()
    private var sessions: [UUID: SessionEndpoint] = [:]
    private var stopping = false
    private var idleExit: DispatchWorkItem?
    init(signing: SigningPolicy) throws {
        guard geteuid() == 0 else { throw HelperFailure("root_daemon_required") }
        self.signing = signing
        let executable = try ExecutableLocation.current()
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard bundle.pathExtension == "app", executable.lastPathComponent == "V2rayMHelper" else {
            throw HelperFailure("signed_app_bundle_required")
        }
        recovery = try SessionRecoveryStore(directory: URL(fileURLWithPath: "/private/var/db/" + HelperIdentity.service))
        super.init()
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(signing.requirement(identifiers: [HelperIdentity.app]))
        let endpoint = SessionEndpoint(limiter: limiter, recovery: recovery, owner: connection.effectiveUserIdentifier)
        let id = UUID()
        lock.lock()
        guard !stopping else { lock.unlock(); return false }
        idleExit?.cancel()
        idleExit = nil
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
            self.lock.lock()
            self.sessions.removeValue(forKey: id)
            if self.sessions.isEmpty && !self.stopping {
                let item = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    let idle = self.sessions.isEmpty && !self.stopping
                    if idle { self.stopping = true }
                    self.lock.unlock()
                    if idle { exit(0) }
                }
                self.idleExit = item
                DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: item)
            }
            self.lock.unlock()
        }
    }
    func shutdown() -> Bool {
        lock.lock(); stopping = true; let active = Array(sessions.values); lock.unlock()
        for endpoint in active { endpoint.cancellation.cancel() }
        let clean = SessionShutdownCoordinator.stop(active.map { endpoint in { endpoint.stopAndWait() } })
        if clean {
            lock.lock(); sessions.removeAll(); lock.unlock()
        }
        // Unfinished leases retain their descriptors and pending route deletions for retry.
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
