import Foundation

public enum RoutingRuleEdit: Sendable {
    case save(SettingsValue, append: Bool)
    case move(id: String, direction: String, position: Int)
    case delete(id: String)
}

extension NativeConfigurationStore {
    private func routeRow(_ id: String, in db: RuntimeDatabase) throws -> RuntimeDatabase.Row {
        guard let row = try db.query("SELECT * FROM RoutingItem WHERE Id=?", [.text(id)]).first else {
            throw ClientFailure("routing_profile_not_found")
        }
        return row
    }

    private static func rules(_ input: SettingsValue, assignIDs: Bool) throws -> [SettingsValue] {
        guard case .array(let items) = input else { throw ClientFailure("routing_rules_json_invalid") }
        var seen = Set<String>()
        return try items.map { item in
            var fields = try StoredRoutingRule.fields(of: item, validate: assignIDs)
            if assignIDs {
                let id = fields["id"]?.text ?? ""
                if id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !seen.insert(id).inserted {
                    fields["id"] = .string(UUID().uuidString)
                }
            }
            if fields["enabled"] == nil { fields["enabled"] = .bool(true) }
            return .object(fields)
        }
    }

    static func parseRoutingRules(_ text: String) throws -> SettingsValue {
        guard let value = try? SettingsValue.parse(text), case .array = value else {
            throw ClientFailure("routing_rules_json_invalid")
        }
        return value
    }

    private func storedRules(_ row: RuntimeDatabase.Row) throws -> [SettingsValue] {
        guard case .text(let text) = row["RuleSet"], !text.isEmpty else { return [] }
        return try Self.rules(Self.parseRoutingRules(text), assignIDs: false)
    }

    /// Preserve malformed or unresolved legacy records for correction in the editor.
    /// Only uniquely bound rules are changed, including rules in inactive profiles.
    static func migrateRoutingTargets(in db: RuntimeDatabase) throws {
        let bind = RoutingTargets.binder(in: db, requireValid: false)
        for row in try db.query("SELECT Id, RuleSet FROM RoutingItem") {
            guard case .text(let text) = row["RuleSet"], case .array(let rules) = try? SettingsValue.parse(text),
                  let id = row["Id"] else { continue }
            let bound = try rules.map(bind)
            if bound != rules {
                _ = try db.query("UPDATE RoutingItem SET RuleSet=? WHERE Id=?", [.text(try SettingsValue.array(bound).json()), id])
            }
        }
    }

    func routingRules(id: String) throws -> [SettingsValue] {
        try storedRules(routeRow(id, in: RuntimeDatabase(url: databaseURL)))
    }

    func routingSource(id: String) throws -> String {
        let row = try routeRow(id, in: RuntimeDatabase(url: databaseURL))
        guard case .text(let url) = row["Url"] else { throw ClientFailure("routing_url_invalid") }
        return url
    }

    func saveRoute(_ input: SettingsValue, id: String? = nil) throws -> String {
        let name = input["remarks"].text
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientFailure("routing_name_required") }
        guard ["", "AsIs", "IPIfNonMatch", "IPOnDemand"].contains(input["domainStrategy"].text) else {
            throw ClientFailure("routing_strategy_invalid")
        }
        let source: SettingsValue
        switch input["ruleSet"] {
        case .array(let items): source = .array(items)
        case .string(let text):
            source = try text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .array([]) : Self.parseRoutingRules(text)
        case .null: source = .array([])
        default: throw ClientFailure("routing_rules_json_invalid")
        }
        let inputRules = try Self.rules(source, assignIDs: true)
        let db = try RuntimeDatabase(url: databaseURL, writable: true)
        let key = id ?? UUID().uuidString
        try db.transaction {
            let rules = try inputRules.map(RoutingTargets.binder(in: db, requireValid: true))
            if let id { _ = try routeRow(id, in: db) }
            else {
                let sort = Int64(input["sort"].text) ?? 0
                _ = try db.query("INSERT INTO RoutingItem (Id,IsActive,Sort) SELECT ?,0,CASE WHEN ?>0 THEN ? ELSE COALESCE(MAX(Sort),0)+1 END FROM RoutingItem",
                                 [.text(key), .integer(sort), .integer(sort)])
            }
            let fields: [RuntimeDatabase.Value] = [.text(name), .text(input["url"].text), .integer(input["enabled"] == .bool(false) ? 0 : 1),
                .integer(input["locked"].flag ? 1 : 0), .text(input["customIcon"].text), .text(input["domainStrategy"].text),
                .text(try SettingsValue.array(rules).json()), .integer(Int64(rules.count)), .text(key)]
            _ = try db.query("UPDATE RoutingItem SET Remarks=?,Url=?,Enabled=?,Locked=?,CustomIcon=?,DomainStrategy=?,RuleSet=?,RuleNum=? WHERE Id=?", fields)
        }
        return key
    }

    func selectRoute(_ id: String, delete: Bool) throws {
        let db = try RuntimeDatabase(url: databaseURL, writable: true)
        try db.transaction {
            let row = try routeRow(id, in: db)
            if delete {
                _ = try db.query("DELETE FROM RoutingItem WHERE Id=?", [.text(id)])
                if row["IsActive"] == .integer(1) {
                    _ = try db.query("UPDATE RoutingItem SET IsActive=(rowid=(SELECT rowid FROM RoutingItem ORDER BY Sort,rowid LIMIT 1))")
                }
            } else {
                _ = try db.query("UPDATE RoutingItem SET IsActive=(Id=?)", [.text(id)])
            }
        }
    }

    func editRules(_ routeID: String, edit: RoutingRuleEdit) throws {
        let db = try RuntimeDatabase(url: databaseURL, writable: true)
        try db.transaction {
            let row = try routeRow(routeID, in: db)
            var items = try storedRules(row)
            switch edit {
            case .save(let value, let append):
                guard case .array(let incoming) = value else { throw ClientFailure("routing_rules_json_invalid") }
                items = try Self.rules(.array((append ? items : []) + incoming), assignIDs: true)
                    .map(RoutingTargets.binder(in: db, requireValid: true))
            case .delete(let id):
                guard let index = items.firstIndex(where: { $0["id"].text == id }) else { throw ClientFailure("routing_rule_not_found") }
                items.remove(at: index)
            case .move(let id, let direction, let position):
                guard let index = items.firstIndex(where: { $0["id"].text == id }) else { throw ClientFailure("routing_rule_not_found") }
                let destination: Int
                switch direction.lowercased() {
                case "top": destination = 0
                case "bottom": destination = items.count - 1
                case "up": destination = max(0, index - 1)
                case "down": destination = min(items.count - 1, index + 1)
                case "position" where (0...items.count).contains(position): destination = position > index ? position - 1 : position
                default: throw ClientFailure("routing_rule_move_failed")
                }
                if index == destination { return }
                items.insert(items.remove(at: index), at: destination)
            }
            _ = try db.query("UPDATE RoutingItem SET RuleSet=?,RuleNum=? WHERE Id=?",
                             [.text(try SettingsValue.array(items).json()), .integer(Int64(items.count)), .text(routeID)])
        }
    }
}
