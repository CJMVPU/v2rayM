import Foundation

public protocol RetainedLogEntry {
    var id: String { get }
    var source: String { get }
    var message: String { get }
}

public struct BoundedLogHistory<Entry: RetainedLogEntry> {
    public private(set) var entries: [Entry] = []
    /// Index of the first surviving record since this history was created.
    public private(set) var headOffset = 0
    private var ids = Set<String>()
    private var characters = 0
    private let maximumLines: Int
    private let maximumCharacters: Int
    public init(maximumLines: Int = 10_000, maximumCharacters: Int = 8_000_000) {
        self.maximumLines = max(1, maximumLines); self.maximumCharacters = max(1, maximumCharacters)
    }
    @discardableResult public mutating func append(_ incoming: [Entry]) -> Bool {
        var changed = false
        for entry in incoming where ids.insert(entry.id).inserted {
            changed = true
            entries.append(entry); characters += entry.message.utf16.count + entry.source.utf16.count
        }
        var remove = 0
        while entries.count - remove > maximumLines || characters > maximumCharacters {
            let entry = entries[remove]; ids.remove(entry.id)
            characters -= entry.message.utf16.count + entry.source.utf16.count; remove += 1
        }
        if remove > 0 { entries.removeFirst(remove); headOffset += remove }
        return changed
    }
}
