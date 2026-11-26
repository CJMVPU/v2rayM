import Foundation

extension NativeConfigurationStore {
    public func profileCatalog(group: String? = "", includeStatistics: Bool = false, search: String? = nil) throws -> [Profile] {
        let db = try RuntimeDatabase(url: databaseURL)
        let settings = try readSettings()
        let group = group ?? settings["SubIndexId"].text
        let statistics = includeStatistics && settings["GuiItem"]["EnableStatistics"].flag
        let totals = statistics ? "st.TotalUp, st.TotalDown, st.TodayUp, st.TodayDown" : "0 AS TotalUp, 0 AS TotalDown, 0 AS TodayUp, 0 AS TodayDown"
        let join = statistics ? "LEFT JOIN " + Self.datedTrafficRelation + " st ON st.IndexId = p.IndexId" : ""
        let filter = group.isEmpty ? "" : "WHERE p.Subid = ?"
        let sql = """
            SELECT p.IndexId, p.ConfigType, p.CoreType, p.Remarks, p.Address, p.Port, p.Network,
                   p.StreamSecurity, p.Subid, s.Remarks AS GroupName, x.Delay, x.Sort, x.Speed, x.IpInfo, \(totals)
            FROM ProfileItem p LEFT JOIN SubItem s ON s.Id = p.Subid
            LEFT JOIN ProfileExItem x ON x.IndexId = p.IndexId \(join) \(filter)
            ORDER BY COALESCE(x.Sort, 0), p.rowid
            """
        var parameters: [RuntimeDatabase.Value] = statistics ? [.integer(try Self.statisticsDayTicks(Date()))] : []
        if !group.isEmpty { parameters.append(.text(group)) }
        let rows = try db.query(sql, parameters).map { row in
            let value = Self.nodeDocument(from: row)
            let kind = value["configType"].text, port = Int(value["port"].text) ?? 0
            let configuredNetwork = value["network"].text
            let networks = ["raw", "kcp", "ws", "httpupgrade", "xhttp", "grpc"]
            let id = value["indexId"].text
            return Profile(indexId: id, remarks: value["remarks"].text, protocol: kind,
                           address: value["address"].text, port: port,
                           network: networks.contains(configuredNetwork) ? configuredNetwork : "raw",
                           streamSecurity: value["streamSecurity"].text, subscriptionId: value["subid"].text,
                           subscriptionName: value["groupName"] == .null ? nil : value["groupName"].text,
                           coreType: value["coreType"] == .null ? "xray" : value["coreType"].text,
                           delay: Int(value["delay"].text) ?? 0, isCurrent: id == settings["IndexId"].text,
                           totalUp: Double(value["totalUp"].text) ?? 0, totalDown: Double(value["totalDown"].text) ?? 0,
                           canTest: !["custom", "outbound", "policyGroup", "proxyChain"].contains(kind) && port > 0,
                           sort: Int(value["sort"].text) ?? 0, speed: Double(value["speed"].text) ?? 0,
                           ipInfo: value["ipInfo"] == .null ? nil : value["ipInfo"].text,
                           todayUp: Double(value["todayUp"].text) ?? 0, todayDown: Double(value["todayDown"].text) ?? 0)
        }
        return RuntimeSearch.filter(rows, pattern: search?.trimmingCharacters(in: .whitespacesAndNewlines),
                                    budget: .seconds(2)) { [$0.remarks, $0.address] }
    }
}

extension NativeConfigurationStore {
    func routeDocuments() throws -> [SettingsValue] {
        let db = try RuntimeDatabase(url: databaseURL)
        return try db.query("SELECT * FROM RoutingItem ORDER BY Sort").map { row in
            var document = Self.nodeDocument(from: row)
            for column in ["Enabled", "Locked", "IsActive"] {
                document[column.prefix(1).lowercased() + column.dropFirst()] = .bool(row[column] == .integer(1))
            }
            return document
        }
    }

    func profileObservations() throws -> [ProfileObservation] {
        let enabled = try readSettings()["GuiItem"]["EnableStatistics"].flag
        let db = try RuntimeDatabase(url: databaseURL)
        let query = enabled ? """
            WITH ids AS (SELECT IndexId FROM ProfileExItem UNION SELECT IndexId FROM ServerStatItem)
            SELECT ids.IndexId, x.Delay, s.TotalUp, s.TotalDown FROM ids
            LEFT JOIN ProfileExItem x ON x.IndexId=ids.IndexId LEFT JOIN ServerStatItem s ON s.IndexId=ids.IndexId
            """ : "SELECT IndexId, Delay, 0 AS TotalUp, 0 AS TotalDown FROM ProfileExItem"
        return try db.query(query).map { row in
            let value = Self.nodeDocument(from: row)
            return ProfileObservation(indexId: value["indexId"].text, delay: Int(value["delay"].text) ?? 0,
                                      totalUp: Double(value["totalUp"].text) ?? 0, totalDown: Double(value["totalDown"].text) ?? 0)
        }
    }
}
