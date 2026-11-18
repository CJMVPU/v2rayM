import AppKit
import RealityKit

/// Normalized, bevelled shells. Scaling the mesh leaves child content in points.
enum DashboardBodyAsset: String, CaseIterable {
    case dial, card

    @MainActor func build() throws -> ModelEntity {
        let contour: [SIMD2<Float>]
        switch self {
        case .dial:
            contour = (0..<128).map {
                let angle = Float($0) * 2 * .pi / 128
                return SIMD2(cos(angle), sin(angle)) * 0.5
            }
        case .card:
            let radius = SIMD2<Float>(0.04, 0.075)
            contour = (0..<4).flatMap { corner in
                let sign: SIMD2<Float> = [[1,1],[-1,1],[-1,-1],[1,-1]][corner]
                return (0...10).map { step in
                    let angle = Float(corner) * .pi / 2 + Float(step) * .pi / 20
                    return sign * (0.5 - radius) + SIMD2(cos(angle), sin(angle)) * radius
                }
            }
        }
        // A recessed plinth, dark sidewall and sloped lip remain visible
        // through the orthographic camera even when the front faces the viewer.
        let rings: [(Float, Float, Float)] = [(0.96,-0.016,-0.5),(1,0,-0.30),(0.99,0.008,0.18),(0.961,0.013,0.42),(0.946,0.013,0.50)]
        var vertices: [SIMD3<Float>] = [], indices: [UInt32] = [], surfaces: [UInt32] = []
        func point(_ index: Int, _ layer: Int) -> SIMD3<Float> {
            let (scale, lift, depth) = rings[layer], v = contour[index] * scale
            return [v.x, v.y + lift, depth]
        }
        func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ material: UInt32) {
            let i = UInt32(vertices.count)
            vertices += [a,b,c]; indices += [i,i+1,i+2]; surfaces.append(material)
        }
        for i in contour.indices {
            let j = (i+1) % contour.count
            for k in 0..<4 {
                triangle(point(i,k),point(j,k),point(j,k+1),UInt32(k))
                triangle(point(i,k),point(j,k+1),point(i,k+1),UInt32(k))
            }
            triangle([0,0,0.50],point(i,4),point(j,4),4)
            triangle([0,0,-0.50],point(j,0),point(i,0),0)
        }
        var mesh = MeshDescriptor(name: rawValue)
        mesh.positions = .init(vertices); mesh.primitives = .triangles(indices); mesh.materials = .perFace(surfaces)
        let colours: [NSColor] = [.init(white: 0.095, alpha: 1), .init(red: 0.16,green: 0.21,blue: 0.25,alpha: 1), .init(red: 0.30,green: 0.38,blue: 0.44,alpha: 1), .init(red: 0.23,green: 0.29,blue: 0.34,alpha: 1), .init(red: 0.15,green: 0.18,blue: 0.21,alpha: 1)]
        return ModelEntity(mesh: try MeshResource.generate(from: [mesh]), materials: colours.map { SimpleMaterial(color: $0, roughness: 0.72, isMetallic: false) })
    }

    #if SWIFT_PACKAGE
    @MainActor private static var templates: [Self: Entity] = [:]
    @MainActor func load() throws -> Entity {
        if let cached = Self.templates[self] { return cached.clone(recursive: true) }
        guard let url = Bundle.module.url(forResource: rawValue, withExtension: "reality", subdirectory: "Dashboard") else { throw CocoaError(.fileNoSuchFile) }
        let cached = try Entity.load(contentsOf: url)
        Self.templates[self] = cached
        return cached.clone(recursive: true)
    }
    #endif
}
