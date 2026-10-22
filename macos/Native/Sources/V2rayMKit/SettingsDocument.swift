import Foundation

/// Round-trip all upstream properties, including fields not exposed in the Mac UI.
public enum SettingsValue: Codable, Equatable {
    case object([String: SettingsValue]), array([SettingsValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: SettingsValue].self) { self = .object(v) }
        else { self = .array(try c.decode([SettingsValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> SettingsValue {
        get { if case .object(let v) = self { return v[key] ?? .null }; return .null }
        set { var v: [String: SettingsValue] = [:]; if case .object(let old) = self { v = old }; v[key] = newValue; self = .object(v) }
    }
    public var text: String {
        switch self { case .string(let v): return v; case .number(let v): return v.rounded() == v ? String(format: "%.0f", v) : String(v); default: return "" }
    }
    public var flag: Bool { if case .bool(let v) = self { return v }; return false }
    public var items: [SettingsValue] { if case .array(let v) = self { return v }; return [] }
    public func json() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
    public static func parse(_ text: String) throws -> SettingsValue { try JSONDecoder().decode(Self.self, from: Data(text.utf8)) }
}

/// A newly created route must never carry an existing route's identity or active flag.
public enum RoutingDraft {
    public static func newProfile() -> SettingsValue {
        .object(["remarks": .string("新方案"), "domainStrategy": .string(""), "ruleSet": .string("[]"), "isActive": .bool(false)])
    }
}
