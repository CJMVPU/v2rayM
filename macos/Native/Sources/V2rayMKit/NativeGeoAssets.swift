import Foundation
import TunShared

/// The active pointer changes only after both DAT files pass Xray validation and the
/// replacement session starts. A crash while downloading or testing leaves the old pointer intact.
struct NativeGeoAssets {
    let dataDirectory: URL
    let bundled: URL
    var root: URL { dataDirectory.appendingPathComponent("native-geo", isDirectory: true) }
    private var marker: URL { root.appendingPathComponent("current") }
    static let names = ["geoip", "geosite"]

    func active() throws -> URL {
        if FileManager.default.fileExists(atPath: marker.path) {
            let id = try String(contentsOf: marker, encoding: .utf8)
            guard UUID(uuidString: id)?.uuidString == id else { throw ClientFailure("geo_store_invalid") }
            let dir = root.appendingPathComponent(id)
            guard Self.hasFiles(dir) else { throw ClientFailure("geo_store_invalid") }
            return dir
        }
        let legacy = dataDirectory.appendingPathComponent("bin")
        return Self.hasFiles(legacy) ? legacy : bundled
    }

    private static func hasFiles(_ directory: URL) -> Bool {
        names.allSatisfy { name in
            let props = try? directory.appendingPathComponent(name + ".dat").resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
            return props?.isRegularFile == true && props?.isSymbolicLink != true && (props?.fileSize ?? 0) > 0
        }
    }

    func newGeneration() throws -> URL {
        let dir = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    func commit(_ dir: URL) throws {
        guard dir.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path,
              UUID(uuidString: dir.lastPathComponent)?.uuidString == dir.lastPathComponent, Self.hasFiles(dir) else {
            throw ClientFailure("geo_store_invalid")
        }
        try Data(dir.lastPathComponent.utf8).write(to: marker, options: .atomic)
    }

    func currentGeneration() throws -> String? {
        guard FileManager.default.fileExists(atPath: marker.path) else { return nil }
        return try active().lastPathComponent
    }

    func matchesActive(_ candidate: URL) throws -> Bool {
        let current = try active()
        return Self.names.allSatisfy { name in
            let file = name + ".dat"
            return FileManager.default.contentsEqual(atPath: candidate.appendingPathComponent(file).path,
                andPath: current.appendingPathComponent(file).resolvingSymlinksInPath().path)
        }
    }

    static func restoreGeneration(_ generation: String?, in data: URL) throws {
        let store = NativeGeoAssets(dataDirectory: data, bundled: data)
        if let generation {
            guard UUID(uuidString: generation)?.uuidString == generation else { throw ClientFailure("geo_store_invalid") }
            try store.commit(store.root.appendingPathComponent(generation))
        } else if FileManager.default.fileExists(atPath: store.marker.path) {
            try FileManager.default.removeItem(at: store.marker)
        }
    }

    func cleanUnused() throws {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let keep = try active().standardizedFileURL.path
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            where UUID(uuidString: url.lastPathComponent)?.uuidString == url.lastPathComponent && url.standardizedFileURL.path != keep {
            try FileManager.default.removeItem(at: url)
        }
    }

    static func download(to dir: URL, source: String, proxyEndpoints: ProxyEndpoints?,
                         idleTimeout: TimeInterval = 30, fileTimeout: TimeInterval = 600,
                         progress: @escaping @Sendable (Int, Int64, Int64?) async -> Void) async throws {
        let pattern = source.isEmpty ? "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/{0}.dat" : source
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = idleTimeout
        config.timeoutIntervalForResource = fileTimeout
        config.connectionProxyDictionary = SystemProxyController.connectionProxyDictionary(proxyEndpoints)
        for (i, name) in names.enumerated() {
            try Task.checkCancellation()
            guard let url = URL(string: pattern.replacingOccurrences(of: "{0}", with: name)),
                  ["https", "http"].contains(url.scheme?.lowercased()), url.host != nil else { throw ClientFailure("geo_source_invalid") }
            await progress(i, 0, nil)
            let transfer = GeoFileDownload(destination: dir.appendingPathComponent(name + ".dat")) { received, total in
                await progress(i, received, total)
            }
            try await transfer.run(url: url, configuration: config)
            await progress(i + 1, 0, nil)
        }
    }
}

private final class GeoFileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let destination: URL
    private let publish: @Sendable (Int64, Int64?) async -> Void
    // The session's serial delegate queue owns all mutable state, including cancellation.
    private var completion: CheckedContinuation<Void, Error>?
    private var cancelled = false
    private var failure: ClientFailure?
    private var output: FileHandle?
    private var received: Int64 = 0
    private var expected: Int64?
    private var partial: URL { destination.appendingPathExtension("partial") }
    private var lastProgress: TimeInterval = -.infinity

    init(destination: URL, publish: @escaping @Sendable (Int64, Int64?) async -> Void) {
        self.destination = destination
        self.publish = publish
    }

    private func failed(_ reason: String) -> ClientFailure {
        ClientFailure("geo_download_failed", "\(destination.lastPathComponent)\(reason)")
    }

    func run(url: URL, configuration: URLSessionConfiguration) async throws {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: url)
        defer { session.invalidateAndCancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (pending: CheckedContinuation<Void, Error>) in
                queue.addOperation {
                    guard !self.cancelled else { pending.resume(throwing: CancellationError()); return }
                    self.completion = pending
                    task.resume()
                }
            }
        } onCancel: {
            queue.addOperation {
                self.cancelled = true
                session.invalidateAndCancel()
            }
        }
        try Task.checkCancellation()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode
            failure = failed(status.map { " 下载失败（HTTP \($0)）。" } ?? " 的下载响应无效。")
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength <= Int64(HelperContract.resourceBytes) else {
            failure = failed(" 超过单个规则文件的大小上限。")
            completionHandler(.cancel)
            return
        }
        expected = response.expectedContentLength > 0 ? response.expectedContentLength : nil
        guard FileManager.default.createFile(atPath: partial.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: partial) else {
            failure = failed(" 无法写入规则文件。")
            completionHandler(.cancel)
            return
        }
        output = handle
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !cancelled, failure == nil, let output else { return }
        received += Int64(data.count)
        guard received <= Int64(HelperContract.resourceBytes) else {
            failure = failed(" 超过单个规则文件的大小上限。")
            dataTask.cancel()
            return
        }
        do { try output.write(contentsOf: data) } catch {
            failure = failed(" 无法写入规则文件。")
            dataTask.cancel()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastProgress >= 0.2 else { return }
        lastProgress = now
        Task { [received, expected] in await publish(received, expected) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let pending = completion else { return }
        completion = nil
        do {
            try output?.close()
            if !cancelled && failure == nil && error == nil {
                if received == 0 { failure = failed(" 下载内容为空。") }
                else { try FileManager.default.moveItem(at: partial, to: destination) }
            }
        } catch { failure = failed(" 无法写入规则文件。") }
        try? FileManager.default.removeItem(at: partial)
        if cancelled { pending.resume(throwing: CancellationError()) }
        else if let failure { pending.resume(throwing: failure) }
        else if let error {
            let code = (error as NSError).code
            pending.resume(throwing: failed(code == NSURLErrorTimedOut ? " 下载超时。" : " 网络下载失败（错误码 \(code)）。"))
        } else { pending.resume() }
    }
}
