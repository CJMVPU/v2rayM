import Foundation

extension NativeConfigurationStore {
    func maintenanceRemovalIDs(group: String?, duplicates: Bool, serving: String?) throws -> [String] {
        let db = try RuntimeDatabase(url: databaseURL)
        let settings = try readSettings()
        let group = group ?? settings["SubIndexId"].text
        let selected = settings["IndexId"].text
        let order = settings["GuiItem"]["KeepOlderDedupl"].flag ? " ASC" : " DESC"
        let query = duplicates ? "SELECT p.* FROM ProfileItem p"
            : "SELECT p.*, x.Delay FROM ProfileItem p LEFT JOIN ProfileExItem x ON x.IndexId=p.IndexId"
        let sql = query
            + (group.isEmpty ? "" : " WHERE p.Subid=?") + " ORDER BY p.rowid" + order
        let rows = try db.query(sql, group.isEmpty ? [] : [.text(group)])
        var seen = Set<RuntimeDatabase.Row>()
        var ids = [String]()
        for row in rows {
            guard case let .text(id) = row["IndexId"], id != selected, id != serving, ProfileTransfer.isOrdinary(row), ProfileTransfer.supportsXray(row) else { continue }
            // Opaque columns, full transport/protocol options and subscription ownership
            // can change how the node connects. Only its ID and display name are incidental.
            let remove = duplicates ? !seen.insert(row.filter { $0.key != "IndexId" && $0.key != "Remarks" }).inserted
                : row["Delay"] == .integer(-1)
            if remove { ids.append(id) }
        }
        return ids
    }

    func generateGroups(subscription id: String, regions: Bool) throws -> SettingsValue {
        guard !id.isEmpty else { throw ClientFailure("profile_group_empty") }
        let db = try RuntimeDatabase(url: databaseURL, writable: true)
        return try db.transaction {
            guard let subscription = try db.query("SELECT Remarks FROM SubItem WHERE Id=?", [.text(id)]).first else {
                throw ClientFailure("subscription_not_found")
            }
            let groupName = Self.nodeDocument(from: subscription)["remarks"].text + " - 策略组"
            let nodes = try db.query("SELECT * FROM ProfileItem WHERE Subid=? ORDER BY rowid", [.text(id)]).map(Self.nodeDocument)
            var ids: [SettingsValue] = []
            let exclusions = "剩余|过期|到期|重置|[Rr]emaining|[Ee]xpir|[Rr]eset"
            for (region, pattern) in regions ? Self.regionPatterns : [("", "")] {
                let filter = "^(?!.*(?:" + exclusions + ")).*" + (region.isEmpty ? "" : "(?:" + pattern + ").*") + "$"
                if regions {
                    let regex = try NSRegularExpression(pattern: filter)
                    guard nodes.contains(where: { member in
                        let name = member["remarks"].text
                        return XrayProfileGraph.canJoinSubscriptionGroup(member) &&
                            regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
                    }) else { continue }
                }
                let key = UUID().uuidString
                let extra: SettingsValue = .object(["MultipleLoad": .number(0), "GroupType": .string("PolicyGroup"),
                                                     "SubChildItems": .string(id), "Filter": .string(filter)])
                try Self.insertProfile(["IndexId": .text(key), "CoreType": .integer(2), "ConfigType": .integer(101),
                                        "ConfigVersion": .integer(4), "IsSub": .integer(0), "Subid": .text(id),
                                        "Network": .text("raw"), "Remarks": .text(groupName + (region.isEmpty ? "" : " - " + region)),
                                        "ProtoExtra": .text(try extra.json())], into: db)
                ids.append(.string(key))
            }
            guard let first = ids.first else { throw ClientFailure("profile_group_empty") }
            return regions ? .array(ids) : first
        }
    }

    private static let regionPatterns: [(String, String)] = [
        ("JP", #"日本|\b[Jj][Pp]\b|🇯🇵|[Jj]apan"#),
        ("US", #"美国|\b[Uu][Ss]\b|🇺🇸|[Uu]nited [Ss]tates|\b[Uu][Ss][Aa]\b"#),
        ("HK", #"香港|\b[Hh][Kk]\b|🇭🇰|[Hh]ong ?[Kk]ong"#),
        ("TW", #"台湾|台灣|\b[Tt][Ww]\b|🇹🇼|[Tt]aiwan"#),
        ("KR", #"韩国|\b[Kk][Rr]\b|🇰🇷|[Kk]orea"#),
        ("SG", #"新加坡|\b[Ss][Gg]\b|🇸🇬|[Ss]ingapore"#),
        ("DE", #"德国|\b[Dd][Ee]\b|🇩🇪|[Gg]ermany"#),
        ("FR", #"法国|\b[Ff][Rr]\b|🇫🇷|[Ff]rance"#),
        ("GB", #"英国|\b[Gg][Bb]\b|🇬🇧|[Uu]nited [Kk]ingdom|[Bb]ritain"#),
        ("CA", #"加拿大|🇨🇦|[Cc]anada"#),
        ("AU", #"澳大利亚|\b[Aa][Uu]\b|🇦🇺|[Aa]ustralia"#),
        ("RU", #"俄罗斯|\b[Rr][Uu]\b|🇷🇺|[Rr]ussia"#),
        ("BR", #"巴西|\b[Bb][Rr]\b|🇧🇷|[Bb]razil"#),
        ("IN", #"印度|🇮🇳|[Ii]ndia"#),
        ("VN", #"越南|\b[Vv][Nn]\b|🇻🇳|[Vv]ietnam"#),
        ("ID", #"印度尼西亚|\b[Ii][Dd]\b|🇮🇩|[Ii]ndonesia"#),
        ("MX", #"墨西哥|\b[Mm][Xx]\b|🇲🇽|[Mm]exico"#)
    ]
}
