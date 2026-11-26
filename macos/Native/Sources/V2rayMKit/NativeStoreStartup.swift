import Foundation

extension NativeConfigurationStore {
    private var settingsURL: URL { databaseURL.deletingLastPathComponent().appendingPathComponent("guiNConfig.json") }

    func readSettings() throws -> SettingsValue {
        try JSONDecoder().decode(SettingsValue.self, from: Data(contentsOf: settingsURL))
    }

    func writeSettings(_ settings: SettingsValue) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(settings).write(to: settingsURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
    }

    func builtin(_ name: String) throws -> SettingsValue {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "RuntimeDefaults") else {
            throw ClientFailure("runtime_defaults_missing")
        }
        return try JSONDecoder().decode(SettingsValue.self, from: Data(contentsOf: url))
    }

    public func initializeRuntimeStore(keepRecoveryJournal: Bool = false) throws {
        try recoverEdit(keepJournal: keepRecoveryJournal)
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            try completePendingSelection(RuntimeDatabase(url: databaseURL, writable: true))
        }
        let defaults = try builtin("settings")
        let exists = FileManager.default.fileExists(atPath: settingsURL.path)
        let original = exists ? try readSettings() : defaults
        guard case .object = original else { throw ClientFailure("settings_invalid") }
        func mergeDefaults(_ existing: SettingsValue, _ defaults: SettingsValue) -> SettingsValue {
            guard case .object(var fields) = existing, case .object(let base) = defaults else { return existing }
            for (key, value) in base {
                fields[key] = fields[key].map { mergeDefaults($0, value) } ?? value
            }
            return .object(fields)
        }
        var settings = mergeDefaults(original, defaults)
        if settings["Inbound"].items.isEmpty { settings["Inbound"] = defaults["Inbound"] }
        try prepareDatabase()
        let db = try RuntimeDatabase(url: databaseURL, writable: true)
        try db.transaction {
            if try db.query("SELECT Id FROM RoutingItem LIMIT 1").isEmpty {
                for (index, pair) in [("white","V4-绕过大陆(Whitelist)"), ("black","V4-黑名单(Blacklist)"), ("global","V4-全局(Global)")].enumerated() {
                    let compiled = try builtin(pair.0).items.map { item in
                        var rule = item
                        rule["id"] = .string(UUID().uuidString)
                        if rule["enabled"] == .null { rule["enabled"] = .bool(true) }
                        return rule
                    }
                    let sql = "INSERT INTO RoutingItem (Id, Remarks, Url, RuleSet, RuleNum, Enabled, Locked, Sort, IsActive) VALUES (?,?, '',?,?,1,0,?,?)"
                    _ = try db.query(sql, [.text(UUID().uuidString), .text(pair.1), .text(try SettingsValue.array(compiled).json()),
                                           .integer(Int64(compiled.count)), .integer(Int64(index+1)), .integer(index == 0 ? 1 : 0)])
                }
            } else {
                let legacyID = settings["RoutingBasicItem"]["RoutingIndexId"].text
                if !legacyID.isEmpty {
                    if try !db.query("SELECT Id FROM RoutingItem WHERE Id=?", [.text(legacyID)]).isEmpty {
                        _ = try db.query("UPDATE RoutingItem SET IsActive=(Id=?)", [.text(legacyID)])
                    }
                    settings["RoutingBasicItem"]["RoutingIndexId"] = .string("")
                }
                if try db.query("SELECT Id FROM RoutingItem WHERE IsActive=1 LIMIT 1").isEmpty {
                    _ = try db.query("UPDATE RoutingItem SET IsActive=1 WHERE rowid=(SELECT MIN(rowid) FROM RoutingItem)")
                }
            }
            try Self.migrateRoutingTargets(in: db)
            for table in ["DNSItem","FullConfigTemplateItem"] {
                if try db.query("SELECT Id FROM \(table) WHERE CoreType=2 LIMIT 1").isEmpty {
                    _ = try db.query("INSERT INTO \(table) (Id,Remarks,Enabled,CoreType) VALUES (?, 'V2ray',0,2)", [.text(UUID().uuidString)])
                }
            }
            let selected = settings["IndexId"].text
            if try db.query("SELECT IndexId FROM ProfileItem WHERE IndexId=?", [.text(selected)]).isEmpty {
                let first = try db.query("SELECT IndexId FROM ProfileItem ORDER BY rowid LIMIT 1").first
                if case let .text(id) = first?["IndexId"] { settings["IndexId"] = .string(id) }
                else { settings["IndexId"] = .string("") }
            }
            let group = settings["SubIndexId"].text
            if !group.isEmpty, try db.query("SELECT Id FROM SubItem WHERE Id=?", [.text(group)]).isEmpty { settings["SubIndexId"] = .string("") }
        }
        try FileProfileImport.prune(databaseURL.deletingLastPathComponent(), db: db)
        if !exists || settings != original { try writeSettings(settings) }
    }
}
