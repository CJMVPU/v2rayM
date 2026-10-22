import AppKit
import V2rayMKit

enum MenuBarIcon {
    @MainActor static func image(for mode: MenuBarMode) -> NSImage {
        let color: NSColor = switch mode {
        case .inactive: .black
        case .system: .systemBlue
        case .tun: .systemGreen
        case .attention: .systemOrange
        }
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let path = NSBezierPath()
            let points: [NSPoint] = [
                .init(x: 1, y: 2), .init(x: 5.5, y: 2), .init(x: 9, y: 12),
                .init(x: 12.5, y: 2), .init(x: 17, y: 2), .init(x: 11.4, y: 17), .init(x: 6.6, y: 17)
            ]
            path.move(to: points[0])
            for point in points.dropFirst() { path.line(to: point) }
            path.close()
            color.setFill(); path.fill()
            return true
        }
        // Inactive follows system contrast; active modes preserve their explicit colors.
        image.isTemplate = mode == .inactive
        image.accessibilityDescription = "v2rayM · " + mode.label
        return image
    }
}
