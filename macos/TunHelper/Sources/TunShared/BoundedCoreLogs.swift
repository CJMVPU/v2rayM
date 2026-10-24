import Foundation

/// Access is serialized by TunSession's log lock. A head index makes oldest-first
/// eviction amortized O(1), while periodic compaction also bounds retained memory.
struct BoundedCoreLogs {
    private var entries: [String?] = []
    private var head = 0
    private(set) var bytes = 0
    let maximumCount: Int
    let maximumBytes: Int
    init(maximumCount: Int = 10_000, maximumBytes: Int = 1_000_000) {
        precondition(maximumCount > 0 && maximumBytes > 0)
        self.maximumCount = maximumCount; self.maximumBytes = maximumBytes
    }
    var count: Int { entries.count - head }
    mutating func append(_ entry: String) {
        entries.append(entry); bytes += entry.utf8.count
        while count > maximumCount || bytes > maximumBytes {
            bytes -= entries[head]!.utf8.count
            entries[head] = nil; head += 1
        }
        if head >= 1024 && head >= count {
            entries.removeFirst(head); head = 0
        }
    }
    mutating func drain() -> [String] {
        let result = entries[head...].compactMap { $0 }
        entries.removeAll(keepingCapacity: true); head = 0; bytes = 0
        return result
    }
}
