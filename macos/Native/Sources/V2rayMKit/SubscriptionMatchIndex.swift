import Foundation

/// Match a whole feed at each confidence level. A weak guess for an early
/// entry must never consume the stored identity of a later exact match.
struct SubscriptionMatchIndex {
    private enum Key: Hashable {
        case exact(RuntimeDatabase.Row)
        case credentials(RuntimeDatabase.Value, String, Int64, String, String)
        case name(RuntimeDatabase.Value, String)
        case endpoint(RuntimeDatabase.Value, String, Int64)
        case address(RuntimeDatabase.Value, String)
    }

    private enum Pass: CaseIterable {
        case exact, credentials, name, endpoint, address

        func key(for row: RuntimeDatabase.Row) -> Key? {
            guard let kind = row["ConfigType"] else { return nil }
            // Group child IDs are rewritten on import, and file-backed rows
            // carry temporary JSON before materialization. Match by unique name.
            let complex = ProfileTransfer.isGroup(row) || FileProfileImport.isFile(row)
            if self == .name {
                guard case let .text(name) = row["Remarks"], !name.isEmpty else { return nil }
                return .name(kind, name)
            }
            guard !complex else { return nil }
            if self == .exact {
                var values = row.filter { $0.value != .null }
                for key in ["IndexId", "IsSub", "Subid", "ConfigVersion"] { values.removeValue(forKey: key) }
                return .exact(values)
            }
            guard case let .text(host) = row["Address"] else { return nil }
            let address = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !address.isEmpty else { return nil }
            if self == .address { return .address(kind, address) }
            let port: Int64
            switch row["Port"] {
            case .integer(let number): port = number
            case .text(let string):
                guard let number = Int64(string) else { return nil }
                port = number
            default: return nil
            }
            guard port > 0 else { return nil }
            if self == .endpoint { return .endpoint(kind, address, port) }
            guard case let .text(secret) = row["Password"], !secret.isEmpty else { return nil }
            var username = ""
            if case let .text(value) = row["Username"] { username = value }
            return .credentials(kind, address, port, username, secret)
        }
    }

    let matches: [RuntimeDatabase.Row?]
    let unmatched: [RuntimeDatabase.Row]

    init(previous: [RuntimeDatabase.Row], incoming: [RuntimeDatabase.Row]) {
        let stored = previous.filter { row in
            ProfileTransfer.supportsXray(row) && (ProfileTransfer.isOrdinary(row) || ProfileTransfer.isGroup(row) || FileProfileImport.isFile(row))
        }
        var used = Set<Int>()
        var matches = [RuntimeDatabase.Row?](repeating: nil, count: incoming.count)
        for pass in Pass.allCases {
            if used.count == stored.count || used.count == incoming.count { break }
            var old = [Key: [Int]]()
            var new = [Key: [Int]]()
            for i in stored.indices where !used.contains(i) {
                if let key = pass.key(for: stored[i]) { old[key, default: []].append(i) }
            }
            for i in incoming.indices where matches[i] == nil {
                if let key = pass.key(for: incoming[i]) { new[key, default: []].append(i) }
            }
            for (key, indices) in new {
                guard let candidates = old[key], pass == .exact || (candidates.count == 1 && indices.count == 1) else { continue }
                for (i, candidate) in zip(indices, candidates) {
                    matches[i] = stored[candidate]
                    used.insert(candidate)
                }
            }
        }
        self.matches = matches
        unmatched = stored.indices.compactMap { used.contains($0) ? nil : stored[$0] }
    }
}
