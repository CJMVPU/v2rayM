import Foundation

extension NativeConfigurationStore {
    func removalIDs(_ requested: [String], subscription: String?) throws -> [String] {
        let db = try RuntimeDatabase(url: databaseURL)
        if let subscription {
            guard try !db.query("SELECT Id FROM SubItem WHERE Id=?", [.text(subscription)]).isEmpty else {
                throw ClientFailure("subscription_not_found")
            }
            return try db.query("SELECT IndexId FROM ProfileItem WHERE Subid=?", [.text(subscription)]).compactMap {
                if case .text(let id) = $0["IndexId"] { return id }
                return nil
            }
        }
        let wanted = Set(requested.filter { !$0.isEmpty })
        guard !wanted.isEmpty else { throw ClientFailure("profile_selection_required") }
        let found = try db.query("SELECT IndexId FROM ProfileItem").compactMap { row -> String? in
            guard case .text(let id) = row["IndexId"], wanted.contains(id) else { return nil }
            return id
        }
        guard !found.isEmpty else { throw ClientFailure("profile_not_found") }
        return found
    }

    func removeProfiles(_ ids: [String], subscription: String?) throws -> String {
        try commitProfileRemoval(ids, subscription: subscription)
        try finishProfileRemoval()
        return try readSettings()["IndexId"].text
    }

    func commitProfileRemoval(_ ids: [String], subscription: String?) throws {
        let db = try RuntimeDatabase(url: databaseURL, writable: true)
        let settings = try readSettings()
        try db.transaction {
            // Commit the new selection alongside deletion, then mirror it into the legacy JSON.
            // If the app exits between the two writes, the next startup completes the same edit.
            _ = try db.query("CREATE TABLE IF NOT EXISTS NativePendingSelection (Key TEXT PRIMARY KEY, Value TEXT NOT NULL)")
            for id in ids {
                try Self.deleteProfileRows(id, in: db)
            }
            if let subscription {
                _ = try db.query("DELETE FROM SubItem WHERE Id=?", [.text(subscription)])
                if settings["SubIndexId"].text == subscription {
                    let next = try db.query("SELECT Id FROM SubItem ORDER BY Sort DESC,rowid DESC LIMIT 1").first?["Id"] ?? .text("")
                    _ = try db.query("INSERT OR REPLACE INTO NativePendingSelection VALUES ('SubIndexId',?)", [next])
                }
            }
            if ids.contains(settings["IndexId"].text) {
                let next = try db.query("SELECT IndexId FROM ProfileItem ORDER BY rowid LIMIT 1").first?["IndexId"] ?? .text("")
                _ = try db.query("INSERT OR REPLACE INTO NativePendingSelection VALUES ('IndexId',?)", [next])
            }
        }
    }

    func finishProfileRemoval() throws {
        let db = try RuntimeDatabase(url: databaseURL, writable: true)
        try completePendingSelection(db)
        try? FileProfileImport.prune(databaseURL.deletingLastPathComponent(), db: db)
    }

    func completePendingSelection(_ db: RuntimeDatabase) throws {
        guard try !db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='NativePendingSelection'").isEmpty else { return }
        let pending = try db.query("SELECT Key,Value FROM NativePendingSelection")
        guard !pending.isEmpty else { return }
        var settings = try readSettings()
        for row in pending {
            guard case .text(let key) = row["Key"], ["IndexId", "SubIndexId"].contains(key),
                  case .text(let id) = row["Value"] else { throw ClientFailure("settings_recovery_required") }
            settings[key] = .string(id)
        }
        try writeSettings(settings)
        _ = try db.query("DELETE FROM NativePendingSelection")
    }

    static func deleteProfileRows(_ id: String, in db: RuntimeDatabase) throws {
        for table in ["ProfileExItem", "ServerStatItem", "ProfileGroupItem", "ProfileItem"] {
            _ = try db.query("DELETE FROM " + table + " WHERE IndexId=?", [.text(id)])
        }
    }

    func clearStatistics() throws {
        _ = try RuntimeDatabase(url: databaseURL, writable: true).query("DELETE FROM ServerStatItem")
    }
}
