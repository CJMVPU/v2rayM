import Foundation

extension NativeConfigurationStore {
    func copyProfiles(_ ids: [String]) throws {
        let db = try RuntimeDatabase(url: databaseURL, writable: true)
        let wanted = Set(ids)
        try db.transaction {
            let rows = try db.query("SELECT * FROM ProfileItem ORDER BY rowid").filter {
                guard case .text(let id) = $0["IndexId"] else { return false }
                return wanted.contains(id)
            }
            guard !rows.isEmpty else { throw ClientFailure("profile_not_found") }
            for var row in rows {
                if [.integer(2), .integer(13)].contains(row["ConfigType"]) { throw ClientFailure("custom_profile_copy_unavailable") }
                let originalID = row["IndexId"]!
                let newID = RuntimeDatabase.Value.text(UUID().uuidString)
                row["IndexId"] = newID
                row["IsSub"] = .integer(0)
                let name = Self.nodeDocument(from: row)["remarks"].text
                row["Remarks"] = .text(name + "-clone")
                try Self.insertProfile(row, into: db)
                if var group = try db.query("SELECT * FROM ProfileGroupItem WHERE IndexId=?", [originalID]).first {
                    group["IndexId"] = newID
                    try Self.insertProfile(group, into: db, group: true)
                }
            }
        }
    }

    func moveProfiles(_ ids: [String], group: String) throws {
        let db = try RuntimeDatabase(url: databaseURL, writable: true)
        try db.transaction {
            try Self.checkGroup(group, db)
            var found = false
            for id in Set(ids) {
                let updated = try db.query("""
                    UPDATE ProfileItem SET IsSub=CASE WHEN COALESCE(Subid,'')=? THEN IsSub ELSE 0 END, Subid=?
                    WHERE IndexId=? RETURNING IndexId
                    """, [.text(group), .text(group), .text(id)])
                if !updated.isEmpty { found = true }
            }
            guard found else { throw ClientFailure("profile_not_found") }
        }
    }

    private static func checkGroup(_ group: String, _ db: RuntimeDatabase) throws {
        if !group.isEmpty, try db.query("SELECT Id FROM SubItem WHERE Id=?", [.text(group)]).isEmpty { throw ClientFailure("subscription_not_found") }
    }

    func selectGroup(_ id: String) throws {
        try Self.checkGroup(id, RuntimeDatabase(url: databaseURL))
        var settings = try readSettings()
        settings["SubIndexId"] = .string(id)
        try writeSettings(settings)
    }

    func sortProfiles(group: String?, column: String, ascending: Bool) throws {
        let settings = try readSettings()
        let id = group ?? settings["SubIndexId"].text
        let numeric = ["configtype":"p.ConfigType", "port":"p.Port", "delayval":"x.Delay", "speedval":"x.Speed",
                       "todaydown":"s.TodayDown", "todayup":"s.TodayUp", "totaldown":"s.TotalDown", "totalup":"s.TotalUp", "def":"x.Sort"]
        let text = ["remarks":"p.Remarks", "address":"p.Address", "network":"p.Network", "streamsecurity":"p.StreamSecurity", "subremarks":"p.Subid", "ipinfo":"x.IpInfo"]
        let key = column.lowercased()
        let enabled = settings["GuiItem"]["EnableStatistics"].flag
        let needsTraffic = enabled && numeric[key]?.hasPrefix("s.") == true
        let order: String
        if let numeric = numeric[key] {
            order = numeric.hasPrefix("s.") && !enabled ? "COALESCE(NULL,0)" : "COALESCE(" + numeric + ",0)"
        } else if let field = text[key] { order = "COALESCE(" + field + ",'') COLLATE NOCASE" }
        else { throw ClientFailure("profile_sort_invalid") }
        let db = try RuntimeDatabase(url: databaseURL, writable: true)
        try db.transaction {
            let filter = id.isEmpty ? "" : "WHERE p.Subid=? "
            let invalidLast = ["delayval","speedval"].contains(key) ? "(" + order + " <= 0), " : ""
            let join = needsTraffic ? "LEFT JOIN " + Self.datedTrafficRelation + " s ON s.IndexId=p.IndexId " : ""
            let sql = "SELECT p.IndexId FROM ProfileItem p LEFT JOIN ProfileExItem x ON p.IndexId=x.IndexId "
                + join + filter + "ORDER BY " + invalidLast + order + (ascending ? " ASC" : " DESC") + ", p.rowid"
            var parameters: [RuntimeDatabase.Value] = needsTraffic ? [.integer(try Self.statisticsDayTicks(Date()))] : []
            if !id.isEmpty { parameters.append(.text(id)) }
            let rows = try db.query(sql, parameters)
            guard !rows.isEmpty else { throw ClientFailure("profile_sort_failed") }
            try Self.applyOrder(rows.compactMap { $0["IndexId"] }, db)
        }
    }

    func moveProfile(id: String, direction: String, position: Int) throws {
        let group = try readSettings()["SubIndexId"].text
        let db = try RuntimeDatabase(url: databaseURL, writable: true)
        try db.transaction {
            let sql = "SELECT p.IndexId FROM ProfileItem p LEFT JOIN ProfileExItem x ON x.IndexId=p.IndexId "
                + (group.isEmpty ? "" : "WHERE p.Subid=? ") + "ORDER BY COALESCE(x.Sort,0),p.rowid"
            var ids = try db.query(sql, group.isEmpty ? [] : [.text(group)]).compactMap { $0["IndexId"] }
            guard let from = ids.firstIndex(of: .text(id)) else { throw ClientFailure("profile_not_found") }
            let to: Int
            switch direction.lowercased() {
            case "top": to = 0
            case "bottom": to = ids.count - 1
            case "up": to = max(0, from - 1)
            case "down": to = min(ids.count - 1, from + 1)
            case "position": to = max(0, min(ids.count - 1, position > from ? position - 1 : position))
            default: throw ClientFailure("profile_move_invalid")
            }
            ids.insert(ids.remove(at: from), at: to)
            try Self.applyOrder(ids, db)
        }
    }

    private static func applyOrder(_ keys: [RuntimeDatabase.Value], _ db: RuntimeDatabase) throws {
        for (index, key) in keys.enumerated() {
            _ = try db.query("INSERT INTO ProfileExItem (IndexId,Sort) VALUES (?,?) ON CONFLICT(IndexId) DO UPDATE SET Sort=excluded.Sort",
                             [key, .integer(Int64(index + 1) * 10)])
        }
    }
}
