import Foundation
import CryptoKit
import Darwin

public struct VerifiedCoreSource {
    public let url: URL
    public let sha256: String
}

public struct OfficialCoreAsset: Decodable {
    public let name: String
    public let size: Int
    public let digest: String?
    public let browser_download_url: String
    public let state: String
}
public struct OfficialCoreRelease: Decodable {
    public let draft: Bool
    public let assets: [OfficialCoreAsset]
}

public enum OfficialCorePolicy {
    public static func hasKnownDarwinBindingBug(_ version: String) -> Bool {
        version.hasPrefix("Xray 26.10.21 ") && version.range(of: #"(?:^|\s)\S*-v2raym-darwin-bind[12](?:\s|$)"#, options: .regularExpression) == nil
    }
    public static func coordinates(kind: String, releaseURL: String) throws -> (repository: String, tag: String, name: String) {
        let repository: String
        switch kind { case "xray": repository = "XTLS/Xray-core"
        default: throw HelperFailure("update_core_not_allowed") }
        guard let url = URL(string: releaseURL), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !releaseURL.contains("%"), !releaseURL.contains("\\") else { throw HelperFailure("update_source_not_allowed") }
        let segments = url.path.split(separator: "/").map(String.init)
        guard segments.count == 6, segments.prefix(2).joined(separator: "/") == repository,
              segments[2] == "releases", segments[3] == "download",
              segments[4].range(of: "^v?[0-9][A-Za-z0-9._-]{0,79}$", options: .regularExpression) != nil else {
            throw HelperFailure("update_source_not_allowed")
        }
        #if arch(arm64)
        let validName = segments[5] == "Xray-macos-arm64-v8a.zip"
        #else
        let validName = segments[5] == "Xray-macos-64.zip"
        #endif
        guard validName, segments[5].range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            throw HelperFailure("update_asset_not_allowed")
        }
        return (repository, segments[4], segments[5])
    }
    public static func verifiedDigest(release: OfficialCoreRelease, name: String, releaseURL: String, archive: Data) throws -> String {
        guard !release.draft, let asset = release.assets.first(where: { $0.name == name }),
              asset.state == "uploaded", asset.browser_download_url == releaseURL,
              asset.size > 0, asset.size <= 64 * 1024 * 1024, asset.size == archive.count,
              let digest = asset.digest, digest.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw HelperFailure("official_package_digest_missing")
        }
        let expected = String(digest.dropFirst(7))
        guard hash(archive) == expected else { throw HelperFailure("official_package_digest_mismatch") }
        return expected
    }
    public static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

private final class NoOfficialRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Only the root helper creates this store. Callers supply a fixed official release URL and package;
/// the helper independently authenticates the package digest before extracting a single executable.
public final class TrustedCoreStore {
    private struct Manifest: Codable {
        var kind: String
        var token: String
        var releaseURL: String
        var packageSHA256: String
        var executableSHA256: String
        var version: String
        var committed: Bool
    }
    private let root: URL
    private let owner: uid_t
    private let lock = NSLock()
    private var activeTokens = Set<String>()
    private var rolledBackTokens = Set<String>()
    private let metadataLoader: ((String, String, HelperOperationContext) throws -> OfficialCoreRelease)?
    private let toolRunner: ((String, [String], Int, HelperOperationContext) throws -> Data)?
    public convenience init(root: URL, owner: uid_t = 0) {
        self.init(root: root, owner: owner, metadataLoader: nil, toolRunner: nil)
    }
    init(root: URL, owner: uid_t,
         metadataLoader: ((String, String, HelperOperationContext) throws -> OfficialCoreRelease)?,
         toolRunner: ((String, [String], Int, HelperOperationContext) throws -> Data)?) {
        self.root = root; self.owner = owner
        self.metadataLoader = metadataLoader; self.toolRunner = toolRunner
    }
    private func directory(_ url: URL, create: Bool = false) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 && create {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == owner, info.st_mode & 0o077 == 0 else { throw HelperFailure("update_store_not_private") }
    }
    private func base(_ kind: String) throws -> URL {
        guard kind == "xray" else { throw HelperFailure("update_core_not_allowed") }
        try directory(root, create: true)
        let base = root.appendingPathComponent(kind); try directory(base, create: true)
        let current = base.appendingPathComponent("current"), previous = base.appendingPathComponent("previous")
        // A crash can occur between either pair of renames in activate/rollback.
        // In that state previous is the only surviving selection; restore it first.
        if !FileManager.default.fileExists(atPath: current.path), FileManager.default.fileExists(atPath: previous.path) {
            guard try read(previous).kind == kind else { throw HelperFailure("update_store_invalid") }
            try FileManager.default.moveItem(at: previous, to: current)
        }
        if FileManager.default.fileExists(atPath: current.path) {
            let manifest = try read(current)
            guard manifest.kind == kind else { throw HelperFailure("update_store_invalid") }
            if !manifest.committed && !activeTokens.contains(manifest.token) {
                rolledBackTokens.insert(manifest.token)
                try FileManager.default.removeItem(at: current)
                if FileManager.default.fileExists(atPath: previous.path) { try directory(previous); try FileManager.default.moveItem(at: previous, to: current) }
            } else if manifest.committed && FileManager.default.fileExists(atPath: previous.path) {
                // Commit is durable before the old directory is removed. Resume
                // that cleanup after a crash, only after verifying the new core.
                let binary = current.appendingPathComponent("core")
                try regularFile(binary, maxSize: 256 * 1024 * 1024)
                guard OfficialCorePolicy.hash(try Data(contentsOf: binary)) == manifest.executableSHA256 else {
                    throw HelperFailure("installed_core_digest_mismatch")
                }
                try directory(previous); try FileManager.default.removeItem(at: previous)
            }
        }
        // Interrupted staging files never become executable selections. Reap abandoned
        // packages after a day, keeping current/previous untouched.
        for entry in try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.creationDateKey]) where entry.lastPathComponent.hasPrefix("stage-") {
            if let created = try entry.resourceValues(forKeys: [.creationDateKey]).creationDate, Date().timeIntervalSince(created) > 86400 {
                try directory(entry); try FileManager.default.removeItem(at: entry)
            }
        }
        return base
    }
    private func checkToken(_ token: String) throws {
        guard UUID(uuidString: token) != nil, !token.contains("/") else { throw HelperFailure("update_token_invalid") }
    }
    private func read(_ path: URL) throws -> Manifest {
        try directory(path)
        let url = path.appendingPathComponent("manifest.json")
        try regularFile(url, maxSize: 16384)
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
    }
    private func regularFile(_ url: URL, maxSize: Int) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == owner, info.st_mode & 0o077 == 0, info.st_size > 0, info.st_size <= maxSize else {
            throw HelperFailure("update_file_not_private")
        }
    }
    private func metadata(_ repository: String, tag: String, context: HelperOperationContext) throws -> OfficialCoreRelease {
        try context.check()
        if let metadataLoader { return try metadataLoader(repository, tag, context) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 25; configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: NoOfficialRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/tags/\(tag)")!)
        request.setValue("v2rayM-privileged-updater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let semaphore = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var result: Result<Data, Error>?
        let task = session.dataTask(with: request) { data, response, error in
            resultLock.lock(); defer { resultLock.unlock(); semaphore.signal() }
            if let error { result = .failure(error) }
            else if let response = response as? HTTPURLResponse, response.statusCode == 200,
                    let data, data.count <= 4 * 1024 * 1024 { result = .success(data) }
            else { result = .failure(HelperFailure("official_release_unavailable")) }
        }
        task.resume()
        defer { task.cancel() }
        let deadline = ProcessInfo.processInfo.systemUptime + 35
        while semaphore.wait(timeout: .now() + 0.1) != .success {
            try context.check()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw HelperFailure("official_release_timeout") }
        }
        try context.check()
        resultLock.lock(); let value = result; resultLock.unlock()
        return try JSONDecoder().decode(OfficialCoreRelease.self, from: value!.get())
    }
    func tool(_ path: String, _ arguments: [String], limit: Int = 2 * 1024 * 1024, context: HelperOperationContext) throws -> Data {
        try context.check()
        if let toolRunner { return try toolRunner(path, arguments, limit, context) }
        let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Only this Process owns the child. Force its exit if a broken tool ignores SIGTERM,
        // so a stalled version probe cannot leave the privileged update queue blocked.
        let deadline = ProcessInfo.processInfo.systemUptime + 25
        let timeout = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        timeout.schedule(deadline: .now(), repeating: 0.1)
        timeout.setEventHandler {
            if ProcessInfo.processInfo.systemUptime >= deadline || (try? context.check()) == nil {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        timeout.resume()
        defer { timeout.cancel(); try? pipe.fileHandleForReading.close() }
        var data = Data()
        while true {
            let chunk = try pipe.fileHandleForReading.read(upToCount: 65536) ?? Data()
            if chunk.isEmpty { break }
            guard data.count + chunk.count <= limit else {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit(); throw HelperFailure("official_executable_too_large")
            }
            data.append(chunk)
        }
        process.waitUntilExit()
        try context.check()
        guard process.terminationStatus == 0 else { throw HelperFailure("official_package_tool_failed") }
        return data
    }
    public func stage(kind: String, releaseURL: String, archive: Data,
                      context: HelperOperationContext = HelperOperationContext()) throws -> HelperResponse {
        try context.check()
        guard archive.count <= 64 * 1024 * 1024 else { throw HelperFailure("official_package_too_large") }
        let coordinate = try OfficialCorePolicy.coordinates(kind: kind, releaseURL: releaseURL)
        let release = try metadata(coordinate.repository, tag: coordinate.tag, context: context)
        let digest = try OfficialCorePolicy.verifiedDigest(release: release, name: coordinate.name, releaseURL: releaseURL, archive: archive)
        try context.check()
        let token = UUID().uuidString
        let stage: URL
        lock.lock()
        do {
            stage = try base(kind).appendingPathComponent("stage-" + token)
            try directory(stage, create: true)
            lock.unlock()
        } catch { lock.unlock(); throw error }
        do {
            let archiveURL = stage.appendingPathComponent("package")
            try archive.write(to: archiveURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archiveURL.path)
            let listing = String(decoding: try tool("/usr/bin/tar", ["-tf", archiveURL.path], context: context), as: UTF8.self)
                .split(separator: "\n").map(String.init)
            guard !listing.isEmpty, listing.count <= 4096,
                  listing.allSatisfy({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..")
                      && $0.range(of: "^[A-Za-z0-9_./+-]+$", options: .regularExpression) != nil }) else {
                throw HelperFailure("official_archive_entries_invalid")
            }
            let name = "xray"
            let matches = listing.filter { !$0.hasSuffix("/") && URL(fileURLWithPath: $0).lastPathComponent == name }
            guard matches.count == 1 else { throw HelperFailure("official_executable_missing") }
            let entry = matches[0]
            let type = String(decoding: try tool("/usr/bin/tar", ["-tvf", archiveURL.path, "--", entry], context: context), as: UTF8.self)
            guard type.hasPrefix("-") else { throw HelperFailure("official_executable_not_regular") }
            let binary = try tool("/usr/bin/tar", ["-xOf", archiveURL.path, "--", entry], limit: 256 * 1024 * 1024, context: context)
            let executable = stage.appendingPathComponent("core")
            try binary.write(to: executable, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let architecture = String(decoding: try tool("/usr/bin/lipo", ["-archs", executable.path], context: context), as: UTF8.self)
            #if arch(arm64)
            guard architecture.split(whereSeparator: \.isWhitespace).contains("arm64") else { throw HelperFailure("official_executable_architecture") }
            #else
            guard architecture.split(whereSeparator: \.isWhitespace).contains("x86_64") else { throw HelperFailure("official_executable_architecture") }
            #endif
            _ = try tool("/usr/bin/codesign", ["--verify", "--strict", executable.path], context: context)
            let version = String(decoding: try tool(executable.path, ["version"], context: context), as: UTF8.self)
            guard version.contains("Xray"), version.count < 8192 else { throw HelperFailure("official_version_invalid") }
            guard !OfficialCorePolicy.hasKnownDarwinBindingBug(version) else { throw HelperFailure("xray_darwin_binding_update_unsafe") }
            let manifest = Manifest(kind: kind, token: token, releaseURL: releaseURL, packageSHA256: digest,
                executableSHA256: OfficialCorePolicy.hash(binary), version: version, committed: false)
            let manifestURL = stage.appendingPathComponent("manifest.json")
            try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
            try FileManager.default.removeItem(at: archiveURL)
            try context.check()
            var response = HelperResponse(state: "staged"); response.updateToken = token; return response
        } catch { try? FileManager.default.removeItem(at: stage); throw error }
    }
    public func transition(action: String, kind: String, token: String) throws -> HelperResponse {
        lock.lock(); defer { lock.unlock() }
        try checkToken(token)
        let base = try base(kind), current = base.appendingPathComponent("current"), previous = base.appendingPathComponent("previous")
        let stage = base.appendingPathComponent("stage-" + token)
        switch action {
        case "update-activate":
            let manifest = try read(stage)
            guard manifest.kind == kind, manifest.token == token, !FileManager.default.fileExists(atPath: previous.path) else { throw HelperFailure("update_store_busy") }
            if FileManager.default.fileExists(atPath: current.path), !(try read(current).committed) { throw HelperFailure("update_store_busy") }
            if FileManager.default.fileExists(atPath: current.path) { try directory(current); try FileManager.default.moveItem(at: current, to: previous) }
            do { try FileManager.default.moveItem(at: stage, to: current) }
            catch { if FileManager.default.fileExists(atPath: previous.path) { try? FileManager.default.moveItem(at: previous, to: current) }; throw error }
            activeTokens.insert(token)
            DispatchQueue.global().asyncAfter(deadline: .now() + 120) { [weak self] in self?.expire(kind: kind, token: token) }
        case "update-rollback":
            if rolledBackTokens.contains(token) { return HelperResponse(state: "ready") }
            let manifest = try read(current)
            guard manifest.token == token else { throw HelperFailure("update_token_mismatch") }
            // A successful finish may lose its XPC acknowledgement. Its previous
            // version has already been discarded; a late rollback cannot restore
            // it and must never delete the only committed selection.
            guard !manifest.committed else { throw HelperFailure("update_already_committed") }
            activeTokens.remove(token); rolledBackTokens.insert(token)
            try FileManager.default.removeItem(at: current)
            if FileManager.default.fileExists(atPath: previous.path) { try directory(previous); try FileManager.default.moveItem(at: previous, to: current) }
        case "update-finish":
            var manifest = try read(current)
            guard manifest.token == token else { throw HelperFailure("update_token_mismatch") }
            manifest.committed = true
            let manifestURL = current.appendingPathComponent("manifest.json")
            try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
            activeTokens.remove(token)
            if FileManager.default.fileExists(atPath: previous.path) { try directory(previous); try FileManager.default.removeItem(at: previous) }
        case "update-discard":
            if FileManager.default.fileExists(atPath: stage.path) { try directory(stage); try FileManager.default.removeItem(at: stage) }
        default: throw HelperFailure("update_action_invalid")
        }
        return HelperResponse(state: "ready")
    }
    private func expire(kind: String, token: String) {
        lock.lock(); defer { lock.unlock() }
        guard activeTokens.remove(token) != nil else { return }
        // base() recovers an activation that never received its successful restart acknowledgement.
        _ = try? base(kind)
    }
    public func source(_ kind: String) throws -> VerifiedCoreSource? {
        lock.lock(); defer { lock.unlock() }
        let current = try base(kind).appendingPathComponent("current")
        guard FileManager.default.fileExists(atPath: current.path) else { return nil }
        let manifest = try read(current), executable = current.appendingPathComponent("core")
        try regularFile(executable, maxSize: 256 * 1024 * 1024)
        guard manifest.kind == kind, OfficialCorePolicy.hash(try Data(contentsOf: executable)) == manifest.executableSHA256 else { throw HelperFailure("installed_core_digest_mismatch") }
        // An authenticated but affected old cache must not override the app's signed fix.
        // Validate the cache first, then let LaunchPolicy verify the bundled private copy.
        if OfficialCorePolicy.hasKnownDarwinBindingBug(manifest.version) { return nil }
        return VerifiedCoreSource(url: executable, sha256: manifest.executableSHA256)
    }
    public func handle(_ request: HelperRequest, cancellation: HelperCancellation = HelperCancellation()) -> HelperResponse {
        do {
            guard let kind = request.core else { throw HelperFailure("update_core_required") }
            if request.action == "update-status" {
                lock.lock(); defer { lock.unlock() }
                let base = try base(kind), current = base.appendingPathComponent("current")
                var response = HelperResponse(state: "ready")
                response.previousVersionPresent = FileManager.default.fileExists(atPath: base.appendingPathComponent("previous").path)
                if FileManager.default.fileExists(atPath: current.path) {
                    let manifest = try read(current), binary = current.appendingPathComponent("core")
                    try regularFile(binary, maxSize: 256 * 1024 * 1024)
                    guard OfficialCorePolicy.hash(try Data(contentsOf: binary)) == manifest.executableSHA256 else { throw HelperFailure("installed_core_digest_mismatch") }
                    response.coreVersion = manifest.version; response.verifiedSHA256 = manifest.executableSHA256
                }
                return response
            }
            if request.action == "update-stage", let url = request.releaseURL, let archive = request.archive {
                return try stage(kind: kind, releaseURL: url, archive: archive,
                                 context: HelperOperationContext(cancellation: cancellation))
            }
            guard let token = request.updateToken else { throw HelperFailure("update_token_invalid") }
            return try transition(action: request.action, kind: kind, token: token)
        } catch { return HelperResponse(success: false, code: (error as? HelperFailure)?.description ?? "trusted_update_failed", state: "failed") }
    }
}
