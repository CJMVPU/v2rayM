import Foundation

public struct RollingLogBuffer {
    public private(set) var entries: [LogEntry] = []
    private var ids = Set<String>()
    private var characters = 0
    private let maximumLines: Int
    private let maximumCharacters: Int
    public init(maximumLines: Int = 10_000, maximumCharacters: Int = 8_000_000) {
        self.maximumLines = max(1, maximumLines); self.maximumCharacters = max(1, maximumCharacters)
    }
    public mutating func append(_ incoming: [LogEntry]) {
        for entry in incoming where ids.insert(entry.id).inserted {
            entries.append(entry); characters += entry.message.utf16.count + entry.source.utf16.count
        }
        var remove = 0
        while entries.count - remove > maximumLines || characters > maximumCharacters {
            let entry = entries[remove]; ids.remove(entry.id)
            characters -= entry.message.utf16.count + entry.source.utf16.count; remove += 1
        }
        if remove > 0 { entries.removeFirst(remove) }
    }
}
