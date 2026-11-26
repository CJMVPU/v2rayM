import CTunDevice
import Darwin
import Foundation
import TunShared

/// All calls are serialized on the owning XPC endpoint's queue.
public final class NetworkLease {
    public let handle: FileHandle
    public let name: String
    let gateway: TunnelNetworkPlan.Prefix
    let desired: [TunnelNetworkPlan.Prefix]
    private let dns: any ManagedTunNetwork
    typealias ChangeRoute = (Bool, TunnelNetworkPlan.Prefix) -> Int32
    private let openRoutes: () throws -> ChangeRoute
    private var installed = [TunnelNetworkPlan.Prefix]()
    public private(set) var active = false

    public convenience init(_ plan: TunnelNetworkPlan) throws {
        let (gateway, desired, localIPv6) = try plan.interfaceConfiguration()
        var buffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        let fd = v2m_open_tunnel(&buffer, Int32(plan.mtu), gateway.address, Int32(gateway.bits),
                                 localIPv6?.address, Int32(localIPv6?.bits ?? 0))
        guard fd >= 0 else { throw HelperFailure("tun_open_failed_\(errno)") }
        let tunnel = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        self.init(handle: tunnel, name: String(cString: buffer), gateway: gateway, desired: desired,
                  dns: TemporaryTunDNS(), openRoutes: {
            var index: UInt16 = 0
            let writer = v2m_open_route_writer(tunnel.fileDescriptor, &index)
            guard writer >= 0 else { throw HelperFailure("tun_route_open_failed_\(errno)") }
            let socket = FileHandle(fileDescriptor: writer, closeOnDealloc: true)
            return { add, route in
                v2m_change_route(socket.fileDescriptor, index, add, route.address, Int32(route.bits), gateway.address)
            }
        })
    }

    init(handle: FileHandle, name: String, gateway: TunnelNetworkPlan.Prefix, desired: [TunnelNetworkPlan.Prefix],
         dns: any ManagedTunNetwork, openRoutes: @escaping () throws -> ChangeRoute) {
        self.handle = handle
        self.name = name
        self.gateway = gateway
        self.desired = desired
        self.dns = dns
        self.openRoutes = openRoutes
    }

    public func activate(cancelled: () -> Bool) throws {
        guard !active, installed.isEmpty else { throw HelperFailure("tunnel_already_active") }
        if !desired.isEmpty {
            let changeRoute = try openRoutes()
            for route in desired {
                if cancelled() { throw HelperFailure("session_disconnected") }
                let error = changeRoute(true, route)
                guard error == 0 else { throw HelperFailure("tun_route_add_failed_\(error)") }
                installed.append(route)
            }
        }
        guard !cancelled() else { throw HelperFailure("session_disconnected") }
        try dns.install(TunDNSSettings(interface: name, resolver: gateway.address))
        guard !cancelled() else { throw HelperFailure("session_disconnected") }
        active = true
    }

    public func restore() throws {
        if !installed.isEmpty, let changeRoute = try? openRoutes() {
            var remaining = [TunnelNetworkPlan.Prefix]()
            for route in installed.reversed() {
                let error = changeRoute(false, route)
                if error != 0 && error != ESRCH { remaining.append(route) }
            }
            installed = remaining.reversed()
        }
        try dns.restore()
        guard installed.isEmpty else { throw HelperFailure("tun_route_cleanup_unconfirmed") }
        active = false
    }
}
