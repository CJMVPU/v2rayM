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
    private let journalURL: URL
    private let makeStore: () throws -> ProxyPreferencesStore
    public init(dataDirectory: URL, makeStore: @escaping () throws -> ProxyPreferencesStore = { try MacProxyPreferences() }) {
        journalURL = dataDirectory.appendingPathComponent("native-proxy-recovery.plist")
        self.makeStore = makeStore
    }
    public var needsRecovery: Bool { FileManager.default.fileExists(atPath: journalURL.path) }
    public func enable(port: Int) throws {
        guard !needsRecovery else { throw ClientFailure("proxy_recovery") }
        guard (1...65535).contains(port) else { throw ClientFailure("invalid_port") }
        let store = try makeStore()
        let original = try store.services()
        guard !original.isEmpty else { throw ClientFailure("proxy_no_services") }
        let changed = original.map { ProxyService(id: $0.id, configuration: Self.configuration($0.configuration, port: port)) }
        let records = try zip(original, changed).map { before, after in
            ProxyRecord(id: before.id, original: try Self.encode(before.configuration), applied: try Self.encode(after.configuration))
        }
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        // Write recovery information before committing any global change.
        let data = try PropertyListEncoder().encode(records)
        try data.write(to: journalURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
        do { try store.apply(changed) }
        catch {
            // Keep the journal even if apply only partially succeeded. The next off/quit can recover it.
            throw error
        }
    }
    /// Restore only fields still matching our applied settings. Never erase a later change by another app.
    @discardableResult public func restore() throws -> Bool {
        guard needsRecovery else { return false }
        let records = try PropertyListDecoder().decode([ProxyRecord].self, from: Data(contentsOf: journalURL))
        let store = try makeStore()
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
        var result = original
        for prefix in ["HTTP", "HTTPS", "SOCKS"] {
            result[prefix + "Enable"] = 1; result[prefix + "Proxy"] = "127.0.0.1"; result[prefix + "Port"] = port
        }
        result["ProxyAutoConfigEnable"] = 0; result["ProxyAutoDiscoveryEnable"] = 0
        result["ExceptionsList"] = ["localhost", "127.0.0.1", "::1", "*.local", "169.254/16"]
        result["ExcludeSimpleHostnames"] = 1
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
