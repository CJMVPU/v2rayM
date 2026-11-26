import Foundation

private final class WebDAVRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct NativeWebDAV {
    private let base: URL
    private let components: [String]
    let directory: URL
    private let authorization: String

    init(settings: SettingsValue) throws {
        let item = settings["WebDavItem"]
        let user = item["UserName"].text, password = item["Password"].text
        guard let base = URL(string: item["Url"].text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(base.scheme?.lowercased()), base.host != nil, base.user == nil,
              base.password == nil, base.fragment == nil, base.query == nil, !user.isEmpty, !password.isEmpty else {
            throw ClientFailure("webdav_settings_invalid")
        }
        let configured = item["DirName"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = (configured.isEmpty ? "v2rayN_backup" : configured).split(separator: "/")
        guard !parts.isEmpty, !parts.contains("."), !parts.contains("..") else { throw ClientFailure("webdav_settings_invalid") }
        self.base = base
        components = parts.map(String.init)
        directory = components.reduce(base) { $0.appendingPathComponent($1, isDirectory: true) }
        authorization = "Basic " + Data((user + ":" + password).utf8).base64EncodedString()
    }

    private func request(_ method: String, url: URL) -> URLRequest {
        var result = URLRequest(url: url, timeoutInterval: 45)
        result.httpMethod = method
        result.setValue(authorization, forHTTPHeaderField: "Authorization")
        return result
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        return URLSession(configuration: config, delegate: WebDAVRedirectPolicy(), delegateQueue: nil)
    }

    private func ensureCollection(_ session: URLSession) async throws {
        func makeCollection(_ url: URL) async throws -> Bool {
            let (_, response) = try await session.data(for: request("MKCOL", url: url))
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 409 { return false } // Missing parent collection.
            guard (200..<300).contains(code) || code == 405 else { throw ClientFailure("webdav_collection_failed") }
            return true
        }
        // Established collections may be writable while their parents forbid MKCOL.
        if try await makeCollection(directory) { return }
        guard components.count > 1 else { throw ClientFailure("webdav_collection_failed") }
        var collection = base
        for component in components {
            collection.appendPathComponent(component, isDirectory: true)
            guard try await makeCollection(collection) else { throw ClientFailure("webdav_collection_failed") }
        }
    }

    private func check(_ response: URLResponse) throws {
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else { throw ClientFailure("webdav_transfer_failed") }
    }

    func probe() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        try await ensureCollection(session)
        let file = directory.appendingPathComponent("readme_test-" + UUID().uuidString)
        let payload = Data(UUID().uuidString.utf8)
        let (_, stored) = try await session.upload(for: request("PUT", url: file), from: payload)
        try check(stored)
        func removeProbe() async throws {
            let (_, deleted) = try await session.data(for: request("DELETE", url: file))
            try check(deleted)
        }
        do {
            let (bytes, response) = try await session.bytes(for: request("GET", url: file))
            try check(response)
            var actual = bytes.makeAsyncIterator()
            for expected in payload {
                guard try await actual.next() == expected else { throw ClientFailure("webdav_transfer_failed") }
            }
            guard try await actual.next() == nil else { throw ClientFailure("webdav_transfer_failed") }
        } catch {
            // The task may be cancelled after the upload. Still remove its remote file.
            _ = await Task { try await removeProbe() }.result
            throw error
        }
        try await removeProbe()
    }

    func upload(_ archive: URL) async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        try await ensureCollection(session)
        let (_, response) = try await session.upload(for: request("PUT", url: directory.appendingPathComponent("backup.zip")), fromFile: archive)
        try check(response)
    }

    func download(to archive: URL) async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request("GET", url: directory.appendingPathComponent("backup.zip")))
        try check(response)
        guard response.expectedContentLength <= NativeBackupArchive.limit else { throw ClientFailure("backup_archive_too_large") }
        guard FileManager.default.createFile(atPath: archive.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ClientFailure("backup_create_failed")
        }
        let output = try FileHandle(forWritingTo: archive)
        defer { try? output.close() }
        var block = Data(), count = 0
        for try await byte in bytes {
            count += 1
            guard count <= NativeBackupArchive.limit else { throw ClientFailure("backup_archive_too_large") }
            block.append(byte)
            if block.count >= 65536 {
                try output.write(contentsOf: block)
                block.removeAll(keepingCapacity: true)
            }
        }
        try output.write(contentsOf: block)
    }
}
