import Foundation
import CoreGraphics

/// Pacific-centered Mercator projection. Longitudes use 0…360 so Asia and
/// America share one continuous map, without a seam at the date line.
public struct PacificMapProjection {
    public let canvas: CGRect
    public let plot: CGRect
    public let world: CGRect
    public init(size: CGSize) {
        canvas = CGRect(origin: .zero, size: size)
        plot = canvas.insetBy(dx: min(44, size.width * 0.12), dy: min(42, size.height * 0.12))
        // Fixed geographic framing. Connection arrival/expiry must never move the map.
        let west = 85.0, east = 275.0
        let south = Self.mercator(-20), north = Self.mercator(70)
        let scale = max((east - west) / max(1, plot.width), (north - south) / max(1, plot.height))
        let width = max(1, plot.width) * scale, height = max(1, plot.height) * scale
        world = CGRect(x: (west + east - width) / 2, y: (south + north - height) / 2, width: width, height: height)
    }
    public static func longitude(_ value: Double) -> Double { (value.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) }
    public static func mercator(_ latitude: Double) -> Double {
        log(tan(.pi / 4 + min(85, max(-85, latitude)) * .pi / 360)) * 180 / .pi
    }
    public static func latitude(_ y: Double) -> Double { (2 * atan(exp(y * .pi / 180)) - .pi / 2) * 180 / .pi }
    public func point(_ place: GlobePlace) -> CGPoint {
        CGPoint(x: plot.minX + (Self.longitude(place.longitude) - world.minX) / world.width * plot.width,
                y: plot.minY + (world.maxY - Self.mercator(place.latitude)) / world.height * plot.height)
    }
    /// Offscreen locations are represented at the edge, explicitly labeled as such.
    /// Keep `point` unmodified for geographic drawing and inverse projection.
    public func displayPoint(_ place: GlobePlace) -> CGPoint {
        let value = point(place)
        return CGPoint(x: min(plot.maxX, max(plot.minX, value.x)),
                       y: min(plot.maxY, max(plot.minY, value.y)))
    }
    public func isOutside(_ place: GlobePlace) -> Bool { !plot.contains(point(place)) }
    public func coordinate(_ point: CGPoint) -> (longitude: Double, latitude: Double) {
        (world.minX + (point.x - plot.minX) / plot.width * world.width,
         Self.latitude(world.maxY - (point.y - plot.minY) / plot.height * world.height))
    }
    public func curve(from: GlobePlace, to: GlobePlace, returnPath: Bool = false) -> MapConnectionCurve {
        let a = displayPoint(from), b = displayPoint(to)
        let lift = min(100, max(24, abs(b.x - a.x) * 0.28))
        // All control points are inside the map. The convex hull property then
        // guarantees the complete cubic stays visible, including polar routes.
        let y = returnPath ? min(plot.maxY, max(a.y, b.y) + lift * 0.55) : max(plot.minY, min(a.y, b.y) - lift)
        return MapConnectionCurve(start: a, control1: CGPoint(x: a.x + (b.x - a.x) * 0.3, y: y),
                                  control2: CGPoint(x: a.x + (b.x - a.x) * 0.7, y: y), end: b)
    }
}

public struct MapConnectionCurve {
    public let start: CGPoint
    public let control1: CGPoint
    public let control2: CGPoint
    public let end: CGPoint
    public func point(at t: Double) -> CGPoint {
        let s = 1 - t
        return CGPoint(x: s*s*s*start.x + 3*s*s*t*control1.x + 3*s*t*t*control2.x + t*t*t*end.x,
                       y: s*s*s*start.y + 3*s*s*t*control1.y + 3*s*t*t*control2.y + t*t*t*end.y)
    }
}
