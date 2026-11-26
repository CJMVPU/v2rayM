import Foundation

enum ConfigurationTable: String, Codable { case routes = "RoutingItem", dns = "DNSItem", templates = "FullConfigTemplateItem" }

/// A nil generation refers to the installation's original Geo pair.
struct RegionalRecovery: Codable {
    let generation: String?
    let runningNode: String?
}

extension NativeConfigurationStore {
    private struct EditSnapshot: Codable {
        let settings: SettingsValue
        let table: ConfigurationTable?
        let rows: [RuntimeDatabase.Row]
        let regional: RegionalRecovery?
        let regionalDNS: [RuntimeDatabase.Row]?
    }
    private var editJournal: URL { databaseURL.deletingLastPathComponent().appendingPathComponent("native-pending-edit.json") }

    func beginEdit(table: ConfigurationTable?, regional: RegionalRecovery? = nil) throws {
        guard !FileManager.default.fileExists(atPath: editJournal.path) else { throw ClientFailure("settings_recovery_required") }
        let db = try RuntimeDatabase(url: databaseURL)
        let snapshot = try db.transaction(writable: false) {
            let rows = try table.map { try db.query("SELECT * FROM " + $0.rawValue + " ORDER BY rowid") } ?? []
            let dns = regional == nil ? nil : try db.query("SELECT * FROM DNSItem ORDER BY rowid")
            return EditSnapshot(settings: try readSettings(), table: table, rows: rows, regional: regional, regionalDNS: dns)
        }
        try JSONEncoder().encode(snapshot).write(to: editJournal, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath:editJournal.path)
    }

    func finishEdit() throws { try FileManager.default.removeItem(at: editJournal) }

    private func pendingEdit() throws -> EditSnapshot? {
        guard FileManager.default.fileExists(atPath: editJournal.path) else { return nil }
        return try JSONDecoder().decode(EditSnapshot.self, from: Data(contentsOf: editJournal))
    }

    func interruptedRegionalNode() throws -> String? { try pendingEdit()?.regional?.runningNode }

    func recoverEdit(keepJournal: Bool = false) throws {
        guard let saved = try pendingEdit() else { return }
        if let table = saved.table {
            let db = try RuntimeDatabase(url: databaseURL, writable: true)
            func restore(_ table: ConfigurationTable, rows: [RuntimeDatabase.Row]) throws {
                _ = try db.query("DELETE FROM " + table.rawValue)
                for row in rows {
                    let keys = row.keys.sorted()
                    let columns = keys.map { "\"" + $0.replacingOccurrences(of:"\"",with:"\"\"") + "\"" }.joined(separator:",")
                    let params = Array(repeating:"?",count:keys.count).joined(separator:",")
                    _ = try db.query("INSERT INTO " + table.rawValue + " (" + columns + ") VALUES (" + params + ")", keys.compactMap { row[$0] })
                }
            }
            try db.transaction {
                try restore(table, rows: saved.rows)
                if let dns = saved.regionalDNS { try restore(.dns, rows: dns) }
            }
        }
        if let region = saved.regional {
            let data = databaseURL.deletingLastPathComponent().deletingLastPathComponent()
            try NativeGeoAssets.restoreGeneration(region.generation, in: data)
        }
        try writeSettings(saved.settings)
        if !keepJournal { try finishEdit() }
    }
}
