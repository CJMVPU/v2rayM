import Foundation
import Security
import Darwin

public actor BackendController {
    private var process: Process?
    private var log: FileHandle?
    public private(set) var client: APIClient?
    public let dataDirectory: URL
    private let backend: URL
    private let port: Int
    public init(bundle: URL = Bundle.main.bundleURL, dataDirectory: URL? = nil, port: Int = 19888) {
        backend = bundle.appendingPathComponent("Contents/Resources/Backend/v2rayN.WebAPI")
        self.dataDirectory = dataDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/v2rayM", isDirectory: true)
        self.port = port
    }
    public var isRunning: Bool { process?.isRunning == true }
    public func start() async throws -> APIClient {
        if let client, process?.isRunning == true { return client }
        guard FileManager.default.isExecutableFile(atPath: backend.path) else { throw ClientFailure("backend_missing") }
        guard (1024...65535).contains(port) else { throw ClientFailure("invalid_port") }
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let logs = dataDirectory.appendingPathComponent("guiLogs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let logURL = logs.appendingPathComponent("native-backend.log")
        // Keep a single previous startup log instead of growing indefinitely.
        let previous = logs.appendingPathComponent("native-backend.previous.log")
        try? FileManager.default.removeItem(at: previous)
        if FileManager.default.fileExists(atPath: logURL.path) { try FileManager.default.moveItem(at: logURL, to: previous) }
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        log = try FileHandle(forWritingTo: logURL)
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ClientFailure("random_failed") }
        let key = Data(bytes).base64EncodedString()
        let client = APIClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!, managementKey: key)
        let child = Process(); child.executableURL = backend
        child.arguments = ["--foreground", "--no-open", "--urls", "http://127.0.0.1:\(port)"]
        child.currentDirectoryURL = backend.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment.filter { key, _ in
            !key.hasPrefix("V2RAYN_") && !key.hasPrefix("V2RAYM_") && !key.hasPrefix("ASPNETCORE_")
                && !key.lowercased().hasPrefix("kestrel") && !key.hasPrefix("DYLD_")
                && !["URLS", "HTTP_PORTS", "HTTPS_PORTS", "INVOCATION_ID", "JOURNAL_STREAM", "NOTIFY_SOCKET"].contains(key)
        }
        // The bundled host uses immutable appsettings. Native FSEvents watches on an app
        // inside Documents can block in macOS privacy checks before Kestrel starts.
        environment["DOTNET_HOSTBUILDER__RELOADCONFIGONCHANGE"] = "false"
        environment["DOTNET_USE_POLLING_FILE_WATCHER"] = "1"
        environment["Logging__LogLevel__Microsoft.AspNetCore"] = "Warning"
        environment["V2RAYM_DATA_HOME"] = dataDirectory.path
        environment["V2RAYN_WEB_API_KEY"] = key
        environment["V2RAYN_WEB_AUTOSTART"] = "false"
        environment["V2RAYN_WEB_PROXY_LISTEN_ALL"] = "false"
        environment["DOTNET_BUNDLE_EXTRACT_BASE_DIR"] = dataDirectory.appendingPathComponent("guiTemps/dotnet").path
        child.environment = environment
        child.standardInput = FileHandle.nullDevice; child.standardOutput = log; child.standardError = log
        try child.run(); process = child
        do {
            for _ in 0..<200 {
                guard child.isRunning else { throw ClientFailure("backend_exited") }
                do {
                    try await client.health(expectedPID: child.processIdentifier)
                    guard child.isRunning else { throw ClientFailure("backend_exited") }
                    self.client = client
                    return client
                } catch let error as ClientFailure { throw error }
                catch { try await Task.sleep(for: .milliseconds(200)) }
            }
            throw ClientFailure("backend_timeout")
        } catch {
            try? await stop(); throw error
        }
    }
    /// Signal only the Process instance created here; never discover/kill by name or lock-file PID.
    public func stop() async throws {
        if let child = process, child.isRunning {
            child.terminate()
            for _ in 0..<240 {
                if !child.isRunning { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            guard !child.isRunning else { throw ClientFailure("backend_stop_timeout") }
        }
        await client?.logout()
        process = nil; client = nil
        try? log?.close(); log = nil
    }
}
