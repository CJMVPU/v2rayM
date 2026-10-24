import Foundation
import Darwin

/// Continuously drains child output; both the current and previous file are size bounded.
/// A logging I/O failure must not block the child's pipe or interfere with network recovery.
public final class RotatingProcessLog: @unchecked Sendable {
    public let pipe = Pipe()
    private let lock = NSLock()
    private let current: URL
    private let previous: URL
    private let maximumBytes: Int
    private var file: FileHandle?
    private var size = 0
    private var closed = false
    public init(current: URL, previous: URL, maximumBytes: Int = 8 * 1024 * 1024) throws {
        self.current = current; self.previous = previous; self.maximumBytes = max(1, maximumBytes)
        try rotate()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            guard !self.closed else { return }
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            else { try? self.write(data) }
        }
    }
    /// The child inherited its own writer. Closing ours lets EOF reach the reader on exit.
    public func didStart() { try? pipe.fileHandleForWriting.close() }
    public func append(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        try write(data)
    }
    private func write(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            if file == nil || size >= maximumBytes { try rotate() }
            let count = min(maximumBytes - size, data.count - offset)
            try file?.write(contentsOf: data[offset..<(offset + count)])
            offset += count; size += count
        }
    }
    private func rotate() throws {
        try file?.close(); file = nil
        if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
        if FileManager.default.fileExists(atPath: current.path) {
            try FileManager.default.moveItem(at: current, to: previous)
            let old = try FileHandle(forReadingFrom: previous)
            defer { try? old.close() }
            let length = try old.seekToEnd()
            if length > UInt64(maximumBytes) {
                try old.seek(toOffset: length - UInt64(maximumBytes))
                let tail = try old.readToEnd() ?? Data()
                try tail.write(to: previous, options: .atomic)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previous.path)
        }
        guard FileManager.default.createFile(atPath: current.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        file = try FileHandle(forWritingTo: current); size = 0
    }
    /// Call after the owned child has exited; drain any final output before closing the files.
    public func finish() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        try? pipe.fileHandleForWriting.close()
        pipe.fileHandleForReading.readabilityHandler = nil
        // A descendant can inherit the writer even after the owned backend exits.
        // Drain only available bytes; never let logging hold up proxy/TUN shutdown.
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                guard count > 0 else { break }
                try? write(Data(buffer.prefix(count)))
            }
        }
        closed = true
        try? pipe.fileHandleForReading.close(); try? file?.close(); file = nil
    }
    deinit {
        pipe.fileHandleForReading.readabilityHandler = nil
        try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close(); try? file?.close()
    }
}
