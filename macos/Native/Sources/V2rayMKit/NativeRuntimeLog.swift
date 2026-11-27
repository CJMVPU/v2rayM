import Foundation
import TunShared

public struct LogPage {
    public let items: [LogEntry]
    public let page, pageSize, total, totalPages: Int
}

final class NativeRuntimeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = RollingLogBuffer()
    private var sequence: Int64 = 0
    private var generation: Int64 = 0
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    func append(source: String, lines: [String]) {
        guard !lines.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        let stamp = formatter.string(from: Date())
        let batch = lines.map { line in
            sequence += 1
            let message = line.utf16.count > 16384 ? String(decoding: line.utf16.prefix(16360), as: UTF16.self) + "… [log entry truncated]" : line
            return LogEntry(timestamp: stamp, source: source, message: message, sequence: sequence, generation: generation)
        }
        _ = buffer.append(batch)
    }
    func tail(after: Int64, limit: Int) -> LogTail {
        lock.lock(); defer { lock.unlock() }
        if after == sequence { return LogTail(items: [], latestSequence: sequence, generation: generation) }
        let cursor = after > sequence ? 0 : max(0, after)
        // append assigns consecutive sequence numbers and both retention limits evict from the front.
        let count = min(sequence - cursor, Int64(min(10_000, max(1, limit))))
        return LogTail(items: Array(buffer.entries.suffix(Int(count))), latestSequence: sequence, generation: generation)
    }
    private func filteredSnapshot(_ filter: String?) -> [LogEntry] {
        let snapshot = lock.withLock { buffer.entries }
        return RuntimeSearch.filter(snapshot, pattern: filter, budget: .milliseconds(200)) { [$0.source + " " + $0.message] }
    }

    func recent(limit: Int, filter: String?) -> [LogEntry] {
        Array(filteredSnapshot(filter).suffix(max(1, min(10000, limit))))
    }

    func page(_ requested: Int, size: Int, filter: String?) -> LogPage {
        let rows = filteredSnapshot(filter)
        let pageSize = max(1, min(size, 200))
        let pages = max(1, (rows.count + pageSize - 1) / pageSize)
        let page = max(1, min(requested, pages))
        let end = rows.count - (page - 1) * pageSize
        let start = max(0, end - pageSize)
        return LogPage(items: Array(rows[start..<end]), page: page, pageSize: pageSize, total: rows.count, totalPages: pages)
    }
    func clear() {
        lock.lock(); defer { lock.unlock() }
        buffer = RollingLogBuffer()
        generation += 1
    }
}
