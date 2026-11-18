import AppKit
import RealityKit

enum TitleBarGeometry {
    static let sideMargin: CGFloat = 8
    static let topMargin: CGFloat = 5
    static let height: CGFloat = 26
    static let width: Float = 860 - 2 * Float(sideMargin)
}

/// Normalized, bevelled shells. Scaling the mesh leaves child content in points.
enum DashboardBodyAsset: String, CaseIterable {
    case dial, card, titleBar

    @MainActor func build() throws -> ModelEntity {
        let contour: [SIMD2<Float>]
        switch self {
        case .dial:
            contour = (0..<128).map {
                let angle = Float($0) * 2 * .pi / 128
                return SIMD2(cos(angle), sin(angle)) * 0.5
            }
        case .card, .titleBar:
            let radius = self == .titleBar ? SIMD2<Float>(13 / TitleBarGeometry.width, 0.5) : SIMD2<Float>(0.04, 0.075)
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
            if self == .titleBar {
                // Inset in points on the floating title strip. A uniform XY
                // scale would consume the left and right ends of a wide card.
                let inset: [Float] = [0.65,0,0.25,0.55,0.85]
                let side = contour[index].x < 0 ? Float(-1) : 1
                let centre = side * (0.5 - 13 / TitleBarGeometry.width)
                let radiusScale = 1 - inset[layer]/13
                return [centre + (contour[index].x - centre) * radiusScale,
                        contour[index].y * radiusScale, depth]
            }
            return [v.x, v.y + lift, depth]
        }
        func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ material: UInt32) {
            guard simd_length_squared(simd_cross(b-a,c-a)) > 1e-20 else { return }
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
        mesh.textureCoordinates = .init(vertices.map { [$0.x + 0.5, $0.y + 0.5] })
        mesh.positions = .init(vertices); mesh.primitives = .triangles(indices); mesh.materials = .perFace(surfaces)
        let colours: [NSColor] = [.init(white: 0.095, alpha: 1), .init(red: 0.16,green: 0.21,blue: 0.25,alpha: 1), .init(red: 0.30,green: 0.38,blue: 0.44,alpha: 1), .init(red: 0.23,green: 0.29,blue: 0.34,alpha: 1), .init(red: 0.15,green: 0.18,blue: 0.21,alpha: 1)]
        var materials = colours.map { SimpleMaterial(color: $0, roughness: 0.72, isMetallic: false) }
        if self != .titleBar {
            // Bake broad reflected light across the front. UVs are continuous
            // across the triangle fan and do not stretch with the bevel depth.
            let length = 256
            var pixels = [UInt8]()
            pixels.reserveCapacity(length * length * 4)
            for y in 0..<length {
                for x in 0..<length {
                    let u = Double(x)/Double(length-1), v = Double(y)/Double(length-1)
                    let highlight = exp(-3.5 * (pow(u-0.22,2) + pow(v-0.26,2)))
                    let light = 0.70 * highlight + 0.30 * (1 - (u + v)/2)
                    pixels += [UInt8(27 + 44 * light), UInt8(38 + 51 * light), UInt8(47 + 58 * light), 255]
                }
            }
            guard let provider = CGDataProvider(data: Data(pixels) as CFData),
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let image = CGImage(width: length, height: length, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: length*4, space: space, bitmapInfo: .init(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw CocoaError(.coderInvalidValue) }
            let texture = try TextureResource.generate(from: image, options: .init(semantic: .color))
            materials[4].color = .init(tint: .white, texture: .init(texture))
        }
        return ModelEntity(mesh: try MeshResource.generate(from: [mesh]), materials: materials)
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
