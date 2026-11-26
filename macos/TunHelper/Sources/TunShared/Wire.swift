import Foundation

public enum HelperIdentity {
    public static let app = "io.github.CJMVPU.v2rayM"
    public static let service = app + ".tun-helper"
    public static let plist = service + ".plist"
    public static let protocolVersion = HelperContract.version
}

@objc public protocol TunHelperProtocol {
    func openTunnel(_ parameters: Data, withReply reply: @escaping (Data, FileHandle?) -> Void)
    func request(_ data: Data, withReply reply: @escaping (Data) -> Void)
}

public struct HelperRequest: Codable {
    public var action: String
    public var core: String?
    public var config: Data?
    public var resources: [String: Data]?
    public var paths: [String: String]?
    public var configureSystemDNS: Bool?
    public var sessionToken: String?
    public var bundledCoreSHA256: String?
    public var releaseURL: String?
    public var archive: Data?
    public var updateToken: String?
    public init(action: String) { self.action = action }
}

/// A decoded request whose original wire representation has passed the size limit.
/// Keeping construction at the wire boundary lets dispatch reuse large resource snapshots.
public struct DecodedHelperRequest {
    public let request: HelperRequest
    public init(data: Data) throws {
        guard data.count <= HelperContract.wireBytes else { throw HelperFailure("request_too_large") }
        request = try JSONDecoder().decode(HelperRequest.self, from: data)
    }
}

public struct HelperResponse: Codable {
    public var success: Bool
    public var code: String
    public var state: String
    public var protocolVersion = HelperIdentity.protocolVersion
    public var pid: Int32?
    public var executablePath: String?
    public var updateToken: String?
    public var logs: [String] = []
    public var coreVersion: String?
    public var verifiedSHA256: String?
    public var supportsTunnelDescriptor: Bool?
    public var supportsTunnelIPv6Address: Bool?
    public var tunnelInterface: String?
    /// Set on an open response when the helper can attest whether it recorded the requested lease.
    public var leaseAccepted: Bool?
    public var supportsBundledCorePin: Bool?
    public var previousVersionPresent: Bool?
    public var forced = false
    public init(success: Bool = true, code: String = "ok", state: String = "idle") {
        self.success = success; self.code = code; self.state = state
    }
}

public struct HelperFailure: Error, CustomStringConvertible {
    public let description: String
    public init(_ code: String) { description = code }
}
