/// A stronger match in a later feed entry takes precedence over an earlier weak match.
package enum SubscriptionMatchPass: CaseIterable {
    case providerIdentity, exact, peerIdentity, credentials, name, endpoint, address
}

package struct SubscriptionIdentityMatches<Row> {
    package let matches: [Row?]
    package let unmatched: [Row]

    package init<Key: Hashable>(stored: [Row], incoming: [Row], key: (SubscriptionMatchPass, Row) -> Key?,
                                compatible: (Row, Row) -> Bool) {
        var used = Set<Int>()
        var matches = [Row?](repeating: nil, count: incoming.count)
        for pass in SubscriptionMatchPass.allCases {
            if used.count == stored.count || used.count == incoming.count { break }
            var old = [Key: [Int]]()
            var new = [Key: [Int]]()
            for i in stored.indices where !used.contains(i) {
                if let key = key(pass, stored[i]) { old[key, default: []].append(i) }
            }
            for i in incoming.indices where matches[i] == nil {
                if let key = key(pass, incoming[i]) { new[key, default: []].append(i) }
            }
            for (key, indices) in new {
                guard let candidates = old[key], pass == .exact || (candidates.count == 1 && indices.count == 1) else { continue }
                for (i, candidate) in zip(indices, candidates) where compatible(stored[candidate], incoming[i]) {
                    matches[i] = stored[candidate]
                    used.insert(candidate)
                }
            }
        }
        self.matches = matches
        unmatched = stored.indices.compactMap { used.contains($0) ? nil : stored[$0] }
    }
}
