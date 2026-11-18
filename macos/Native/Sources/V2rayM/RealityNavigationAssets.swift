import AppKit
import RealityKit

/// Authored in RealityKit, exported to .reality files by the accompanying tool.
/// Units are normalized model-space units, not points or scene metres.
enum RealityNavigationSymbol: String, CaseIterable {
    case home, nodes, logs, settings
}

@MainActor enum RealityNavigationAssets {
    #if SWIFT_PACKAGE
    private static var templates: [RealityNavigationSymbol: [Bool: Entity]] = [:]
    static func load(_ symbol: RealityNavigationSymbol, selected: Bool = true) throws -> Entity {
        if let template = templates[symbol]?[selected] { return template.clone(recursive: true) }
        guard let url = Bundle.module.url(forResource: symbol.rawValue, withExtension: "reality", subdirectory: "Navigation") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let template = try Entity.load(contentsOf: url)
        tint(template, selected: selected)
        templates[symbol, default: [:]][selected] = template
        return template.clone(recursive: true)
    }
    private static func tint(_ entity: Entity, selected: Bool) {
        if let model = entity as? ModelEntity, var component = model.model {
            component.materials = component.materials.map { material in
                func tone(_ color: NSColor) -> NSColor {
                    let base = NSColor(selected ? DashboardTheme.accent : DashboardTheme.graphite)
                    let value = color.usingColorSpace(.sRGB)?.redComponent ?? 1
                    return base.blended(withFraction: 1 - value, of: .black) ?? base
                }
                if var simple = material as? SimpleMaterial {
                    simple.color.tint = tone(simple.color.tint)
                    return simple
                }
                if var pbr = material as? PhysicallyBasedMaterial {
                    pbr.baseColor.tint = tone(pbr.baseColor.tint)
                    return pbr
                }
                return material
            }
            model.model = component
        }
        for child in entity.children { tint(child, selected: selected) }
    }
    #endif
    static func build(_ symbol: RealityNavigationSymbol) throws -> Entity {
        let root = Entity(); root.name = "navigation-" + symbol.rawValue
        let ivory = SimpleMaterial(color: NSColor(white: 0.94, alpha: 1), roughness: 0.86, isMetallic: false)
        let mist = SimpleMaterial(color: NSColor(white: 0.78, alpha: 1), roughness: 0.84, isMetallic: false)
        let ink = SimpleMaterial(color: NSColor(white: 0.12, alpha: 1), roughness: 0.83, isMetallic: false)
        @discardableResult func part(_ name: String, _ mesh: MeshResource, _ material: SimpleMaterial, at position: SIMD3<Float>) -> ModelEntity {
            let entity = ModelEntity(mesh: mesh, materials: [material]); entity.name = name; entity.position = position
            root.addChild(entity); return entity
        }
        func box(_ name: String, _ size: SIMD3<Float>, _ material: SimpleMaterial, _ position: SIMD3<Float>, radius: Float = 0.035) {
            part(name, .generateBox(size: size, cornerRadius: radius), material, at: position)
        }
        func oval(_ name: String, _ size: SIMD3<Float>, _ material: SimpleMaterial, at position: SIMD3<Float>) {
            let eye = part(name, .generateSphere(radius: 1), material, at: position)
            eye.scale = size / 2
        }
        switch symbol {
        case .home:
            // A single house silhouette with round eaves and an open doorway.
            // The recessed purple disc in the reference is intentionally omitted.
            let corners: [SIMD2<Float>] = [[-0.84,0.10],[0,0.92],[0.84,0.10],[0.64,0.05],
                [0.64,-0.73],[0.12,-0.73],[0.12,-0.35],[-0.12,-0.35],[-0.12,-0.73],[-0.64,-0.73],[-0.64,0.05]]
            let house = ModelEntity(mesh: try relief(corners, radius: 0.115, depth: 0.34), materials: [ivory,mist])
            house.name = "house"; root.addChild(house)
        case .nodes:
            // Five capsules step upward, with the longest stroke at the centre.
            let bars: [(Float, Float)] = [(0.46,-0.45),(1.08,-0.37),(1.48,0),(1.10,0.35),(0.46,0.43)]
            for (index, bar) in bars.enumerated() {
                box("accent-signal-\(index)", [0.235,bar.0,0.26], mist,
                    [Float(index-2)*0.39,bar.1,0], radius: 0.115)
            }
        case .logs:
            // The projecting page block and curved covers read as a book at toolbar size.
            let felt = try coverMaterial()
            box("back-cover", [1.32,1.63,0.18], felt, [0,-0.06,-0.18], radius: 0.085)
            box("page-block", [1.23,1.49,0.36], ivory, [0.035,-0.10,0], radius: 0.12)
            box("binding", [0.24,1.57,0.48], felt, [-0.55,-0.035,0], radius: 0.10)
            box("front-cover", [1.34,1.53,0.22], felt, [0,0.06,0.21], radius: 0.105)
            for x: Float in [-0.32,0.32] {
                oval("eye", [0.34,0.33,0.14], ivory, at: [x,0.22,0.34])
                oval("pupil", [0.19,0.20,0.09], ink, at: [x,0.22,0.405])
            }
            let smile: [SIMD2<Float>] = [[-0.25,0.02],[0.25,0.02],[0.19,-0.12],[0.08,-0.20],[-0.08,-0.20],[-0.19,-0.12]]
            let mouth = ModelEntity(mesh: try relief(smile, radius: 0.045, depth: 0.05), materials: [ink,ink])
            mouth.position = [0,-0.08,0.33]; root.addChild(mouth)
        case .settings:
            let gear = ModelEntity(mesh: try gearMesh(), materials: [ivory,mist,mist])
            gear.name = "navigation-gear"; root.addChild(gear)
        }
        return root
    }

    /// Bake a fine, deterministic two-tone fleck into the book cover at export.
    private static func coverMaterial() throws -> SimpleMaterial {
        let size = 128
        var pixels = [UInt8](), seed: UInt32 = 713
        for _ in 0..<(size * size) {
            seed = seed &* 1664525 &+ 1013904223
            let grain = Int(seed >> 27) - 15
            pixels += [UInt8(170 + grain),UInt8(170 + grain),UInt8(170 + grain),255]
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let bitmap = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: size*4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: .init(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
            decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
        let texture = try TextureResource.generate(from: bitmap, options: .init(semantic: .color))
        var material = SimpleMaterial(color: .white, roughness: 1, isMetallic: false)
        material.color = .init(tint: .white, texture: .init(texture))
        return material
    }

    /// Sweep horizontal spans to fill concave contours (notably the doorway),
    /// then close the perimeter with a contrasting wall.
    private static func relief(_ corners: [SIMD2<Float>], radius: Float, depth: Float) throws -> MeshResource {
        typealias Point = SIMD2<Float>
        var outline: [Point] = []
        for i in corners.indices {
            let p = corners[i], prev = corners[(i + corners.count - 1) % corners.count], next = corners[(i+1) % corners.count]
            let r = min(radius, min(simd_distance(prev,p),simd_distance(next,p))*0.45)
            let a = p + simd_normalize(prev-p)*r, b = p + simd_normalize(next-p)*r
            for k in 0...6 {
                let t = Float(k)/6
                outline.append((1-t)*(1-t)*a + 2*t*(1-t)*p + t*t*b)
            }
        }
        var vertices: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], materials: [UInt32] = []
        func tri(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ mat: UInt32) {
            let n = simd_cross(b-a,c-a)
            guard simd_length_squared(n) > 1e-15 else { return }
            let normal = simd_normalize(n)
            vertices += [a,b,c]; normals += [normal,normal,normal]; materials.append(mat)
        }
        let z = depth/2
        let edges = outline.indices.map { (outline[$0],outline[($0+1)%outline.count]) }
        let heights = Set(outline.map(\.y)).sorted()
        for (lo,hi) in zip(heights, heights.dropFirst()) {
            let mid = (lo+hi)/2
            let spans = edges.compactMap { a,b -> Point? in
                guard min(a.y,b.y) < mid, max(a.y,b.y) > mid else { return nil }
                let slope = (b.x-a.x)/(b.y-a.y)
                return [a.x+(lo-a.y)*slope,a.x+(hi-a.y)*slope]
            }.sorted { $0.x+$0.y < $1.x+$1.y }
            for i in stride(from: 0, to: spans.count-1, by: 2) {
                let l = spans[i], r = spans[i+1]
                for face in [z,-z] {
                    let a = SIMD3<Float>(l.x,lo,face), b = SIMD3<Float>(r.x,lo,face)
                    let c = SIMD3<Float>(r.y,hi,face), d = SIMD3<Float>(l.y,hi,face)
                    if face > 0 { tri(a,b,c,0); tri(a,c,d,0) } else { tri(c,b,a,0); tri(d,c,a,0) }
                }
            }
        }
        for (a,b) in edges {
            tri([a.x,a.y,z],[b.x,b.y,z],[b.x,b.y,-z],1)
            tri([a.x,a.y,z],[b.x,b.y,-z],[a.x,a.y,-z],1)
        }
        var mesh = MeshDescriptor(name: "rounded-relief")
        mesh.positions = .init(vertices); mesh.normals = .init(normals)
        mesh.primitives = .triangles(vertices.indices.map(UInt32.init)); mesh.materials = .perFace(materials)
        return try MeshResource.generate(from: [mesh])
    }

    static func gearMesh() throws -> MeshResource {
        let count = 256
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = [], materials: [UInt32] = []
        func vertex(_ i: Int, inset: Float, z: Float, inner: Bool = false) -> SIMD3<Float> {
            let a = Float(i)*2 * .pi/Float(count)
            let sector = abs(remainder(a, .pi/4))
            // Ray through a rounded rectangular tooth on a circular root.
            let tooth: Float = max(0.68, min(0.97/max(cos(sector),0.001), 0.15/max(sin(sector),0.001)))
            let r = inner ? 0.32 + inset : tooth - inset
            return [cos(a)*r,sin(a)*r,z]
        }
        func quad(_ p: SIMD3<Float>, _ q: SIMD3<Float>, _ r: SIMD3<Float>, _ s: SIMD3<Float>, material: UInt32) {
            for (a,b,c) in [(p,q,r),(p,r,s)] {
                let base = UInt32(positions.count), n = simd_normalize(simd_cross(b-a,c-a))
                positions += [a,b,c]; normals += [n,n,n]; indices += [base,base+1,base+2]; materials.append(material)
            }
        }
        for i in 0..<count {
            let j = i+1
            quad(vertex(i,inset:0.09,z:0.3),vertex(j,inset:0.09,z:0.3),vertex(j,inset:0.05,z:0.3,inner:true),vertex(i,inset:0.05,z:0.3,inner:true),material:0)
            quad(vertex(i,inset:0,z:0.23),vertex(j,inset:0,z:0.23),vertex(j,inset:0.09,z:0.3),vertex(i,inset:0.09,z:0.3),material:2)
            quad(vertex(i,inset:0,z:-0.23),vertex(j,inset:0,z:-0.23),vertex(j,inset:0,z:0.23),vertex(i,inset:0,z:0.23),material:1)
            quad(vertex(i,inset:0.05,z:0.3,inner:true),vertex(j,inset:0.05,z:0.3,inner:true),vertex(j,inset:0,z:0.23,inner:true),vertex(i,inset:0,z:0.23,inner:true),material:2)
            quad(vertex(i,inset:0,z:0.23,inner:true),vertex(j,inset:0,z:0.23,inner:true),vertex(j,inset:0,z:-0.23,inner:true),vertex(i,inset:0,z:-0.23,inner:true),material:1)
            quad(vertex(i,inset:0,z:-0.23),vertex(i,inset:0,z:-0.23,inner:true),vertex(j,inset:0,z:-0.23,inner:true),vertex(j,inset:0,z:-0.23),material:0)
        }
        var mesh = MeshDescriptor(name: "eight-tooth-gear")
        mesh.positions = .init(positions); mesh.normals = .init(normals); mesh.primitives = .triangles(indices); mesh.materials = .perFace(materials)
        return try MeshResource.generate(from: [mesh])
    }
}
