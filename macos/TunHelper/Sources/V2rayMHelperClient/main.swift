import Foundation
import ServiceManagement
import TunShared

func emit(_ response: HelperResponse) {
    if let data = try? JSONEncoder().encode(response) {
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
    }
}

final class Client {
    let connection: NSXPCConnection
    init() throws {
        let signing = try SigningPolicy()
        connection = NSXPCConnection(machServiceName: HelperIdentity.service, options: .privileged)
        connection.setCodeSigningRequirement(signing.requirement(identifiers: [HelperIdentity.service]))
        connection.remoteObjectInterface = NSXPCInterface(with: TunHelperProtocol.self)
        connection.resume()
    }
    func call(_ request: HelperRequest) throws -> HelperResponse {
        let completion = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: Result<Data, Error>?
        func finish(_ value: Result<Data, Error>) {
            lock.lock(); defer { lock.unlock() }
            if result == nil { result = value; completion.signal() }
        }
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in finish(.failure(HelperFailure("helper_unavailable"))) }
        guard let remote = proxy as? TunHelperProtocol else { throw HelperFailure("helper_unavailable") }
        remote.request(try JSONEncoder().encode(request)) { finish(.success($0)) }
        guard completion.wait(timeout: .now() + (request.action == "update-stage" ? HelperOperationContext.stageClientTimeout : 20)) == .success else { throw HelperFailure("helper_timeout") }
        lock.lock(); let value = result; lock.unlock()
        return try JSONDecoder().decode(HelperResponse.self, from: value!.get())
    }
    deinit { connection.invalidate() }
}

final class StopFlag {
    private let lock = NSLock()
    private var stopped = false
    func set() { lock.lock(); stopped = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

do {
    let action = CommandLine.arguments.dropFirst().first ?? "status"
    if ["register", "unregister", "approval"].contains(action) {
        _ = try SigningPolicy()
        let service = SMAppService.daemon(plistName: HelperIdentity.plist)
        if action == "register" {
            do { try service.register() }
            catch {
                // A daemon can be registered while still awaiting the user's approval.
                guard service.status == .requiresApproval else { throw error }
            }
        }
        if action == "unregister" { try service.unregister() }
        if action == "approval" { SMAppService.openSystemSettingsLoginItems() }
        let ready = service.status == .enabled
        let state: String
        switch service.status {
        case .enabled: state = "ready"
        case .requiresApproval: state = "requiresApproval"
        case .notRegistered: state = "notRegistered"
        case .notFound: state = "notFound"
        @unknown default: state = "unavailable"
        }
        let success = action == "unregister" ? service.status == .notRegistered : ready
        emit(HelperResponse(success: success, code: success ? "ok" : "helper_approval_required", state: state))
        if !success { exit(2) }
    } else if action == "status" {
        let client = try Client(); let response = try client.call(HelperRequest(action: "status"))
        emit(response)
        if !response.success { exit(1) }
    } else if action == "cleanup-status" {
        guard let token = readLine(), UUID(uuidString: token) != nil else { throw HelperFailure("session_token_invalid") }
        var request = HelperRequest(action: action); request.sessionToken = token
        let response = try Client().call(request)
        emit(response)
        if !response.success { exit(1) }
    } else if action == "update" {
        guard let line = readLine(), line.utf8.count <= HelperContract.wireBytes,
              let data = line.data(using: .utf8) else { throw HelperFailure("update_request_required") }
        let request = try JSONDecoder().decode(HelperRequest.self, from: data)
        guard request.action.hasPrefix("update-"), HelperContract.actions.contains(request.action) else { throw HelperFailure("update_action_invalid") }
        let response = try Client().call(request)
        emit(response)
        if !response.success { exit(1) }
    } else if action == "run" {
        guard let line = readLine(), line.utf8.count <= HelperContract.wireBytes,
              let bytes = line.data(using: .utf8) else { throw HelperFailure("start_request_required") }
        let request = try JSONDecoder().decode(HelperRequest.self, from: bytes)
        guard request.action == "start" else { throw HelperFailure("start_request_required") }
        let client = try Client()
        defer { client.connection.invalidate() }
        var response = try client.call(request)
        emit(response)
        guard response.success && response.state == "running" else { exit(1) }
        let stop = StopFlag()
        // Closing stdin (including backend death) requests graceful cleanup.
        DispatchQueue.global().async { _ = readLine(); stop.set() }
        while response.state == "running" && !stop.value {
            Thread.sleep(forTimeInterval: 0.25)
            response = try client.call(HelperRequest(action: "status")); emit(response)
            if !response.success { break }
        }
        if stop.value || !response.success {
            response = try client.call(HelperRequest(action: "stop")); emit(response)
        }
        if !response.success || response.state == "running" { exit(1) }
    } else { throw HelperFailure("action_not_allowed") }
} catch {
    let detail = error as NSError
    fputs("V2rayMHelperClient: \(detail.domain) (\(detail.code)): \(detail.localizedDescription)\n", stderr)
    emit(HelperResponse(success: false, code: (error as? HelperFailure)?.description ?? "helper_client_failed", state: "unavailable"))
    exit(1)
}
