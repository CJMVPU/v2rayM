import Foundation

enum CoreConfigurationProfile {
    case dns, template
    var table: ConfigurationTable { self == .dns ? .dns : .templates }
    var columns: [String] {
        if self == .dns {
            return ["Remarks", "Enabled", "UseSystemHosts", "NormalDNS", "TunDNS", "DomainStrategy4Freedom", "DomainDNSAddress"]
        }
        return ["Remarks", "Enabled", "Config", "TunConfig", "AddProxyOnly", "ProxyDetour"]
    }
    var invalid: String { self == .dns ? "dns_profile_invalid" : "core_template_invalid" }

    func validate(_ input: SettingsValue) throws {
        guard self == .dns else { return }
        guard ["", "AsIs", "UseIP", "UseIPv4v6", "UseIPv6v4", "UseIPv4", "UseIPv6"].contains(input["domainStrategy4Freedom"].text) else {
            throw ClientFailure(invalid)
        }
        for key in ["normalDNS", "tunDNS"] {
            let content = input[key].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if content.hasPrefix("{") {
                guard let document = try? SettingsValue.parse(content), document["servers"] != .null else { throw ClientFailure(invalid) }
            } else if content.contains("{") || content.contains("}") { throw ClientFailure(invalid) }
        }
    }
}

extension NativeConfigurationStore {
    func coreConfigurationProfiles(_ kind: CoreConfigurationProfile) throws -> [SettingsValue] {
        let db = try RuntimeDatabase(url: databaseURL)
        return try db.query("SELECT * FROM " + kind.table.rawValue + " WHERE CoreType=2 ORDER BY rowid").map { row in
            var document = Self.nodeDocument(from: row)
            for column in ["Enabled", "UseSystemHosts", "AddProxyOnly"] where kind.columns.contains(column) {
                let key = column.prefix(1).lowercased() + column.dropFirst()
                if column == "AddProxyOnly", row[column] == .null { document[key] = .null }
                else { document[key] = .bool(row[column] == .integer(1)) }
            }
            return document
        }
    }

    func saveCoreConfigurationProfile(_ kind: CoreConfigurationProfile, input: SettingsValue) throws -> SettingsValue {
        try kind.validate(input)
        let db = try RuntimeDatabase(url: databaseURL, writable: true)
        try db.transaction {
            guard let row = try db.query("SELECT Id FROM " + kind.table.rawValue + " WHERE CoreType=2 ORDER BY rowid LIMIT 1").first,
                  let id = row["Id"] else { throw ClientFailure(kind.invalid) }
            var fields = [String]()
            var values = [RuntimeDatabase.Value]()
            for column in kind.columns {
                let key = column.prefix(1).lowercased() + column.dropFirst()
                let value = input[key]
                if column == "Remarks" && value == .null { continue }
                fields.append(column + "=?")
                switch value {
                case .null where column == "Enabled" || column == "UseSystemHosts": values.append(.integer(0))
                case .null: values.append(.null)
                case .bool(let flag): values.append(.integer(flag ? 1 : 0))
                case .string(let text): values.append(.text(text))
                default: throw ClientFailure(kind.invalid)
                }
            }
            _ = try db.query("UPDATE " + kind.table.rawValue + " SET " + fields.joined(separator: ",") + " WHERE Id=?", values + [id])
        }
        return .object(["coreType": .string("Xray")])
    }
}
