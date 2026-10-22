import Foundation

/// Edit the full profile document so fields omitted from the form survive a save.
public struct ProfileDocument {
    public var value: SettingsValue
    public init(_ value: SettingsValue) { self.value = value }
    public func validated() throws -> SettingsValue {
        guard !value["remarks"].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value["address"].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let port = Int(value["port"].text), (1...65535).contains(port) else {
            throw ProfileEditError.invalidAddress
        }
        for key in ["protoExtra", "transportExtra"] {
            let text = value[key].text
            if !text.isEmpty {
                guard case .object = try SettingsValue.parse(text) else { throw ProfileEditError.invalidExtra }
            }
        }
        var result = value
        result["port"] = .number(Double(port))
        return result
    }
}
public enum ProfileEditError: LocalizedError {
    case invalidAddress, invalidExtra
    public var errorDescription: String? {
        switch self {
        case .invalidAddress: return "请输入节点名称、服务器地址和 1–65535 范围内的端口。"
        case .invalidExtra: return "协议和传输扩展配置必须是 JSON 对象。"
        }
    }
}
