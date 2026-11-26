import Foundation
import V2rayMDomain

/// Translates stored SQLite fields into identity keys for a subscription refresh.
struct SubscriptionMatchIndex {
    private enum Key: Hashable {
        case exact(RuntimeDatabase.Row)
        case credentials(RuntimeDatabase.Value, String, Int64, String, String)
        case name(RuntimeDatabase.Value, String)
        case endpoint(RuntimeDatabase.Value, String, Int64)
        case address(RuntimeDatabase.Value, String)
    }

    private static func key(_ pass: SubscriptionMatchPass, for row: RuntimeDatabase.Row) -> Key? {
        guard let kind = row["ConfigType"] else { return nil }
        // Group child IDs are rewritten on import, and file-backed rows
        // carry temporary JSON before materialization. Match by unique name.
        let complex = ProfileTransfer.isGroup(row) || FileProfileImport.isFile(row)
        if pass == .name {
            guard case let .text(name) = row["Remarks"], !name.isEmpty else { return nil }
            return .name(kind, name)
        }
        guard !complex else { return nil }
        if pass == .exact {
            var values = row.filter { $0.value != .null }
            for key in ["IndexId", "IsSub", "Subid", "ConfigVersion"] { values.removeValue(forKey: key) }
            return .exact(values)
        }
        guard case let .text(host) = row["Address"] else { return nil }
        let address = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !address.isEmpty else { return nil }
        if pass == .address { return .address(kind, address) }
        let port: Int64
        switch row["Port"] {
        case .integer(let number): port = number
        case .text(let string):
            guard let number = Int64(string) else { return nil }
            port = number
        default: return nil
        }
        guard port > 0 else { return nil }
        if pass == .endpoint { return .endpoint(kind, address, port) }
        guard case let .text(secret) = row["Password"], !secret.isEmpty else { return nil }
        var username = ""
        if case let .text(value) = row["Username"] { username = value }
        return .credentials(kind, address, port, username, secret)
    }

    let matches: [RuntimeDatabase.Row?]
    let unmatched: [RuntimeDatabase.Row]

    init(previous: [RuntimeDatabase.Row], incoming: [RuntimeDatabase.Row]) {
        let stored = previous.filter { row in
            ProfileTransfer.supportsXray(row) && (ProfileTransfer.isOrdinary(row) || ProfileTransfer.isGroup(row) || FileProfileImport.isFile(row))
        }
        let result = SubscriptionIdentityMatches(stored: stored, incoming: incoming, key: Self.key)
        matches = result.matches
        unmatched = result.unmatched
    }
}
