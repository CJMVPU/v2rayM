import Foundation

/// Existing route exports name a node in outboundTag. A native rule also records
/// its database ID so renaming the node cannot change which peer gets the request.
struct RoutingTargets {
    static let builtins: Set<String> = ["proxy", "direct", "block"]
    let byID: [String: SettingsValue]
    let byName: [String: [SettingsValue]]

    init(nodes: [SettingsValue]) {
        byID = Dictionary(nodes.map { ($0["indexId"].text, $0) }, uniquingKeysWith: { first, _ in first })
        byName = Dictionary(grouping: nodes, by: { $0["remarks"].text })
    }

    init(db: RuntimeDatabase) throws {
        self.init(nodes: try db.query("SELECT IndexId, Remarks, ConfigType, CoreType FROM ProfileItem")
                    .map(NativeConfigurationStore.nodeDocument(from:)))
    }

    func node(id: String, name: String) throws -> SettingsValue {
        let node: SettingsValue?
        if !id.isEmpty {
            node = byID[id]
        } else {
            let matches = byName[name] ?? []
            guard matches.count <= 1 else {
                throw ClientFailure("routing_target_ambiguous", "路由出口“\(name)”对应多个同名节点，请在路由设置中重新选择。")
            }
            node = matches.first
        }
        guard let node else {
            throw ClientFailure("routing_target_missing", "找不到路由出口“\(name.isEmpty ? id : name)”，请在路由设置中重新选择。")
        }
        guard node["configType"].text != "custom", node["coreType"] == .null || node["coreType"].text == "xray" else {
            throw ClientFailure("routing_target_unsupported", "节点“\(node["remarks"].text)”不能作为 Xray 路由出口。")
        }
        return node
    }

    /// Most plans only use the three built-ins. Read the node catalog on the
    /// first node reference, then share the index across this whole transaction.
    static func binder(in db: RuntimeDatabase, requireValid: Bool) -> (SettingsValue) throws -> SettingsValue {
        var catalog: RoutingTargets?
        return { rule in
            try bind(rule, requireValid: requireValid) { id, name in
                if let catalog { return try catalog.node(id: id, name: name) }
                let targets = try RoutingTargets(db: db)
                catalog = targets
                return try targets.node(id: id, name: name)
            }
        }
    }

    private static func bind(_ rule: SettingsValue, requireValid: Bool,
                             resolve: (String, String) throws -> SettingsValue) throws -> SettingsValue {
        guard case .object(let fields) = rule else { return rule }
        func value(_ key: String) -> SettingsValue? {
            fields.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
        }
        let id = value("outboundProfileId")?.text ?? ""
        let name = value("outboundTag")?.text ?? "proxy"
        guard !id.isEmpty || !Self.builtins.contains(name) else { return rule }
        if !requireValid && !id.isEmpty { return rule }
        do {
            let target = try resolve(id, name)
            guard id.isEmpty else { return rule }
            var bound = rule
            let key = fields.keys.first { $0.caseInsensitiveCompare("outboundProfileId") == .orderedSame } ?? "outboundProfileId"
            bound[key] = target["indexId"]
            return bound
        } catch let error as ClientFailure where ["routing_target_missing", "routing_target_ambiguous", "routing_target_unsupported"].contains(error.code) {
            if requireValid && value("enabled") != .bool(false) { throw error }
            return rule
        }
    }
}
