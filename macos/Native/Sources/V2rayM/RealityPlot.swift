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

    @MainActor static func mesh(_ strokes: [RealityPlotStroke], size: CGSize) throws -> MeshResource? {
        var positions: [SIMD3<Float>] = [], indices: [UInt32] = [], materials: [UInt32] = []
        for (index, stroke) in strokes.enumerated() {
            for (a,b) in segments(stroke.path) {
                guard let (from,to) = clip(CGPoint(x: a.x + stroke.offset, y: a.y), CGPoint(x: b.x + stroke.offset, y: b.y), size: size) else { continue }
                let delta = SIMD2<Float>(Float(to.x-from.x), Float(to.y-from.y))
                let length = simd_length(delta)
                guard length > 0.00001 else { continue }
                let normal = SIMD2<Float>(-delta.y,delta.x) * Float(stroke.width / 2) / length
                let p = SIMD2<Float>(Float(from.x-size.width/2),Float(size.height/2-from.y))
                let q = SIMD2<Float>(Float(to.x-size.width/2),Float(size.height/2-to.y))
                let n = SIMD2<Float>(normal.x,-normal.y)
                let base = UInt32(positions.count)
                for value in [p+n,p-n,q-n,q+n] { positions.append([value.x/1000,value.y/1000,0]) }
                indices += [base,base+1,base+2,base,base+2,base+3]
                materials += [UInt32(index),UInt32(index)]
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

@MainActor final class RealityPlotModel {
    let entity = ModelEntity()
    private var lastPaths: [CGPath] = []
    private var lastOffsets: [CGFloat] = []
    private var lastSize = CGSize.zero
    private var lastColors: [CGColor] = []
    private var lastOpacities: [Float] = []
    func update(_ strokes: [RealityPlotStroke], size: CGSize) {
        let paths = strokes.map(\.path), offsets = strokes.map(\.offset)
        let colors = strokes.map(\.color), opacities = strokes.map(\.opacity)
        guard paths != lastPaths || offsets != lastOffsets || size != lastSize || colors != lastColors || opacities != lastOpacities else { return }
        lastPaths = paths; lastOffsets = offsets; lastSize = size; lastColors = colors; lastOpacities = opacities
        guard let mesh = try? RealityPlotGeometry.mesh(strokes, size: size) else { entity.isEnabled = false; return }
        let materials: [UnlitMaterial] = strokes.map { stroke in
            let color = NSColor(cgColor: stroke.color) ?? .white
            var material = UnlitMaterial(color: color.withAlphaComponent(1))
            material.blending = .transparent(opacity: .init(floatLiteral: Float(color.alphaComponent) * stroke.opacity))
            material.faceCulling = .none
            return material
        }
        entity.model = ModelComponent(mesh: mesh, materials: materials)
        entity.isEnabled = true
    }
}
