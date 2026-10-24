import Foundation

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
public actor APIClient {
    public let baseURL: URL
    private let key: String
    private var token: String?
    private var loginTask: Task<String, Error>?
    private let session: URLSession
    public init(baseURL: URL, managementKey: String) {
        self.init(baseURL: baseURL, managementKey: managementKey, configuration: .ephemeral)
    }
    /// Internal transport seam for isolated URLProtocol contract tests.
    init(baseURL: URL, managementKey: String, configuration: URLSessionConfiguration) {
        precondition(baseURL.host == "127.0.0.1" && baseURL.scheme == "http")
        self.baseURL = baseURL; key = managementKey
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 35
        configuration.timeoutIntervalForResource = 90
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }
    public func health(expectedPID: Int32) async throws {
        let (data, response) = try await raw("/api/health", authenticated: false)
        guard response.statusCode == 200,
              response.value(forHTTPHeaderField: "X-v2rayn-WebAPI-instance-pid") == String(expectedPID),
              (try? JSONDecoder().decode(Health.self, from: data).status) == "ok" else {
            throw ClientFailure("backend_identity")
        }
    }
    public func logout() async { _ = try? await raw("/api/auth/logout", method: "POST"); token = nil }
    private func login() async throws {
        if let loginTask { token = try await loginTask.value; return }
        let pending = Task { try await self.loginToken() }
        loginTask = pending
        defer { loginTask = nil }
        token = try await pending.value
    }
    private func loginToken() async throws -> String {
        let data = try JSONEncoder().encode(["key": key])
        let (reply, response) = try await raw("/api/auth/login", method: "POST", body: data, authenticated: false)
        guard response.statusCode == 200,
              let envelope = try? JSONDecoder().decode(APIEnvelope<SessionToken>.self, from: reply),
              envelope.success, let result = envelope.data else { throw ClientFailure("unauthorized") }
        return result.token
    }
    public func encodedResponse(_ path: String, method: String, body: Data?) async throws -> Data {
        if token == nil { try await login() }
        var (data, response) = try await raw(path, method: method, body: body)
        if response.statusCode == 401 {
            token = nil; try await login()
            (data, response) = try await raw(path, method: method, body: body)
        }
        struct Result: Decodable { let success: Bool; let code: String? }
        let envelope = try JSONDecoder().decode(Result.self, from: data)
        guard (200..<300).contains(response.statusCode), envelope.success else {
            throw ClientFailure(envelope.code ?? "http_\(response.statusCode)")
        }
        return data
    }
    private func raw(_ path: String, method: String = "GET", body: Data? = nil,
                     authenticated: Bool = true) async throws -> (Data, HTTPURLResponse) {
        guard path.hasPrefix("/api/"), !path.contains("://"),
              let url = URL(string: baseURL.absoluteString + path), url.host == "127.0.0.1" else {
            throw ClientFailure("invalid_api_path")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        if path == "/api/health" { request.timeoutInterval = 1 }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if authenticated, let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientFailure("response_invalid") }
        return (data, http)
    }
}
