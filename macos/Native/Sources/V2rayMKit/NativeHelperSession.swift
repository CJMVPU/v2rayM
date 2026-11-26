import Foundation
import TunShared

/// Each XPC connection has its own helper session. Keep the starting connection alive
/// until stop; a separate connection can query the cleanup receipt after disconnect.
final class NativeHelperChannel: @unchecked Sendable {
    private let connection: NSXPCConnection
    convenience init(onDisconnect: (@Sendable () -> Void)? = nil) throws {
        let signing = try SigningPolicy()
        let connection = NSXPCConnection(machServiceName: HelperIdentity.service, options: .privileged)
        connection.setCodeSigningRequirement(signing.requirement(identifiers: [HelperIdentity.service]))
        self.init(connection: connection, onDisconnect: onDisconnect)
    }

    init(connection: NSXPCConnection, onDisconnect: (@Sendable () -> Void)? = nil) {
        self.connection = connection
        connection.remoteObjectInterface = NSXPCInterface(with: TunHelperProtocol.self)
        connection.interruptionHandler = onDisconnect
        connection.invalidationHandler = onDisconnect
        connection.resume()
    }
    deinit { connection.invalidate() }
    func invalidate() { connection.invalidate() }

    private final class Reply<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var timeout: DispatchWorkItem?
        func arm(_ continuation: CheckedContinuation<T, Error>, seconds: Double) {
            let item = DispatchWorkItem { [weak self] in self?.finish(.failure(ClientFailure("helper_timeout"))) }
            lock.lock()
            self.continuation = continuation
            timeout = item
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
        }
        func finish(_ result: Result<T, Error>) {
            lock.lock()
            let pending = continuation
            continuation = nil
            timeout?.cancel()
            timeout = nil
            lock.unlock()
            pending?.resume(with: result)
        }
    }

    struct RejectedOpen: Error { let reason: Error }

    func open(_ plan: TunnelNetworkPlan) async throws -> (String, FileHandle) {
        let data = try JSONEncoder().encode(plan)
        let result: (Data, FileHandle?) = try await withTaskCancellationHandler {
            if Task.isCancelled { throw RejectedOpen(reason: CancellationError()) }
            return try await withCheckedThrowingContinuation { continuation in
                let reply = Reply<(Data, FileHandle?)>()
                reply.arm(continuation, seconds: 10)
                let proxy = connection.remoteObjectProxyWithErrorHandler { _ in reply.finish(.failure(ClientFailure("helper_unavailable"))) }
                guard let remote = proxy as? TunHelperProtocol else { reply.finish(.failure(ClientFailure("helper_unavailable"))); return }
                remote.openTunnel(data) { response, file in reply.finish(.success((response, file))) }
            }
        } onCancel: { self.invalidate() }
        let status = try JSONDecoder().decode(HelperResponse.self, from: result.0)
        guard status.protocolVersion == HelperContract.version else { throw ClientFailure("helper_protocol_mismatch") }
        // Older descriptor-capable helpers return tunnel_busy before registering a token.
        if !status.success, result.1 == nil,
           status.leaseAccepted == false || (status.leaseAccepted == nil && status.code == "tunnel_busy") {
            throw RejectedOpen(reason: ClientFailure(status.code))
        }
        guard status.success, status.state == "prepared",
              let name = status.tunnelInterface, name.wholeMatch(of: #/utun[0-9]+/#) != nil, let file = result.1 else {
            throw ClientFailure(status.success ? "invalid_tunnel_descriptor" : status.code)
        }
        return (name, file)
    }

    func call(_ request: HelperRequest, timeout: Double = 20) async throws -> HelperResponse {
        let data = try JSONEncoder().encode(request)
        guard data.count <= HelperContract.wireBytes else { throw ClientFailure("request_too_large") }
        let reply = Reply<Data>()
        let readOnly = request.action == "status" || request.action == "cleanup-status"
        let output: Data = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                reply.arm(continuation, seconds: timeout)
                if Task.isCancelled { reply.finish(.failure(CancellationError())); return }
                let proxy = connection.remoteObjectProxyWithErrorHandler { _ in reply.finish(.failure(ClientFailure("helper_unavailable"))) }
                guard let remote = proxy as? TunHelperProtocol else { reply.finish(.failure(ClientFailure("helper_unavailable"))); return }
                remote.request(data) { reply.finish(.success($0)) }
            }
        } onCancel: {
            reply.finish(.failure(CancellationError()))
            // The status reader shares the connection that owns the active tunnel.
            if !readOnly { self.invalidate() }
        }
        let decoded = try JSONDecoder().decode(HelperResponse.self, from: output)
        guard decoded.protocolVersion == HelperContract.version else { throw ClientFailure("helper_protocol_mismatch") }
        return decoded
    }
}

actor NativeHelperSession {
    typealias ChannelFactory = ((@Sendable () -> Void)?) throws -> NativeHelperChannel
    private let makeChannel: ChannelFactory
    init(makeChannel: @escaping ChannelFactory = { try NativeHelperChannel(onDisconnect: $0) }) {
        self.makeChannel = makeChannel
    }

    private var channel: NativeHelperChannel?
    private var pendingToken: String?
    private var lastProbe: (date: Date, response: HelperResponse)?

    func status(fresh: Bool = false, requiresIPv6: Bool = false) async -> HelperResponse {
        do {
            let response: HelperResponse
            if channel == nil, !fresh, let lastProbe, Date().timeIntervalSince(lastProbe.date) < 5 {
                response = lastProbe.response
            } else {
                let client = try channel ?? makeChannel(nil)
                response = try await client.checkCapability()
                try Task.checkCancellation()
                if channel == nil { lastProbe = (Date(), response) }
            }
            try Self.checkIPv6Capability(response, required: requiresIPv6)
            return response
        } catch {
            let code = (error as? ClientFailure)?.code ?? (error as? HelperFailure)?.description ?? "helper_unavailable"
            return HelperResponse(success: false, code: code, state: "unavailable")
        }
    }

    func prepare(config: SettingsValue, token: UUID, onDisconnect: @escaping @Sendable () -> Void) async throws -> (String, FileHandle) {
        if pendingToken != nil { try await stop() }
        let tunnels = config["inbounds"].items.filter { $0["protocol"].text == "tun" }
        guard tunnels.count == 1, let settings = tunnels.first?["settings"], let mtu = Int(settings["MTU"].text),
              let gateway = settings["gateway"].items.first?.text else { throw ClientFailure("invalid_tunnel_settings") }
        let addresses = settings["gateway"].items
        guard addresses.count <= 2 else { throw ClientFailure("invalid_tunnel_settings") }
        let plan = TunnelNetworkPlan(token: token, mtu: mtu, gateway: gateway, ipv6Gateway: addresses.dropFirst().first?.text, routes: settings["autoSystemRoutingTable"].items.map(\.text))
        _ = try plan.validated()
        let owner = try makeChannel(onDisconnect)
        let capability = try await owner.checkCapability()
        guard capability.success else { throw ClientFailure(capability.code) }
        try Self.checkIPv6Capability(capability, required: plan.ipv6Gateway != nil)
        channel = owner
        pendingToken = token.uuidString
        do { return try await owner.open(plan) }
        catch let rejection as NativeHelperChannel.RejectedOpen {
            // An authenticated, definite refusal leaves no ownership to recover.
            owner.invalidate()
            channel = nil
            pendingToken = nil
            throw rejection.reason
        }
    }

    private static func checkIPv6Capability(_ status: HelperResponse, required: Bool) throws {
        if status.success, required, status.supportsTunnelIPv6Address != true { throw ClientFailure("helper_protocol_mismatch") }
    }

    func activate(token: UUID) async throws {
        guard channel != nil, pendingToken == token.uuidString else { throw ClientFailure("session_token_invalid") }
        var request = HelperRequest(action: "activate-tunnel")
        request.sessionToken = token.uuidString
        let response = try await channel?.call(request)
        guard response?.success == true, response?.state == "running" else { throw ClientFailure(response?.code ?? "helper_unavailable") }
        lastProbe = nil
    }

    func stop() async throws {
        guard let token = pendingToken else { return }
        if let channel {
            _ = try? await channel.call(HelperRequest(action: "stop"))
            channel.invalidate()
            self.channel = nil
        }
        lastProbe = nil
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline {
            var request = HelperRequest(action: "cleanup-status")
            request.sessionToken = token
            if let probe = try? makeChannel(nil),
               let result = try? await probe.call(request, timeout: 3) {
                if result.code == "session_cleanup_confirmed" {
                    guard result.success, result.state == "stopped", !result.forced else { break }
                    pendingToken = nil
                    return
                }
                if result.code == "session_cleanup_unconfirmed" { break }
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw ClientFailure("tun_stop_unconfirmed")
    }

}

extension NativeHelperChannel {
    func checkCapability() async throws -> HelperResponse {
        let response = try await call(HelperRequest(action: "status"), timeout: 5)
        guard !response.success || response.supportsTunnelDescriptor == true else {
            throw ClientFailure("helper_protocol_mismatch")
        }
        return response
    }
}
