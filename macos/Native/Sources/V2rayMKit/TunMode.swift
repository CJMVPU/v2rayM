import Darwin
import Foundation
import V2rayMDomain
import V2rayMApplication

public struct MacTunStatus: Codable, Sendable, Equatable {
    public var platformSupported: Bool
    public var helperAvailable: Bool
    public var helperCode: String
    public var helperState: String
    public var enabled: Bool
    public var supportedCores: [String]
    public var coreSource: String
    public var runtimeState: String
    public var privilegedCoreProcessIds: [Int]

    public var confirmedInactiveSessionID: UUID? = nil
    public var tunnelForwardingPID: Int? = nil
    public var tunnelProcessIDs: [Int] { tunnelForwardingPID.map { [$0] } ?? privilegedCoreProcessIds }
    public var isRunning: Bool { enabled && runtimeState == "running" && !tunnelProcessIDs.isEmpty }
    public var domainState: TunModeState {
        TunModeState(helperAvailable: helperAvailable, enabled: enabled, runtimeState: runtimeState,
                     ownedProcessIDs: tunnelProcessIDs)
    }
    public var modeDescription: String {
        if !enabled { return "已关闭" }
        if isRunning { return "运行中" }
        if runtimeState == "faulted" { return "连接失败，请查看日志" }
        return "已启用，未连接"
    }
    public var helperDescription: String {
        if helperAvailable { return "已就绪" }
        switch helperCode {
        case "apple_team_signature_required", "signing_identity_missing": return "需要签名安装包"
        case "helper_protocol_mismatch": return "版本不匹配，请点击“检查与修复”"
        default: return "未就绪，请检查授权"
        }
    }
}

public protocol TunBackend: Sendable {
    func tunStatus() async throws -> MacTunStatus
    func setTunEnabled(_ enabled: Bool) async throws
    func startTunCore() async throws
}



public enum TunModeChange {
    public static func checkBeforeConnecting(backend: any TunBackend,
                                             checkOtherTunnel: @Sendable () async throws -> Void = { try await TunnelConflict.check() }) async throws {
        let state = try await backend.tunStatus()
        do { try await TunPreflightService.check(state.domainState, requestingTun: state.enabled, checkOtherTunnel: checkOtherTunnel) }
        catch ModeSwitchRejection.helperUnavailable { throw ClientFailure("mac_tun_helper_unavailable") }
    }


}

public enum TunnelConflict {
    public static func check() async throws {
        try await Task.detached {
            if try routeInterface(to: "1.1.1.1").hasPrefix("utun") || hasRoutedTunnel() { throw ClientFailure("tun_conflict") }
        }.value
    }

    // A split tunnel can own a unicast prefix while the IPv4 default stays on Wi-Fi.
    // macOS also installs scoped defaults and link-local routes for idle utun interfaces.
    static func capturesTraffic(interface: String, flags: Int32, family: Int32, address: [UInt8]) -> Bool {
        guard interface.hasPrefix("utun"), flags & RTF_UP != 0, flags & (RTF_IFSCOPE | RTF_LOCAL) == 0 else { return false }
        if family == AF_INET, address.count == 4 {
            return address[0] != 127 && address[0] < 224 && !address.starts(with: [169, 254])
        }
        if family == AF_INET6, address.count == 16 {
            return address[0] != 0xff && !(address[0] == 0xfe && address[1] & 0xc0 == 0x80)
                && address != Array(repeating: 0, count: 15) + [1]
        }
        return false
    }

    static func hasRoutedTunnel() throws -> Bool {
        var mib = [CTL_NET, PF_ROUTE, 0, AF_UNSPEC, NET_RT_DUMP, 0]
        let failure = ClientFailure("tun_route_check_failed")
        for _ in 0..<3 {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0 else { throw failure }
            var data = Data(count: size)
            let status = data.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0) }
            if status < 0 && errno == ENOMEM { continue }
            guard status == 0 else { throw failure }
            return try data.withUnsafeBytes { bytes in
                let headerSize = MemoryLayout<rt_msghdr>.size
                var offset = 0
                while offset < size {
                    guard size - offset >= headerSize else { throw failure }
                    let h = bytes.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self)
                    let end = offset + Int(h.rtm_msglen)
                    guard end <= size, end >= offset + headerSize else { throw failure }
                    defer { offset = end }
                    guard h.rtm_addrs & RTA_DST != 0, end - offset >= headerSize + 2 else { continue }
                    let dst = offset + headerSize
                    let family = Int32(bytes[dst + 1])
                    let field: (Int, Int)
                    switch family {
                    case AF_INET: field = (MemoryLayout<sockaddr_in>.offset(of: \.sin_addr)!, 4)
                    case AF_INET6: field = (MemoryLayout<sockaddr_in6>.offset(of: \.sin6_addr)!, 16)
                    default: continue
                    }
                    guard Int(bytes[dst]) >= field.0 + field.1, dst + Int(bytes[dst]) <= end else { continue }
                    var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                    guard if_indextoname(UInt32(h.rtm_index), &name) != nil else { continue }
                    let address = Array(bytes[(dst + field.0)..<(dst + field.0 + field.1)])
                    if capturesTraffic(interface: String(cString: name), flags: h.rtm_flags, family: family, address: address) { return true }
                }
                return false
            }
        }
        throw failure
    }

    /// RTM_GET asks the kernel which route a packet would use. It sends no packet to the destination.
    static func routeInterface(to address: String) throws -> String {
        let failure = ClientFailure("tun_route_check_failed")
        let fd = socket(PF_ROUTE, SOCK_RAW, 0)
        guard fd >= 0 else { throw failure }
        defer { close(fd) }
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, address, &destination.sin_addr) == 1 else { throw failure }
        var header = rt_msghdr()
        header.rtm_version = UInt8(RTM_VERSION)
        header.rtm_type = UInt8(RTM_GET)
        header.rtm_addrs = RTA_DST
        header.rtm_seq = Int32.random(in: 1...Int32.max)
        header.rtm_msglen = UInt16(MemoryLayout<rt_msghdr>.size + MemoryLayout<sockaddr_in>.size)
        var packet = withUnsafeBytes(of: &header) { Data($0) }
        withUnsafeBytes(of: &destination) { packet.append(contentsOf: $0) }
        let sent = packet.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard sent == packet.count else { throw failure }

        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var bytes = [UInt8](repeating: 0, count: 65536)
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw failure }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let polled = poll(&descriptor, 1, Int32(ceil(remaining * 1000)))
            if polled < 0 && errno == EINTR { continue }
            guard polled > 0 else { throw failure }
            let length = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if length < 0 && errno == EINTR { continue }
            guard length >= MemoryLayout<rt_msghdr>.size else { throw failure }
            let reply = bytes.withUnsafeBytes { $0.loadUnaligned(as: rt_msghdr.self) }
            guard reply.rtm_type == UInt8(RTM_GET), reply.rtm_pid == getpid(), reply.rtm_seq == header.rtm_seq else { continue }
            var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
            guard reply.rtm_errno == 0, if_indextoname(UInt32(reply.rtm_index), &name) != nil else { throw failure }
            return String(cString: name)
        }
    }
}
