import Foundation

/// Pipe reads are arbitrary byte chunks, not log records. Keep UTF-8 bytes until LF.
public final class CoreLogLines {
    private var pending = Data()
    private var dropping = false
    private let lock = NSLock()
    public init() {}
    public func append(_ bytes: Data, end: Bool = false) -> [String] {
        lock.lock(); defer { lock.unlock() }
        var lines: [String] = []
        for byte in bytes {
            if byte == 10 {
                if !dropping {
                    if pending.last == 13 { pending.removeLast() }
                    if !pending.isEmpty { lines.append(String(decoding: pending, as: UTF8.self)) }
                }
                pending.removeAll(keepingCapacity: true); dropping = false
            } else if !dropping {
                pending.append(byte)
                if pending.count >= 16_384 {
                    lines.append(String(decoding: pending, as: UTF8.self) + "… [log entry truncated]")
                    pending.removeAll(keepingCapacity: true); dropping = true
                }
            }
        }
        if end && !pending.isEmpty {
            lines.append(String(decoding: pending, as: UTF8.self)); pending.removeAll()
        }
        return lines
    }
}
