import AppKit
import Foundation

public enum LogKind: Equatable {
    case error, warning, lifecycle, debug, info, normal
    public static func classify(_ entry: LogEntry) -> Self {
        let source = entry.source.lowercased()
        let message = entry.message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Match level tokens, not words in hostnames, URLs or ordinary payloads.
        func level(_ names: [String]) -> Bool {
            names.contains { name in
                source == name || source.hasSuffix("." + name) || source.hasSuffix("/" + name)
                || message.range(of: "[" + name + "]", options: .literal) != nil
                || message.hasPrefix(name + ":") || message.hasPrefix(name + " ")
            }
        }
        if level(["error", "fatal", "panic", "critical"]) { return .error }
        if level(["warning", "warn"]) { return .warning }
        let event = message.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        if ["core.startfailed", "core.stopfailed", "core.binarymissing", "core.portinuse", "core.unsupported"].contains(event) { return .error }
        if ["core.notrunning", "core.runtimebusy", "core.tunnotsupported"].contains(event) { return .warning }
        let lifecycle = ["core.start", "core.stop", "core.restart", "core.started", "core.stopped", "core.restarted"]
        if lifecycle.contains(source) || lifecycle.contains(event) { return .lifecycle }
        if level(["debug", "trace"]) { return .debug }
        if level(["info", "information"]) { return .info }
        return .normal
    }
    public var color: NSColor {
        switch self {
        case .error: return Self.adaptive("error", light: (0.72, 0.10, 0.14), dark: (1, 0.43, 0.46))
        case .warning: return Self.adaptive("warning", light: (0.49, 0.28, 0), dark: (1, 0.72, 0.30))
        case .lifecycle: return Self.adaptive("lifecycle", light: (0.04, 0.40, 0.25), dark: (0.36, 0.85, 0.61))
        case .debug: return Self.adaptive("debug", light: (0.43, 0.32, 0.56), dark: (0.74, 0.64, 0.89))
        case .info: return Self.adaptive("info", light: (0.08, 0.35, 0.62), dark: (0.42, 0.72, 1))
        case .normal: return .labelColor
        }
    }
    private static func adaptive(_ name: String, light: (Double, Double, Double), dark: (Double, Double, Double)) -> NSColor {
        NSColor(name: NSColor.Name("v2rayM.log." + name)) { appearance in
            let components = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: components.0, green: components.1, blue: components.2, alpha: 1)
        }
    }
}
