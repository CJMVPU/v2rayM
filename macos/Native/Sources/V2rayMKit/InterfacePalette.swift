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
    public static let accent = rgb(0x98C7B6)
    public static let proxyUpload = rgb(0x82B7BE)
    public static let proxyDownload = rgb(0xB19DBB)
    public static let directUpload = rgb(0x9CB699)
    public static let directDownload = rgb(0xCFAC81)
    public static let error = rgb(0xD99389)

    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(value >> 16) / 255,
                green: CGFloat(value >> 8 & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
