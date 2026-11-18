import AppKit

/// Fixed sRGB swatches shared by native text, log attributes and RealityKit materials.
public enum InterfacePalette {
    public static let background = rgb(0x161616)
    public static let well = rgb(0x1C1C1C)
    public static let panel = rgb(0x262626)
    public static let raised = rgb(0x303030)
    public static let edge = rgb(0x404040)
    public static let cardEdge = rgb(0x565656)
    public static let graphite = rgb(0x696969)
    public static let selectedPanel = rgb(0x494949)
    public static let text = rgb(0xEEEEE9)
    public static let secondary = rgb(0xBEBEBA)
    public static let proxyUpload = NSColor(srgbRed: 0.02, green: 0.83, blue: 0.96, alpha: 1)
    public static let proxyDownload = NSColor(srgbRed: 0.72, green: 0.35, blue: 0.98, alpha: 1)
    public static let directUpload = NSColor(srgbRed: 0.22, green: 0.79, blue: 0.48, alpha: 1)
    public static let directDownload = NSColor(srgbRed: 1, green: 0.65, blue: 0.24, alpha: 1)
    public static let accent = proxyUpload
    public static let error = rgb(0xD99389)

    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(value >> 16) / 255,
                green: CGFloat(value >> 8 & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
