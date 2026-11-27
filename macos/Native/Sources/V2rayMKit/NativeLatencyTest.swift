import Foundation
import Network

public enum NativeSpeedAction: String, Sendable {
    case tcping, realping, fastrealping, udptest, speedtest, mixedtest
}

enum NativeLatencyTest {
    private static let queue = DispatchQueue(label: "v2rayM.latency", qos: .utility)

    static func ipDescription(_ info: SettingsValue) -> String {
        guard case .object = info else { return "none" }
        let country = [info["country_code"], info["country"], info["countryCode"], info["location"]["country_code"]]
            .first { $0 != .null }?.text ?? "unknown"
        let ip = ["ip", "clientIp", "ip_addr", "query"].compactMap { info[$0] == .null ? nil : info[$0].text }.first ?? ""
        var flag = ""
        if country.utf8.count == 2, country.utf8.allSatisfy({ (65...90).contains($0) }) {
            for ascii in country.utf8 { flag.unicodeScalars.append(Unicode.Scalar(0x1F1E6 + Int(ascii) - 65)!) }
        }
        return flag + "(" + country + ") " + ip
    }

    static func privateConfiguration(_ outbounds: [SettingsValue], id: UUID, group: XrayGroupRouting, pingURL: SettingsValue) throws -> SettingsValue {
        let tags = Set(outbounds.map { $0["tag"].text })
        guard tags.count == outbounds.count, (tags.contains("proxy") || group.tags.contains("proxy-balancer")), !tags.contains("") else {
            throw ClientFailure("speedtest_invalid_profile")
        }
        let prefix = id.uuidString + "/"
        let scoped = try outbounds.map { original in
            var item = original
            try XrayFileProfile.remapReferences(in: &item) { target in
                guard tags.contains(target) else { throw ClientFailure("profile_chain_member_missing") }
                return prefix + target
            }
            item["tag"] = .string(prefix + original["tag"].text)
            return item
        }
        var config: SettingsValue = .object(["outbounds": .array(scoped)])
        if var rule = group.balancers.first(where: { $0["tag"].text == "proxy-balancer" }) {
            rule["selector"] = .array([.string(prefix + "proxy")])
            config["routing"]["balancers"] = .array([rule])
            config["probeURL"] = pingURL
        }
        return config
    }

    static func measure(_ profile: Profile) async throws -> Int {
        try Task.checkCancellation()
        guard let port = UInt16(exactly: profile.port).flatMap(NWEndpoint.Port.init(rawValue:)) else { throw ClientFailure("speedtest_invalid_profile") }
        let connection = NWConnection(host: NWEndpoint.Host(profile.address), port: port, using: .tcp)
        let (stream, result) = AsyncStream<Int>.makeStream()
        let start = DispatchTime.now().uptimeNanoseconds
        let timeout = DispatchWorkItem { result.yield(-1); result.finish() }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                result.yield(max(1, Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)))
                result.finish()
            case .failed: result.yield(-1); result.finish()
            case .cancelled: result.finish()
            default: break
            }
        }
        queue.asyncAfter(deadline: .now() + 5, execute: timeout)
        connection.start(queue: queue)
        defer { timeout.cancel(); connection.cancel(); result.finish() }
        for await value in stream {
            try Task.checkCancellation()
            return value
        }
        try Task.checkCancellation()
        return -1
    }
}

/// Keep the exact graph given to Xray, including the probe's private tag namespace.
struct NativeDiagnosticAttempt {
    let id = UUID()
    let configuration: SettingsValue?
    let dependsOnGraph: Bool

    init(node: Profile, snapshot: XrayConfigurationSnapshot) {
        dependsOnGraph = ["proxyChain", "policyGroup", "outbound"].contains(node.protocol)
            || snapshot.configuration.subscriptions[node.subscriptionId ?? ""] != nil
        configuration = try? snapshot.generate(nodeID: node.id, metricsPort: nil, diagnosticID: id)
    }
}

extension NativeConfigurationStore {
    @discardableResult
    func recordLatency(_ delay: Int, for profile: Profile, speed: Double? = nil, ipInfo: String? = nil,
                       original: SettingsValue? = nil, attempt: NativeDiagnosticAttempt? = nil) throws -> Bool {
        let db = try RuntimeDatabase(url: databaseURL, writable: true)
        return try db.transaction {
            try Task.checkCancellation()
            guard let row = try db.query("SELECT * FROM ProfileItem WHERE IndexId=?", [.text(profile.id)]).first else { return false }
            if let original, Self.nodeDocument(from: row) != original { return false }
            let current = Self.nodeDocument(from: row)
            guard current["address"].text == profile.address, (Int(current["port"].text) ?? 0) == profile.port else { return false }
            if let attempt {
                // An ordinary subscription node can gain a chained hop during a probe.
                var checkGraph = attempt.dependsOnGraph
                if !checkGraph, !current["subid"].text.isEmpty {
                    checkGraph = try !db.query("""
                        SELECT Id FROM SubItem WHERE Id=? AND
                        (COALESCE(PrevProfile,'') <> '' OR COALESCE(NextProfile,'') <> '')
                        """, [.text(current["subid"].text)]).isEmpty
                }
                if checkGraph {
                    let snapshot = try configurationSnapshot()
                    let live = try? snapshot.generate(nodeID: profile.id, metricsPort: nil, diagnosticID: attempt.id)
                    guard live == attempt.configuration else { return false }
                }
            }
            try Task.checkCancellation()
            _ = try db.query("""
                INSERT INTO ProfileExItem(IndexId,Delay,Speed,IpInfo) VALUES (?,?,?,?)
                ON CONFLICT(IndexId) DO UPDATE SET Delay=excluded.Delay, Speed=COALESCE(excluded.Speed,ProfileExItem.Speed),
                IpInfo=COALESCE(excluded.IpInfo,ProfileExItem.IpInfo)
                """, [.text(profile.id), .integer(Int64(delay)), speed.map(RuntimeDatabase.Value.real) ?? .null,
                      ipInfo.map(RuntimeDatabase.Value.text) ?? .null])
            return true
        }
    }
}
