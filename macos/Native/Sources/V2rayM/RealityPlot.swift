import AppKit
import RealityKit

struct RealityPlotStroke {
    let path: CGPath
    let color: CGColor
    var width: CGFloat = 1.5
    var offset: CGFloat = 0
    var opacity: Float = 1
}

/// Reuses the existing data-space curve cache, but presents clipped vector
/// ribbons as RealityKit meshes. Core Animation no longer draws the plot.
enum RealityPlotGeometry {
    static func segments(_ path: CGPath) -> [(CGPoint, CGPoint)] {
        var output: [(CGPoint, CGPoint)] = []
        var point = CGPoint.zero, start = CGPoint.zero
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint: point = element.points[0]; start = point
            case .addLineToPoint:
                output.append((point, element.points[0])); point = element.points[0]
            case .addCurveToPoint:
                let from = point, a = element.points[0], b = element.points[1], to = element.points[2]
                for i in 1...8 {
                    let t = CGFloat(i) / 8, u = 1-t
                    let next = CGPoint(x: u*u*u*from.x + 3*u*u*t*a.x + 3*u*t*t*b.x + t*t*t*to.x,
                                       y: u*u*u*from.y + 3*u*u*t*a.y + 3*u*t*t*b.y + t*t*t*to.y)
                    output.append((point,next)); point = next
                }
            case .addQuadCurveToPoint:
                let from = point, control = element.points[0], to = element.points[1]
                for i in 1...8 {
                    let t = CGFloat(i) / 8, u = 1-t
                    let next = CGPoint(x: u*u*from.x + 2*u*t*control.x + t*t*to.x,
                                       y: u*u*from.y + 2*u*t*control.y + t*t*to.y)
                    output.append((point,next)); point = next
                }
            case .closeSubpath: output.append((point,start)); point = start
            @unknown default: break
            }
        }
        return output
    }

    static func clip(_ from: CGPoint, _ to: CGPoint, size: CGSize) -> (CGPoint, CGPoint)? {
        guard from.x.isFinite, from.y.isFinite, to.x.isFinite, to.y.isFinite else { return nil }
        let dx = to.x-from.x, dy = to.y-from.y
        var lower: CGFloat = 0, upper: CGFloat = 1
        for (p,q) in [(-dx,from.x), (dx,size.width-from.x), (-dy,from.y), (dy,size.height-from.y)] {
            if p == 0 { if q < 0 { return nil }; continue }
            let r = q/p
            if p < 0 { lower = max(lower,r) } else { upper = min(upper,r) }
            if lower > upper { return nil }
        }
        return (CGPoint(x: from.x + lower*dx, y: from.y + lower*dy),
                CGPoint(x: from.x + upper*dx, y: from.y + upper*dy))
    }

    @MainActor static func mesh(_ strokes: [RealityPlotStroke], size: CGSize, clipToViewport: Bool = true) throws -> MeshResource? {
        var positions: [SIMD3<Float>] = [], indices: [UInt32] = [], materials: [UInt32] = []
        for (index, stroke) in strokes.enumerated() {
            for (a,b) in segments(stroke.path) {
                var from = CGPoint(x: a.x + stroke.offset, y: a.y)
                var to = CGPoint(x: b.x + stroke.offset, y: b.y)
                if clipToViewport {
                    guard let endpoints = clip(from, to, size: size) else { continue }
                    (from, to) = endpoints
                }
                let delta = SIMD2<Float>(Float(to.x-from.x), Float(to.y-from.y))
                let length = simd_length(delta)
                guard length > 0.00001 else { continue }
                let normal = SIMD2<Float>(-delta.y,delta.x) * Float(stroke.width / 2) / length
                let p = SIMD2<Float>(Float(from.x-size.width/2),Float(size.height/2-from.y))
                let q = SIMD2<Float>(Float(to.x-size.width/2),Float(size.height/2-to.y))
                let n = SIMD2<Float>(normal.x,-normal.y)
                let base = UInt32(positions.count)
                // A shallow ridge retains the precise projected line width.
                for (point,z): (SIMD2<Float>, Float) in [(p+n,0),(p,0.0003),(p-n,0),(q+n,0),(q,0.0003),(q-n,0)] {
                    positions.append([point.x/1000, point.y/1000, z])
                }
                for index in [0,1,4,0,4,3,1,2,5,1,5,4] { indices.append(base + UInt32(index)) }
                materials.append(contentsOf: Array(repeating: UInt32(index), count: 4))
            }
        }
        guard !positions.isEmpty else { return nil }
        var descriptor = MeshDescriptor(name: "v2rayM-plot")
        descriptor.positions = .init(positions)
        descriptor.normals = .init(Array(repeating: SIMD3<Float>(0,0,1), count: positions.count))
        descriptor.primitives = .triangles(indices)
        descriptor.materials = .perFace(materials)
        return try MeshResource.generate(from: [descriptor])
    }
}

/// A series owns a mesh in plot coordinates. Scrolling moves its entity, while
/// new samples, tail reveal and a new vertical scale invalidate only changed paths.
@MainActor final class RealityPlotModel {
    let entity = ModelEntity()
    @MainActor private struct Series {
        let entity = ModelEntity()
        var path: CGPath?
        var width: CGFloat = 0
        var origin: CGFloat = 0
        var color: CGColor?
        var opacity: Float = -1
        var clipped = false
    }
    private var series: [Series] = []
    private var size = CGSize.zero

    func update(_ strokes: [RealityPlotStroke], size: CGSize) {
        let resized = self.size != size
        if resized {
            self.size = size
            let frame = CGRect(origin: .zero, size: size)
            RealityViewportClip.apply(frame, in: frame, to: entity)
        }
        while series.count > strokes.count { series.removeLast().entity.removeFromParent() }
        while series.count < strokes.count {
            let item = Series()
            entity.addChild(item.entity)
            series.append(item)
        }
        let viewport = CGRect(origin: .zero, size: size)
        for (index, stroke) in strokes.enumerated() {
            var item = series[index]
            // On earlier systems, only paths crossing the viewport need CPU clipping.
            let needsClip = !RealityViewportClip.supported && !viewport.contains(stroke.path.boundingBoxOfPath
                .insetBy(dx: -stroke.width/2, dy: -stroke.width/2).offsetBy(dx: stroke.offset, dy: 0))
            let rebuild = resized || item.path != stroke.path || item.width != stroke.width
                || item.clipped != needsClip || (needsClip && stroke.offset != item.origin)
            if rebuild {
                item.origin = stroke.offset
                item.clipped = needsClip
                item.path = stroke.path
                item.width = stroke.width
                if let mesh = try? RealityPlotGeometry.mesh([stroke], size: size, clipToViewport: needsClip) {
                    item.entity.model = ModelComponent(mesh: mesh, materials: [])
                } else { item.entity.model = nil }
            }
            if rebuild || item.color != stroke.color || item.opacity != stroke.opacity {
                let color = NSColor(cgColor: stroke.color) ?? .white
                var material = UnlitMaterial(color: color.withAlphaComponent(1))
                material.blending = .transparent(opacity: .init(floatLiteral: Float(color.alphaComponent) * stroke.opacity))
                material.faceCulling = .none
                item.entity.model?.materials = [material]
                item.color = stroke.color
                item.opacity = stroke.opacity
            }
            let x = Float(stroke.offset-item.origin)/1000
            if item.entity.position.x != x { item.entity.position.x = x }
            series[index] = item
        }
    }
}
