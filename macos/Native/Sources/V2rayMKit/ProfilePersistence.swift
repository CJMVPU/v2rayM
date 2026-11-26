import Foundation

extension NativeConfigurationStore {
    /// Persist only fields changed by this editor. If another operation changed one of
    /// those same fields, preserve its update and ask the editor to reload.
    @discardableResult
    func updateProfile(id: String, original: SettingsValue, edited: SettingsValue, commit: Bool = true) throws -> SettingsValue {
        if edited["coreType"] != original["coreType"], edited["coreType"] != .null, edited["coreType"].text != "xray" {
            throw ClientFailure("xray_only_profile_required")
        }
        guard original["indexId"] == .string(id), edited["indexId"] == original["indexId"],
              edited["configType"] == original["configType"], edited["coreType"] == original["coreType"] else {
            throw ClientFailure("profile_identity_changed")
        }
        let allColumns = ["Remarks", "Address", "Port", "Username", "Password", "Network", "StreamSecurity",
                          "AllowInsecure", "Sni", "Alpn", "Fingerprint", "PublicKey", "ShortId", "CertSha", "VerifyPeerCertByName",
                          "ProtoExtra", "TransportExtra"]
        let basic = !["custom", "outbound", "policygroup", "proxychain"].contains(original["configType"].text.lowercased())
        let validated = basic ? try ProfileDocument(edited).validated() : edited
        if basic, edited["certSha"] != original["certSha"], !edited["certSha"].text.isEmpty {
            let pins = edited["certSha"].text.components(separatedBy: ",")
            guard pins.allSatisfy({ pin in
                let bytes = pin.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ":", with: "").utf8
                return bytes.count == 64 && bytes.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
            }) else { throw ClientFailure("profile_certificate_pin_invalid", "每个 SHA-256 指纹需要 64 位十六进制字符，可使用冒号分隔字节或逗号分隔多个指纹。") }
        }
        guard !validated["remarks"].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClientFailure("profile_validation_failed")
        }
        let db = try RuntimeDatabase(url: databaseURL, writable: commit)
        return try db.transaction(writable: commit) {
            guard var row = try db.query("SELECT * FROM ProfileItem WHERE IndexId = ?", [.text(id)]).first else {
                throw ClientFailure("profile_not_found")
            }
            if ProfileTransfer.isGroup(row) {
                // The group editor changes the name only. Older groups keep
                // their actual member filter in a separate SQLite table.
                let stored = try Self.profileWithLegacyGroup(row, db: db)
                let proto = Self.nodeDocument(from: stored)["protoExtra"].text
                _ = try XrayProfileGraph.memberFilter(try SettingsValue.parse(proto.isEmpty ? "{}" : proto))
                if edited["protoExtra"] != original["protoExtra"] {
                    _ = try XrayProfileGraph.memberFilter(try SettingsValue.parse(edited["protoExtra"].text))
                }
            }
            var assignments: [String] = []
            var bindings: [RuntimeDatabase.Value] = []
            for column in basic ? allColumns : ["Remarks"] {
                let key = column.prefix(1).lowercased() + column.dropFirst()
                guard original[key] != validated[key] else { continue }
                func stored(_ value: SettingsValue) throws -> RuntimeDatabase.Value {
                    switch value {
                    case .null: return .null
                    case .string(let text): return .text(text)
                    case .number(let n) where column == "Port":
                        guard let number = Int64(exactly: n), (1...65535).contains(number) else {
                            throw ClientFailure("profile_validation_failed")
                        }
                        return .integer(number)
                    default: throw ClientFailure("profile_validation_failed")
                    }
                }
                guard try stored(original[key]) == row[column] else { throw ClientFailure("profile_edit_conflict") }
                assignments.append(column + " = ?")
                let value = try stored(validated[key])
                row[column] = value
                bindings.append(value)
            }
            if commit, !assignments.isEmpty {
                _ = try db.query("UPDATE ProfileItem SET " + assignments.joined(separator: ", ") + " WHERE IndexId = ?",
                             bindings + [.text(id)])
            }
            return Self.nodeDocument(from: row)
        }
    }
}
