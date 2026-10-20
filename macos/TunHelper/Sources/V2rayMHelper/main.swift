import Foundation
import Darwin
import TunShared

final class SessionEndpoint: NSObject, TunHelperProtocol {
    let session: TunSession
    let queue = DispatchQueue(label: "v2rayM.tun.session")
    init(_ session: TunSession) { self.session = session }
    func request(_ data: Data, withReply reply: @escaping (Data) -> Void) {
        queue.async { reply((try? JSONEncoder().encode(self.session.handle(data))) ?? Data()) }
    }
    func disconnect() { queue.async { self.session.disconnect() } }
    func stopAndWait() { queue.sync { session.disconnect() } }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    let signing: SigningPolicy
    let policy: LaunchPolicy
    let limiter = SlotLimiter()
    private let lock = NSLock()
    private var sessions: [UUID: SessionEndpoint] = [:]
    private var stopping = false
    init(signing: SigningPolicy) throws {
        guard geteuid() == 0 else { throw HelperFailure("root_daemon_required") }
        self.signing = signing
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard bundle.pathExtension == "app", executable.lastPathComponent == "V2rayMHelper" else {
            throw HelperFailure("signed_app_bundle_required")
        }
        policy = LaunchPolicy(bundle: bundle,
            stateRoot: URL(fileURLWithPath: "/private/var/run/" + HelperIdentity.service),
            validate: { try signing.validateCore($0, kind: $1) })
        super.init()
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(signing.requirement(identifiers: [HelperIdentity.app, HelperIdentity.app + ".bridge"]))
        let endpoint = SessionEndpoint(TunSession(limiter: limiter, prepare: policy.prepare))
        let id = UUID()
        lock.lock()
        guard !stopping else { lock.unlock(); return false }
        sessions[id] = endpoint
        lock.unlock()
        connection.exportedInterface = NSXPCInterface(with: TunHelperProtocol.self)
        connection.exportedObject = endpoint
        connection.invalidationHandler = { [weak self] in
            endpoint.disconnect()
            guard let self else { return }
            self.lock.lock(); self.sessions.removeValue(forKey: id); self.lock.unlock()
        }
        connection.interruptionHandler = { endpoint.disconnect() }
        connection.resume()
        return true
    }
    func shutdown() {
        lock.lock(); stopping = true; let active = Array(sessions.values); sessions.removeAll(); lock.unlock()
        for endpoint in active { endpoint.stopAndWait() }
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
        source.setEventHandler { delegate.shutdown(); exit(0) }
        source.resume()
        return source
    }
    withExtendedLifetime((delegate, signals)) { RunLoop.current.run() }
} catch {
    fputs("V2rayMHelper: \((error as? HelperFailure)?.description ?? "initialization_failed")\n", stderr)
    exit(78)
}
