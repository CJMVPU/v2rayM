import AppKit

/// Fixed sRGB swatches shared by native text, log attributes and RealityKit materials.
public enum InterfacePalette {
    public static let background = rgb(0x141414)
    public static let well = rgb(0x191919)
    public static let panel = rgb(0x1E1E1E)
    public static let raised = rgb(0x272727)
    public static let edge = rgb(0x323232)
    public static let graphite = rgb(0x696969)
    public static let selectedPanel = rgb(0x3D3D3D)
    public static let text = rgb(0xDEDEDB)
    public static let secondary = rgb(0xA6A6A4)
    public static let accent = rgb(0x81AF9F)
    public static let proxyUpload = rgb(0x72A5AC)
    public static let proxyDownload = rgb(0xA08DA9)
    public static let directUpload = rgb(0x8CA587)
    public static let directDownload = rgb(0xBE9D74)
    public static let error = rgb(0xD99389)

    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(value >> 16) / 255,
                green: CGFloat(value >> 8 & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
