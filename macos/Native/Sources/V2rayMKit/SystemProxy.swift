import Foundation
import SystemConfiguration
import Security

public struct ProxyService {
    public var id: String
    public var configuration: [String: Any]
    public init(id: String, configuration: [String: Any]) { self.id = id; self.configuration = configuration }
}
public protocol ProxyPreferencesStore: AnyObject {
    func services() throws -> [ProxyService]
    func recoveryServices() throws -> [ProxyService]
    func apply(_ services: [ProxyService]) throws
}
extension ProxyPreferencesStore {
    public func recoveryServices() throws -> [ProxyService] { try services() }
}
/// A preferences session is created only in response to an explicit proxy change.
/// macOS owns any authorization dialog; the app never collects a password.
public final class MacProxyPreferences: ProxyPreferencesStore {
    private var authorization: AuthorizationRef?
    private let preferences: SCPreferences
    public init() throws {
        var reference: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &reference) == errAuthorizationSuccess, let reference else {
            throw ClientFailure("proxy_authorization")
        }
        authorization = reference
        guard let prefs = SCPreferencesCreateWithAuthorization(nil, "v2rayM" as CFString, nil, reference) else {
            AuthorizationFree(reference, []); authorization = nil
            throw ClientFailure("proxy_authorization")
        }
        preferences = prefs
        guard SCPreferencesLock(prefs, true) else { throw ClientFailure("proxy_authorization") }
    }
    deinit { SCPreferencesUnlock(preferences); if let authorization { AuthorizationFree(authorization, []) } }
    public func services() throws -> [ProxyService] {
        try services(includeDisabled: false)
    }
    public func recoveryServices() throws -> [ProxyService] {
        try services(includeDisabled: true)
    }
    private func services(includeDisabled: Bool) throws -> [ProxyService] {
        guard let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else {
            throw ClientFailure("proxy_no_services")
        }
        return services.compactMap { service in
            guard (includeDisabled || SCNetworkServiceGetEnabled(service)), let serviceID = SCNetworkServiceGetServiceID(service),
                  let protocolRef = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { return nil }
            return ProxyService(id: serviceID as String,
                configuration: SCNetworkProtocolGetConfiguration(protocolRef) as? [String: Any] ?? [:])
        }
    }
    public func apply(_ services: [ProxyService]) throws {
        for item in services {
            guard let service = SCNetworkServiceCopy(preferences, item.id as CFString),
                  let protocolRef = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies),
                  SCNetworkProtocolSetConfiguration(protocolRef, item.configuration as CFDictionary) else {
                throw ClientFailure("proxy_configuration")
            }
        }
        guard SCPreferencesCommitChanges(preferences), SCPreferencesApplyChanges(preferences) else {
            throw ClientFailure(SCError() == kSCStatusAccessError ? "proxy_authorization" : "proxy_configuration")
        }
    }
}

struct ProxyRecord: Codable {
    var id: String
    var original: Data
    var applied: Data
}
public actor SystemProxyController {
    public static let managedKeys = ["HTTPEnable", "HTTPProxy", "HTTPPort", "HTTPSEnable", "HTTPSProxy", "HTTPSPort",
        "SOCKSEnable", "SOCKSProxy", "SOCKSPort", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable",
        "ExceptionsList", "ExcludeSimpleHostnames"]
    private static let managedGroups = [["HTTPEnable", "HTTPProxy", "HTTPPort"],
        ["HTTPSEnable", "HTTPSProxy", "HTTPSPort"], ["SOCKSEnable", "SOCKSProxy", "SOCKSPort"],
        ["ProxyAutoConfigEnable"], ["ProxyAutoDiscoveryEnable"], ["ExceptionsList", "ExcludeSimpleHostnames"]]
    private var ownedEndpoints: ProxyEndpoints?
    private var serviceRevision: Data?
    private let readRevision: () -> Data?
    private let journalURL: URL
    private let makeStore: () throws -> ProxyPreferencesStore
    public init(dataDirectory: URL) {
        journalURL = dataDirectory.appendingPathComponent("native-proxy-recovery.plist")
        makeStore = { try MacProxyPreferences() }
        // Read-only preferences signature avoids taking an authorization lock on each status poll.
        let passive = SCPreferencesCreate(nil, "v2rayM network services" as CFString, nil)
        readRevision = {
            guard let passive else { return nil }
            SCPreferencesSynchronize(passive)
            return SCPreferencesGetSignature(passive) as Data?
        }
    }
    public init(dataDirectory: URL, makeStore: @escaping () throws -> ProxyPreferencesStore) {
        readRevision = { nil }
        journalURL = dataDirectory.appendingPathComponent("native-proxy-recovery.plist")
        self.makeStore = makeStore
    }
    private var hasJournal: Bool { FileManager.default.fileExists(atPath: journalURL.path) }
    public var isEnabled: Bool { ownedEndpoints != nil && hasJournal }
    /// An active session deliberately keeps a journal for normal off/quit.
    /// Only an unowned or failed transaction needs the recovery UI.
    public var needsRecovery: Bool { hasJournal && ownedEndpoints == nil }
    public func enable(port: Int) throws { try enable(endpoints: ProxyEndpoints(loopbackPort: port)) }

    public func enable(endpoints: ProxyEndpoints) throws {
        guard !hasJournal else { throw ClientFailure("proxy_recovery") }
        try Self.validate(endpoints)
        try enable(endpoints: endpoints, store: makeStore())
    }

    private func enable(endpoints: ProxyEndpoints, store: ProxyPreferencesStore) throws {
        let original = try store.services()
        guard !original.isEmpty else { throw ClientFailure("proxy_no_services") }
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        try enroll(original, endpoints: endpoints, preserving: [], store: store)
        ownedEndpoints = endpoints
        serviceRevision = nil
    }

    private static func validate(_ endpoints: ProxyEndpoints) throws {
        guard endpoints.preferredPort != nil else { throw ClientFailure("proxy_no_usable_listener") }
        guard [endpoints.http, endpoints.socks].compactMap({ $0 }).allSatisfy({ (1...65535).contains($0.port) }) else {
            throw ClientFailure("invalid_port")
        }
    }

    /// Journal the original values before applying to any new service, including mid-session additions.
    private func enroll(_ services: [ProxyService], endpoints: ProxyEndpoints, preserving records: [ProxyRecord],
                        store: ProxyPreferencesStore) throws {
        let changed = services.map { ProxyService(id: $0.id, configuration: Self.configuration($0.configuration, endpoints: endpoints)) }
        let added = try zip(services, changed).map { before, after in
            ProxyRecord(id: before.id, original: try Self.encode(before.configuration), applied: try Self.encode(after.configuration))
        }
        do {
            try PropertyListEncoder().encode(records + added).write(to: journalURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
            try store.apply(changed)
        } catch { ownedEndpoints = nil; throw error }
    }

    public func rebind(port: Int) throws { try rebind(endpoints: ProxyEndpoints(loopbackPort: port)) }

    public func rebind(endpoints: ProxyEndpoints) throws {
        try Self.validate(endpoints)
        guard let ownedEndpoints, hasJournal else { throw ClientFailure("proxy_recovery") }
        let revision = readRevision()
        if ownedEndpoints == endpoints, let revision, revision == serviceRevision { return }
        let store = try makeStore()
        let records = try loadJournal()
        let services = try store.services()
        let current = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0.configuration) })
        let drifted = try records.contains { record in
            guard let settings = current[record.id] else { return false }
            return !Self.fieldsEqual(settings, try Self.decode(record.applied), keys: Self.managedKeys)
        }
        if drifted || ownedEndpoints != endpoints {
            // Reuse the locked preferences session for detection, cleanup and rebinding.
            self.ownedEndpoints = nil
            serviceRevision = nil
            let changedElsewhere = try restore(records, store: store)
            guard !drifted && !changedElsewhere else { throw ClientFailure("proxy_changed") }
            try enable(endpoints: endpoints, store: store)
            return
        }
        let known = Set(records.map(\.id))
        let added = services.filter { !known.contains($0.id) }
        if !added.isEmpty { try enroll(added, endpoints: endpoints, preserving: records, store: store) }
        serviceRevision = revision
    }

    private func loadJournal() throws -> [ProxyRecord] {
        try PropertyListDecoder().decode([ProxyRecord].self, from: Data(contentsOf: journalURL))
    }

    /// Restore only fields still matching our applied settings. Never erase a later change by another app.
    @discardableResult public func restore() throws -> Bool {
        ownedEndpoints = nil
        serviceRevision = nil
        guard hasJournal else { return false }
        return try restore(loadJournal(), store: makeStore())
    }

    private func restore(_ records: [ProxyRecord], store: ProxyPreferencesStore) throws -> Bool {
        let current = try store.recoveryServices()
        var replacements: [ProxyService] = []
        var changedElsewhere = false
        for record in records {
            guard let service = current.first(where: { $0.id == record.id }) else {
                // Recovery enumerates disabled services too. A missing ID has been
                // deleted, so it cannot retain our proxy and must not block recovery.
                continue
            }
            let applied = try Self.decode(record.applied)
            let original = try Self.decode(record.original)
            var restored = service.configuration
            for keys in Self.managedGroups {
                if Self.fieldsEqual(service.configuration, original, keys: keys) { continue }
                guard Self.fieldsEqual(service.configuration, applied, keys: keys) else { changedElsewhere = true; continue }
                for key in keys { restored[key] = original[key] }
            }
            if !NSDictionary(dictionary: restored).isEqual(to: service.configuration) {
                replacements.append(ProxyService(id: record.id, configuration: restored))
            }
        }
        if !replacements.isEmpty { try store.apply(replacements) }
        try FileManager.default.removeItem(at: journalURL)
        return changedElsewhere
    }
    public static func configuration(_ original: [String: Any], port: Int) -> [String: Any] {
        configuration(original, endpoints: ProxyEndpoints(loopbackPort: port))
    }
    static func configuration(_ original: [String: Any], endpoints: ProxyEndpoints) -> [String: Any] {
        var result = original
        let settings = connectionProxyDictionary(endpoints)
        for prefix in ["HTTP", "HTTPS", "SOCKS"] {
            for suffix in ["Enable", "Proxy", "Port"] {
                let key = prefix + suffix
                result[key] = settings[key]
            }
        }
        result["ProxyAutoConfigEnable"] = 0; result["ProxyAutoDiscoveryEnable"] = 0
        result["ExceptionsList"] = ["localhost", "127.0.0.1", "::1", "*.local", "169.254/16"]
        result["ExcludeSimpleHostnames"] = 1
        return result
    }
    static func connectionProxyDictionary(_ endpoints: ProxyEndpoints?) -> [String: Any] {
        var result = [String: Any]()
        for (prefix, endpoint) in [("HTTP", endpoints?.http), ("HTTPS", endpoints?.http), ("SOCKS", endpoints?.socks)] {
            result[prefix + "Enable"] = endpoint == nil ? 0 : 1
            result[prefix + "Proxy"] = endpoint?.host
            result[prefix + "Port"] = endpoint?.port
        }
        return result
    }
    private static func fieldsEqual(_ lhs: [String: Any], _ rhs: [String: Any], keys: [String]) -> Bool {
        NSDictionary(dictionary: lhs.filter { keys.contains($0.key) })
            .isEqual(to: rhs.filter { keys.contains($0.key) })
    }
    private static func encode(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }
    private static func decode(_ value: Data) throws -> [String: Any] {
        guard let result = try PropertyListSerialization.propertyList(from: value, options: [], format: nil) as? [String: Any] else {
            throw ClientFailure("proxy_recovery")
        }
        return result
    }
}
