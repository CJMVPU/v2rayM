import Foundation
import Darwin
import SystemConfiguration

public struct TunDNSSettings: Equatable {
    public let interface: String
    public let resolver: String
    public init(interface: String, resolver: String) { self.interface = interface; self.resolver = resolver }
}

public protocol ManagedTunNetwork: AnyObject {
    func install(_ settings: TunDNSSettings?) throws
    func restore() throws
}

/// Temporary dynamic-store keys are owned by this SC session. macOS removes them
/// if the helper dies, without rewriting any saved network-service DNS settings.
public final class TemporaryTunDNS: ManagedTunNetwork {
    private var store: SCDynamicStore?
    private var key: CFString?
    public init() {}
    public func install(_ settings: TunDNSSettings?) throws {
        guard let settings else { return }
        guard store == nil else { throw HelperFailure("tun_dns_already_installed") }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while if_nametoindex(settings.interface) == 0 && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.025)
        }
        guard if_nametoindex(settings.interface) != 0 else { throw HelperFailure("native_tun_interface_not_ready") }
        guard let session = SCDynamicStoreCreate(nil, HelperIdentity.service as CFString, nil, nil) else {
            throw HelperFailure("tun_dns_store_unavailable")
        }
        let path = "State:/Network/Service/\(HelperIdentity.service)-\(UUID().uuidString)/DNS" as CFString
        let value: [String: Any] = [
            "ServerAddresses": [settings.resolver],
            "SupplementalMatchDomains": [""],
            "SupplementalMatchOrders": [0],
            "SupplementalMatchDomainsNoSearch": 1,
            "SearchOrder": 0,
        ]
        guard SCDynamicStoreAddTemporaryValue(session, path, value as CFDictionary) else {
            throw HelperFailure("tun_dns_install_failed")
        }
        store = session; key = path
    }
    static func removeOwnedResolver(remove: () -> Bool, status: () -> Int32) throws {
        // A missing key confirms cleanup. A configd error leaves ownership pending for retry.
        guard remove() || status() == kSCStatusNoKey else { throw HelperFailure("tun_dns_cleanup_failed") }
    }

    public func restore() throws {
        guard let store, let key else { return }
        try Self.removeOwnedResolver(remove: { SCDynamicStoreRemoveValue(store, key) }, status: SCError)
        self.key = nil; self.store = nil
    }
    deinit {
        if let store, let key { _ = SCDynamicStoreRemoveValue(store, key) }
        // Closing the SC session also removes every remaining temporary key.
    }
}
