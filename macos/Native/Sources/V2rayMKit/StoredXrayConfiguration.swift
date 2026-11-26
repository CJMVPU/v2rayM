import Foundation

extension NativeConfigurationStore {
    /// All database-backed inputs come from the same read transaction, including nested
    /// routing references. Reading the JSON file in the store actor orders it with native edits.
    public func generateXrayConfiguration(nodeID: String, metricsPort: Int?, tunnelInterface: String? = nil,
                                          hasGlobalIPv6: Bool = false, at date: Date = Date(),
                                          preSocksPort: Int? = nil, diagnosticID: UUID? = nil) throws -> SettingsValue {
        try configurationSnapshot().generate(nodeID: nodeID, metricsPort: metricsPort, tunnelInterface: tunnelInterface,
            hasGlobalIPv6: hasGlobalIPv6, at: date, preSocksPort: preSocksPort, diagnosticID: diagnosticID)
    }

    func configurationSnapshot() throws -> XrayConfigurationSnapshot {
        let directory = databaseURL.deletingLastPathComponent()
        let settings = try readSettings()
        let db = try RuntimeDatabase(url: databaseURL)
        let snapshot = try db.transaction(writable: false) {
            let route = try db.query("SELECT * FROM RoutingItem ORDER BY COALESCE(IsActive, 0) DESC, rowid LIMIT 1").first
            let dns = try db.query("SELECT * FROM DNSItem WHERE CoreType = 2 LIMIT 1").first
            let template = try db.query("SELECT * FROM FullConfigTemplateItem WHERE CoreType = 2 LIMIT 1").first
            let rows = try db.query("SELECT * FROM ProfileItem ORDER BY rowid")
            var originals = [String: SettingsValue]()
            let nodes = try rows.map { row in
                let saved = Self.nodeDocument(from: row)
                if ProfileTransfer.isGroup(row), (Int(saved["configVersion"].text) ?? 0) < 3 {
                    originals[saved["indexId"].text] = saved
                    return Self.nodeDocument(from: try Self.profileWithLegacyGroup(row, db: db))
                }
                return saved
            }
            let linked = try db.query("SELECT Id, PrevProfile, NextProfile FROM SubItem WHERE COALESCE(PrevProfile,'') != '' OR COALESCE(NextProfile,'') != ''").map(Self.nodeDocument)
            return (route: route, dns: dns, template: template, nodes: nodes,
                    subscriptions: Dictionary(uniqueKeysWithValues: linked.map { ($0["id"].text, $0) }), originals: originals)
        }
        func document(_ row: RuntimeDatabase.Row?) -> SettingsValue {
            guard let row else { return .null }
            var fields = [String: SettingsValue]()
            for (key, field) in row {
                switch field {
                case .text(let text): fields[key] = .string(text)
                case .integer(let value) where ["Enabled", "AddProxyOnly", "UseSystemHosts"].contains(key):
                    fields[key] = .bool(value != 0)
                default: break
                }
            }
            return .object(fields)
        }
        let dns = document(snapshot.dns)
        let useHosts = dns["Enabled"].flag ? dns["UseSystemHosts"].flag : settings["SimpleDNSItem"]["UseSystemHosts"].flag
        let hosts = useHosts ? try Self.hostsFile() : [:]
        let source = XrayClientConfiguration(settings: settings, route: document(snapshot.route), customDNS: dns,
                                             template: document(snapshot.template), systemHosts: hosts, nodes: snapshot.nodes,
                                             subscriptions: snapshot.subscriptions, profileDirectory: directory)
        return XrayConfigurationSnapshot(configuration: source,
            nodesByID: Dictionary(snapshot.nodes.map { ($0["indexId"].text, $0) }, uniquingKeysWith: { first, _ in first }),
            legacyOriginals: snapshot.originals, logDirectory: directory.deletingLastPathComponent().appendingPathComponent("guiLogs"))
    }

    static func profileWithLegacyGroup(_ row: RuntimeDatabase.Row, db: RuntimeDatabase) throws -> RuntimeDatabase.Row {
        guard ProfileTransfer.isGroup(row), (Int(nodeDocument(from: row)["configVersion"].text) ?? 0) < 3,
              let id = row["IndexId"],
              let old = try db.query("SELECT * FROM ProfileGroupItem WHERE IndexId=?", [id]).first else { return row }
        var row = row
        let text = nodeDocument(from: row)["protoExtra"].text
        var extra = (try? SettingsValue.parse(text)) ?? .object([:])
        let legacy = nodeDocument(from: old)
        for key in ["ChildItems", "SubChildItems", "Filter", "MultipleLoad"] {
            let name = key.prefix(1).lowercased() + key.dropFirst()
            if legacy[name] != .null { extra[key] = legacy[name] }
        }
        row["ProtoExtra"] = .text(try extra.json())
        return row
    }

    private static func hostsFile() throws -> [String: String] {
        var hosts = [String: String]()
        for line in try String(contentsOfFile: "/etc/hosts", encoding: .utf8).components(separatedBy: .newlines) {
            let parts = line.prefix { $0 != "#" }.split(whereSeparator: \.isWhitespace)
            guard let ip = parts.first else { continue }
            for host in parts.dropFirst() where hosts[String(host)] == nil { hosts[String(host)] = String(ip) }
        }
        return hosts
    }
}

/// Shared only within an export or diagnostic request. Subsequent requests see new edits.
struct XrayConfigurationSnapshot {
    private(set) var configuration: XrayClientConfiguration
    private(set) var nodesByID: [String: SettingsValue]
    private(set) var legacyOriginals: [String: SettingsValue]
    let logDirectory: URL

    func original(_ id: String) -> SettingsValue? { legacyOriginals[id] ?? nodesByID[id] }

    func replacingProfile(_ id: String, with original: SettingsValue) -> Self {
        var next = self
        var node = original
        if legacyOriginals[id] != nil {
            next.legacyOriginals[id] = original
            node["protoExtra"] = nodesByID[id]?["protoExtra"] ?? .null
        }
        next.nodesByID[id] = node
        if let index = next.configuration.nodes.firstIndex(where: { $0["indexId"].text == id }) {
            next.configuration.nodes[index] = node
        }
        return next
    }

    func replacingSubscription(_ plan: SubscriptionReplacement) throws -> Self {
        var next = self
        // Existing rows retain their SQLite row order; inserts follow feed order.
        for change in plan.changes {
            next.nodesByID[change.id] = change.document
            next.legacyOriginals.removeValue(forKey: change.id)
        }
        next.configuration.nodes = configuration.nodes.map { next.nodesByID[$0["indexId"].text] ?? $0 }
        for change in plan.changes where change.original == nil {
            if let node = next.nodesByID[change.id] { next.configuration.nodes.append(node) }
        }
        if plan.removed.isEmpty { return next }
        return try next.removingProfiles(Set(plan.removed), subscription: nil)
    }

    func movingProfiles(_ ids: Set<String>, to group: String) -> Self {
        var next = self
        for index in next.configuration.nodes.indices {
            let id = next.configuration.nodes[index]["indexId"].text
            guard ids.contains(id), next.configuration.nodes[index]["subid"].text != group else { continue }
            next.configuration.nodes[index]["isSub"] = .bool(false)
            next.configuration.nodes[index]["subid"] = .string(group)
            next.nodesByID[id] = next.configuration.nodes[index]
            if next.legacyOriginals[id] != nil {
                next.legacyOriginals[id]?["subid"] = .string(group)
                next.legacyOriginals[id]?["isSub"] = .bool(false)
            }
        }
        return next
    }

    func removingProfiles(_ ids: Set<String>, subscription: String?) throws -> Self {
        var next = self
        next.configuration.nodes.removeAll { ids.contains($0["indexId"].text) }
        for id in ids {
            next.nodesByID.removeValue(forKey: id)
            next.legacyOriginals.removeValue(forKey: id)
        }
        if let subscription { next.configuration.subscriptions.removeValue(forKey: subscription) }
        // Keep saved explicit references intact. The user can remove or edit the referring group first.
        for node in next.configuration.nodes where ["policyGroup", "proxyChain"].contains(node["configType"].text) {
            let extra = try? SettingsValue.parse(node["protoExtra"].text)
            let explicit = extra?["ChildItems"].text.split(separator: ",") ?? []
            if explicit.contains(where: { ids.contains($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) {
                throw ClientFailure("profile_in_use_by_group", node["remarks"].text)
            }
        }
        return next
    }

    func generate(nodeID: String, metricsPort: Int?, tunnelInterface: String? = nil, hasGlobalIPv6: Bool = false,
                  at date: Date = Date(), preSocksPort: Int? = nil, diagnosticID: UUID? = nil) throws -> SettingsValue {
        guard let node = nodesByID[nodeID] else { throw ClientFailure("profile_not_found") }
        let effective: SettingsValue
        if let preSocksPort {
            guard node["configType"].text == "custom", (1...65535).contains(preSocksPort),
                  tunnelInterface == nil else { throw ClientFailure("mac_tun_generated_core_required") }
            effective = .object(["configType": .string("socks"), "coreType": .string("xray"),
                                 "address": .string("127.0.0.1"), "port": .number(Double(preSocksPort))])
        } else { effective = node }
        return try configuration.generate(for: effective, metricsPort: metricsPort,
                                   logDirectory: logDirectory, at: date, tunnelInterface: tunnelInterface,
                                          hasGlobalIPv6: hasGlobalIPv6, diagnosticID: diagnosticID)
    }
}
