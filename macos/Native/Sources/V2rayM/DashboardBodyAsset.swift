import AppKit
import RealityKit

enum TitleBarGeometry {
    static let sideMargin: CGFloat = 8
    static let topMargin: CGFloat = 5
    static let height: CGFloat = 26
    static let cornerRadius: CGFloat = 6
    static let width: Float = 860 - 2 * Float(sideMargin)
}

/// Normalized, bevelled shells. Scaling the mesh leaves child content in points.
enum DashboardBodyAsset: String, CaseIterable {
    case dial, card, titleBar

    @MainActor func build() throws -> ModelEntity {
        let radiusInPoints = Float(TitleBarGeometry.cornerRadius)
        let stripRadius = SIMD2(radiusInPoints / TitleBarGeometry.width, radiusInPoints / Float(TitleBarGeometry.height))
        let contour: [SIMD2<Float>]
        switch self {
        case .dial:
            contour = (0..<128).map {
                let angle = Float($0) * 2 * .pi / 128
                return SIMD2(cos(angle), sin(angle)) * 0.5
            }
        case .card, .titleBar:
            let radius = self == .titleBar ? stripRadius : SIMD2<Float>(0.04, 0.075)
            contour = (0..<4).flatMap { corner in
                let sign: SIMD2<Float> = [[1,1],[-1,1],[-1,-1],[1,-1]][corner]
                return (0...10).map { step in
                    let angle = Float(corner) * .pi / 2 + Float(step) * .pi / 20
                    return sign * (0.5 - radius) + SIMD2(cos(angle), sin(angle)) * radius
                }
            }
        }
        // A continuous sidewall and narrow bevel meet the face on the same outline.
        let rings: [(scale: Float, depth: Float)] = [(0.993,-0.5),(1,-0.36),(1,0.30),(0.997,0.45),(0.991,0.50)]
        var vertices: [SIMD3<Float>] = [], indices: [UInt32] = [], surfaces: [UInt32] = []
        func point(_ index: Int, _ layer: Int) -> SIMD3<Float> {
            let ring = rings[layer]
            var xy = contour[index] * ring.scale
            if self == .titleBar {
                let inset: [Float] = [0.55, 0, 0, 0.25, 0.65]
                let corner = SIMD2<Float>(contour[index].x < 0 ? -1 : 1, contour[index].y < 0 ? -1 : 1)
                let centre = corner * (0.5 - stripRadius)
                xy = centre + (contour[index] - centre) * (1 - inset[layer] / radiusInPoints)
            }
            return [xy.x, xy.y, ring.depth]
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
        let tones: [CGFloat] = [0.11, 0.15, 0.22, 0.26, 0.20]
        var materials = tones.map { SimpleMaterial(color: NSColor(white: $0, alpha: 1), roughness: 0.78, isMetallic: false) }
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
                    pixels += [UInt8(31 + 33 * light), UInt8(31 + 33 * light), UInt8(32 + 33 * light), 255]
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
