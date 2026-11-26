import Foundation
import V2rayMDomain

/// Translates stored SQLite fields into identity keys for a subscription refresh.
struct SubscriptionMatchIndex {
    private enum Key: Hashable {
        case provider(UUID)
        case exact(RuntimeDatabase.Row)
        case peer(String)
        case peerAtEndpoint(String, String, Int64)
        case credentials(RuntimeDatabase.Value, String, Int64, String, String)
        case name(RuntimeDatabase.Value, String)
        case endpoint(RuntimeDatabase.Value, String, Int64)
        case address(RuntimeDatabase.Value, String)
    }

    private static func key(_ pass: SubscriptionMatchPass, for row: RuntimeDatabase.Row) -> Key? {
        guard let kind = row["ConfigType"] else { return nil }
        if pass == .providerIdentity { return providerID(row).map(Key.provider) }
        let complex = ProfileTransfer.isGroup(row) || FileProfileImport.isFile(row)
        if pass == .exact {
            guard !complex else { return nil }
            var values = row.filter { $0.value != .null }
            for key in ["IndexId", "IsSub", "Subid", "ConfigVersion"] { values.removeValue(forKey: key) }
            return .exact(values)
        }
        // WireGuard imports derive display names from the peer order and share the interface secret.
        // An endpoint may disambiguate duplicate public keys, but can never join two different peers.
        if kind == .integer(9) {
            guard pass == .peerIdentity || pass == .endpoint,
                  case let .text(json) = row["ProtoExtra"],
                  let options = try? SettingsValue.parse(json),
                  case let .string(key) = options["WgPublicKey"], !key.isEmpty else { return nil }
            let identity = XrayOutbound.wireGuardKeyIdentity(key) ?? key
            if pass == .peerIdentity { return .peer(identity) }
            guard case let .text(host) = row["Address"], !host.isEmpty,
                  case let .integer(port) = row["Port"] else { return nil }
            return .peerAtEndpoint(identity, host.lowercased(), port)
        }
        guard pass != .peerIdentity else { return nil }
        // Group child IDs are rewritten on import, and file-backed rows
        // carry temporary JSON before materialization. Match by unique name.
        if pass == .name {
            guard case let .text(name) = row["Remarks"], !name.isEmpty else { return nil }
            return .name(kind, name)
        }
        guard !complex else { return nil }
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

    static func providerID(_ row: RuntimeDatabase.Row) -> UUID? {
        guard row["ConfigType"] == .integer(3), case let .text(json) = row["ProtoExtra"],
              let options = try? SettingsValue.parse(json) else { return nil }
        return UUID(uuidString: options["Sip008ServerId"].text)
    }

    let matches: [RuntimeDatabase.Row?]
    let unmatched: [RuntimeDatabase.Row]

    init(previous: [RuntimeDatabase.Row], incoming: [RuntimeDatabase.Row]) {
        let stored = previous.filter { row in
            ProfileTransfer.supportsXray(row) && (ProfileTransfer.isOrdinary(row) || ProfileTransfer.isGroup(row) || FileProfileImport.isFile(row))
        }
        let result = SubscriptionIdentityMatches(stored: stored, incoming: incoming, key: Self.key) { original, update in
            guard let old = Self.providerID(original), let new = Self.providerID(update) else { return true }
            return old == new
        }
        matches = result.matches
        unmatched = result.unmatched
    }
}
