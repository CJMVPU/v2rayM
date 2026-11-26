import Foundation

extension NativeConfigurationStore {
    func subscription(id: String) throws -> Subscription {
        let db = try RuntimeDatabase(url: databaseURL)
        return try Self.subscription(id: id, in: db)
    }

    static func subscription(id: String, in db: RuntimeDatabase) throws -> Subscription {
        guard let record = try db.query("SELECT * FROM SubItem WHERE Id=?", [.text(id)]).first else {
            throw ClientFailure("subscription_not_found")
        }
        return try subscription(record)
    }

    func subscriptions() throws -> [Subscription] {
        let db = try RuntimeDatabase(url: databaseURL)
        return try db.query("SELECT * FROM SubItem ORDER BY Sort,rowid").map(Self.subscription)
    }

    static func subscription(_ row: RuntimeDatabase.Row) throws -> Subscription {
        var value = nodeDocument(from: row)
        for key in ["remarks", "url", "userAgent"] where value[key] == .null { value[key] = .string("") }
        for key in ["sort", "autoUpdateInterval", "updateTime"] where value[key] == .null { value[key] = .number(0) }
        value["enabled"] = .bool(row["Enabled"] != .integer(0))
        if case .integer(let code) = row["CustomCoreType"] { value["customCoreType"] = .string(code == 2 ? "xray" : String(code)) }
        return try JSONDecoder().decode(Subscription.self, from: JSONEncoder().encode(value))
    }

    func saveSubscription(_ input: SettingsValue, id: String?) throws -> Subscription {
        let name = input["remarks"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = input["url"].text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ClientFailure("subscription_name_required") }
        if !url.isEmpty { _ = try SubscriptionDownload.address(url) }
        _ = try SubscriptionDownload.headers(input["requestHeaders"].text)
        let db = try RuntimeDatabase(url: databaseURL, writable: true)
        let key = id ?? UUID().uuidString
        return try db.transaction {
            if id == nil {
                _ = try db.query("INSERT INTO SubItem (Id,Enabled,UserAgent,Sort,AutoUpdateInterval,UpdateTime) VALUES (?,1,'',0,0,0)", [.text(key)])
            }
            let old = try db.query("SELECT * FROM SubItem WHERE Id=?", [.text(key)]).first
            guard let old else { throw ClientFailure("subscription_not_found") }
            var changes: RuntimeDatabase.Row = ["Remarks": .text(name), "Url": .text(url)]
            for col in ["MoreUrl","UserAgent","RequestHeaders","Filter","ConvertTarget","Memo","PrevProfile","NextProfile"] {
                if case .string(let text) = input[col.prefix(1).lowercased() + col.dropFirst()] { changes[col] = .text(text) }
            }
            if case .bool(let enabled) = input["enabled"] { changes["Enabled"] = .integer(enabled ? 1 : 0) }
            for col in ["AutoUpdateInterval","Sort","PreSocksPort"] {
                let field = input[col.prefix(1).lowercased() + col.dropFirst()]
                if field != .null {
                    guard let n = Int64(field.text) else { throw ClientFailure("subscription_invalid_input") }
                    changes[col] = .integer(col == "AutoUpdateInterval" ? max(0,n) : n)
                }
            }
            if case .object(let fields) = input {
                if fields["preSocksPort"] == .null { changes["PreSocksPort"] = .null }
                if let field = fields["customCoreType"] {
                    if field == .null { changes["CustomCoreType"] = .null }
                    else if field.text.lowercased() == "xray" || field.text == "2" { changes["CustomCoreType"] = .integer(2) }
                    else if old["CustomCoreType"] != Int64(field.text).map(RuntimeDatabase.Value.integer) { throw ClientFailure("xray_only_profile_required") }
                }
            }
            let columns = changes.keys.sorted()
            _ = try db.query("UPDATE SubItem SET " + columns.map { $0 + "=?" }.joined(separator: ",") + " WHERE Id=?",
                             columns.compactMap { changes[$0] } + [.text(key)])
            guard let current = try db.query("SELECT * FROM SubItem WHERE Id=?", [.text(key)]).first else { throw ClientFailure("subscription_not_found") }
            return try Self.subscription(current)
        }
    }
}

enum SubscriptionDownload {
    static func address(_ text: String) throws -> URL {
        guard let url = URL(string: text), ["http","https"].contains(url.scheme?.lowercased()),
              let host = url.host, !host.isEmpty else { throw ClientFailure("subscription_invalid_url") }
        return url
    }

    static func headers(_ text: String) throws -> [String: String] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [:] }
        guard let values = try? JSONDecoder().decode([String:String].self, from: Data(text.utf8)) else {
            throw ClientFailure("subscription_invalid_headers")
        }
        let symbols = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var names = Set<String>()
        for (name, value) in values {
            guard !name.isEmpty, name.unicodeScalars.allSatisfy(symbols.contains),
                  value.unicodeScalars.allSatisfy({ $0.value == 9 || !CharacterSet.controlCharacters.contains($0) }),
                  names.insert(name.lowercased()).inserted else { throw ClientFailure("subscription_invalid_headers") }
        }
        return values
    }
}

extension SubscriptionDownload {
    static func fetch(_ subscription: Subscription, proxyEndpoints: ProxyEndpoints?, converter: String) async throws -> [RuntimeDatabase.Row] {
        var addresses = [subscription.url]
        if let target = subscription.convertTarget, !target.isEmpty {
            guard !converter.isEmpty, converter.contains("{0}"),
                  let encoded = subscription.url.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
                  var parts = URLComponents(string: converter.replacingOccurrences(of: "{0}", with: encoded)) else {
                throw ClientFailure("subscription_converter_unavailable")
            }
            var query = parts.queryItems ?? []
            if !query.contains(where: { $0.name == "target" }) { query.append(URLQueryItem(name: "target", value: target)) }
            parts.queryItems = query
            guard let converted = parts.string else { throw ClientFailure("subscription_invalid_url") }
            addresses = [converted]
        } else {
            addresses += (subscription.moreUrl ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        var rows = [RuntimeDatabase.Row]()
        for address in addresses {
            var request = URLRequest(url: try self.address(address))
            request.timeoutInterval = 30
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            if !subscription.userAgent.isEmpty { request.setValue(subscription.userAgent, forHTTPHeaderField: "User-Agent") }
            for (key, value) in try headers(subscription.requestHeaders ?? "") { request.setValue(value, forHTTPHeaderField: key) }
            let content: String
            do { content = try await download(request, proxyEndpoints: proxyEndpoints) }
            catch {
                try Task.checkCancellation()
                guard proxyEndpoints != nil else { throw error }
                content = try await download(request, proxyEndpoints: nil)
            }
            rows += try ShareLinkImport.decode(content, subscriptionName: subscription.remarks)
        }
        if let pattern = subscription.filter, !pattern.isEmpty {
            let regex = try NSRegularExpression(pattern: pattern)
            rows = rows.filter { row in
                guard case .text(let name) = row["Remarks"] else { return false }
                return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
            }
        }
        guard !rows.isEmpty else { throw ClientFailure("profile_import_empty") }
        return rows
    }

    static func download(_ request: URLRequest, proxyEndpoints: ProxyEndpoints?) async throws -> String {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.connectionProxyDictionary = SystemProxyController.connectionProxyDictionary(proxyEndpoints)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (file, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let text = String(data: try Data(contentsOf: file), encoding: .utf8) else { throw ClientFailure("subscription_download_failed") }
        return text
    }
}

/// A refresh chooses IDs once so the candidate graph and the committed rows have
/// identical identities, including for newly imported group members.
struct SubscriptionReplacement {
    struct Change {
        let id: String
        let fields: RuntimeDatabase.Row
        let original: RuntimeDatabase.Row?

        var document: SettingsValue {
            NativeConfigurationStore.nodeDocument(from: (original ?? [:]).merging(fields) { _, new in new })
        }
    }

    let subscription: Subscription
    let previous: [RuntimeDatabase.Row]
    let changes: [Change]
    let removed: [String]
}

extension NativeConfigurationStore {
    func replaceSubscription(_ subscription: Subscription, rows: [RuntimeDatabase.Row], serving: String?) async throws {
        try await withSubscriptionReplacement(subscription, rows: rows, serving: serving) { plan in
            try await self.commitSubscription(plan)
        }
    }

    /// Materialized configs are content-addressed. Keep both generations alive
    /// until Xray and SQLite have accepted the replacement or restored the old one.
    func withSubscriptionReplacement(_ subscription: Subscription, rows: [RuntimeDatabase.Row], serving: String?,
                                     apply: @Sendable (SubscriptionReplacement) async throws -> Void) async throws {
        try Task.checkCancellation()
        let settings = try readSettings()
        let directory = databaseURL.deletingLastPathComponent()
        let db = try RuntimeDatabase(url: databaseURL, writable: true)
        defer { try? FileProfileImport.prune(directory, db: db) }
        let previous = try subscriptionRows(subscription, db: db)
        let index = SubscriptionMatchIndex(previous: previous, incoming: rows)
        let ids = index.matches.map { existing -> String in
            if case .text(let id) = existing?["IndexId"] { return id }
            return UUID().uuidString
        }
        let imported = try ProfileTransfer.rekey(rows, ids: ids, subscription: subscription.id)
        var changes = [SubscriptionReplacement.Change]()
        for i in imported.indices {
            try Task.checkCancellation()
            var item = imported[i]
            if FileProfileImport.isFile(item) {
                try FileProfileImport.materialize(&item, directory: directory)
                if item["ConfigType"] == .integer(2) { item["PreSocksPort"] = subscription.preSocksPort.map { .integer(Int64($0)) } ?? .null }
            } else if !ProfileTransfer.isGroup(item) {
                _ = try XrayOutbound(node: Self.nodeDocument(from: item), config: settings).build()
            }
            item["Subid"] = .text(subscription.id)
            item["IsSub"] = .integer(1)
            item["ConfigVersion"] = .integer(4)
            if index.matches[i] != nil {
                for key in ["CoreType","Username","Password","Sni","Alpn","Fingerprint","PublicKey","ShortId","SpiderX",
                            "Mldsa65Verify","EchConfigList","VerifyPeerCertByName","CertSha","Cert","Finalmask","AllowInsecure"] where item[key] == nil {
                    item[key] = .null
                }
            }
            changes.append(.init(id: ids[i], fields: item, original: index.matches[i]))
        }
        let removed = index.unmatched.compactMap { row -> String? in
            guard case .text(let id) = row["IndexId"], id != settings["IndexId"].text, id != serving else { return nil }
            return id
        }
        try await apply(SubscriptionReplacement(subscription: subscription, previous: previous, changes: changes, removed: removed))
    }

    private func subscriptionRows(_ subscription: Subscription, db: RuntimeDatabase) throws -> [RuntimeDatabase.Row] {
        guard let record = try db.query("SELECT * FROM SubItem WHERE Id=?", [.text(subscription.id)]).first,
              try Self.subscription(record) == subscription else { throw ClientFailure("subscription_edit_conflict") }
        return try db.query("SELECT * FROM ProfileItem WHERE Subid=? AND IsSub=1 ORDER BY rowid", [.text(subscription.id)])
    }

    func commitSubscription(_ plan: SubscriptionReplacement) throws {
        let db = try RuntimeDatabase(url: databaseURL, writable: true)
        try db.transaction {
            guard try subscriptionRows(plan.subscription, db: db) == plan.previous else {
                throw ClientFailure("subscription_edit_conflict")
            }
            for change in plan.changes {
                try Task.checkCancellation()
                if change.original != nil {
                    let keys = change.fields.keys.sorted()
                    _ = try db.query("UPDATE ProfileItem SET " + keys.map { $0 + "=?" }.joined(separator: ",") + " WHERE IndexId=?",
                                     keys.compactMap { change.fields[$0] } + [.text(change.id)])
                } else {
                    try Self.insertProfile(change.fields, into: db)
                }
            }
            for id in plan.removed { try Self.deleteProfileRows(id, in: db) }
            _ = try db.query("UPDATE SubItem SET UpdateTime=? WHERE Id=?", [.integer(Int64(Date().timeIntervalSince1970)), .text(plan.subscription.id)])
            try Task.checkCancellation()
        }
    }
}
