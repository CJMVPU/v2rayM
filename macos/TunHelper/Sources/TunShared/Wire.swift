import Foundation

public enum HelperIdentity {
    public static let app = "io.github.CJMVPU.v2rayM"
    public static let service = app + ".tun-helper"
    public static let plist = service + ".plist"
    public static let protocolVersion = 1
}

@objc public protocol TunHelperProtocol {
    func request(_ data: Data, withReply reply: @escaping (Data) -> Void)
}

public struct HelperRequest: Codable {
    public var action: String
    public var core: String?
    public var config: Data?
    public var resources: [String: Data]?
    public var paths: [String: String]?
    public init(action: String) { self.action = action }
}

public struct HelperResponse: Codable {
    public var success: Bool
    public var code: String
    public var state: String
    public var protocolVersion = HelperIdentity.protocolVersion
    public var pid: Int32?
    public var executablePath: String?
    public var logs: [String] = []
    public var forced = false
    public init(success: Bool = true, code: String = "ok", state: String = "idle") {
        self.success = success; self.code = code; self.state = state
    }
}

public struct HelperFailure: Error, CustomStringConvertible {
    public let description: String
    public init(_ code: String) { description = code }
}
