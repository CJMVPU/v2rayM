import RealityKit
import AppKit

/// Point-space geometry is converted once to metres. All generated meshes have
/// real side faces; cards are not stacks of two-dimensional SwiftUI shapes.
enum RealityGeometry {
    static func outline(shape: RealityShape, size: CGSize) -> [SIMD2<Float>] {
        let w = Float(size.width / 1000), h = Float(size.height / 1000)
        switch shape {
        case .disc:
            return (0..<96).map { i in
                let a = Float(i) * 2 * .pi / 96
                return [cos(a) * w / 2, sin(a) * h / 2]
            }
        case .panel(let radius), .cardPanel(let radius), .well(let radius), .shadow(let radius):
            let r = min(Float(radius / 1000), min(w, h) / 2)
            if r <= 0 { return [[w/2,h/2],[-w/2,h/2],[-w/2,-h/2],[w/2,-h/2]] }
            let centers: [SIMD2<Float>] = [[w/2-r, h/2-r], [-w/2+r, h/2-r], [-w/2+r, -h/2+r], [w/2-r, -h/2+r]]
            return centers.enumerated().flatMap { corner, center in
                (0...8).map { i in
                    let a = Float(corner) * .pi / 2 + Float(i) * .pi / 16
                    return center + SIMD2<Float>(cos(a), sin(a)) * r
                }
            }
        case .ring, .ringTrack, .symbol, .dashboard, .glyph, .group: return []
        }
    }
    @MainActor static func mesh(shape: RealityShape, size: CGSize, depth: Float) throws -> MeshResource {
        if case .symbol = shape { throw CocoaError(.featureUnsupported) }
        var points: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = []
        let cardFace: Bool
        if case .cardPanel = shape { cardFace = true } else { cardFace = false }
        var materials: [UInt32] = []
        func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, normal: SIMD3<Float>, face: Bool = false) {
            let start = UInt32(points.count); points += [a,b,c]; normals += [normal,normal,normal]
            indices += [start,start+1,start+2]
            if cardFace { materials.append(face ? 1 : 0) }
        }
        let half = max(0.0001, depth / 2000)
        if case .ring(let fraction) = shape { return try RealityRingMesh.make(size: size, fraction: fraction) }
        if shape == .ringTrack { return try RealityRingMesh.make(size: size, fraction: 1, segments: 360) }
        let polygon = outline(shape: shape, size: size)
        let bevel = min(0.85, min(size.width, size.height) * 0.1, CGFloat(depth) * 0.28)
        let innerShape: RealityShape
        var recessed = false
        switch shape {
        case .panel(let r), .cardPanel(let r): innerShape = .panel(max(0.001, r-bevel))
        case .well(let r): innerShape = .well(max(0.001, r-bevel)); recessed = true
        default: innerShape = shape
        }
        let inner = outline(shape: innerShape, size: CGSize(width: size.width - 2*bevel, height: size.height - 2*bevel))
        let useBevel = inner.count == polygon.count && bevel > 0 && shape != .panel(0)
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i+1) % polygon.count]
            guard simd_length_squared(b-a) > 1e-16 else { continue }
            let lipZ = useBevel && !recessed ? half - Float(bevel)/1000 : half
            let frontA = SIMD3<Float>(a.x,a.y,lipZ), frontB = SIMD3<Float>(b.x,b.y,lipZ)
            let backA = SIMD3<Float>(a.x,a.y,-half), backB = SIMD3<Float>(b.x,b.y,-half)
            if useBevel {
                let faceZ = recessed ? half - Float(bevel)/1000 : half
                let c = SIMD3<Float>(inner[i].x, inner[i].y, faceZ)
                let next = inner[(i+1) % inner.count]
                let d = SIMD3<Float>(next.x, next.y, faceZ)
                let n = simd_normalize(simd_cross(frontB-frontA, d-frontA))
                triangle(frontA,frontB,d,normal:n); triangle(frontA,d,c,normal:n)
                triangle([0,0,faceZ],c,d,normal:[0,0,1], face: true)
            } else { triangle([0,0,half],frontA,frontB,normal: [0,0,1], face: true) }
            triangle([0,0,-half],backB,backA,normal: [0,0,-1])
            let edge = b-a
            let normal = simd_normalize(SIMD3<Float>(edge.y,-edge.x,0))
            triangle(frontA,backA,backB,normal: normal); triangle(frontA,backB,frontB,normal: normal)
        }
        var descriptor = MeshDescriptor(name: "v2rayM-surface")
        if cardFace {
            descriptor.textureCoordinates = .init(points.map { [$0.x*1000/Float(size.width)+0.5, $0.y*1000/Float(size.height)+0.5] })
            descriptor.materials = .perFace(materials)
        }
        descriptor.positions = MeshBuffers.Positions(points)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        return try MeshResource.generate(from: [descriptor])
    }
}
