import Foundation

/// A malformed or timed-out expression leaves the original snapshot visible.
enum RuntimeSearch {
    static func filter<T>(_ snapshot: [T], pattern: String?, budget: Duration,
                          fields: (T) -> [String]) -> [T] {
        guard let pattern, !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              pattern.utf16.count <= 4096 else { return snapshot }
        let deadline = ContinuousClock.now + budget
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return snapshot }
        var matches = [T]()
        for row in snapshot {
            if ContinuousClock.now >= deadline { return snapshot }
            for field in fields(row) where !field.isEmpty {
                var found = false
                var expired = false
                expression.enumerateMatches(in: field, options: .reportProgress, range: NSRange(field.startIndex..., in: field)) {
                    match, flags, stop in
                    expired = ContinuousClock.now >= deadline || flags.contains(.internalError)
                    found = match != nil
                    if found || expired { stop.pointee = true }
                }
                if expired { return snapshot }
                if found { matches.append(row); break }
            }
        }
        return matches
    }
}
