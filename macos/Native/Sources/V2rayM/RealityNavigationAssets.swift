import AppKit
import RealityKit

/// Authored in RealityKit, exported to .reality files by the accompanying tool.
/// Units are normalized model-space units, not points or scene metres.
enum RealityNavigationSymbol: String, CaseIterable {
    case home, nodes, logs, settings
}

@MainActor enum RealityNavigationAssets {
    #if SWIFT_PACKAGE
    private static var templates: [RealityNavigationSymbol: Entity] = [:]
    static func load(_ symbol: RealityNavigationSymbol) throws -> Entity {
        if let template = templates[symbol] { return template.clone(recursive: true) }
        guard let url = Bundle.module.url(forResource: symbol.rawValue, withExtension: "reality", subdirectory: "Navigation") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let template = try Entity.load(contentsOf: url)
        templates[symbol] = template
        return template.clone(recursive: true)
    }
    #endif
    static func build(_ symbol: RealityNavigationSymbol) throws -> Entity {
        let root = Entity(); root.name = "navigation-" + symbol.rawValue
        let porcelain = SimpleMaterial(color: NSColor(red: 0.68, green: 0.81, blue: 0.91, alpha: 1), roughness: 0.3, isMetallic: false)
        let accent = SimpleMaterial(color: NSColor(red: 0.12, green: 0.57, blue: 0.74, alpha: 1), roughness: 0.26, isMetallic: true)
        let steel = SimpleMaterial(color: NSColor(white: 0.58, alpha: 1), roughness: 0.25, isMetallic: true)
        let dark = SimpleMaterial(color: NSColor(red: 0.07, green: 0.15, blue: 0.23, alpha: 1), roughness: 0.45, isMetallic: false)
        @discardableResult func part(_ name: String, _ mesh: MeshResource, _ material: SimpleMaterial, at position: SIMD3<Float>) -> ModelEntity {
            let entity = ModelEntity(mesh: mesh, materials: [material]); entity.name = name; entity.position = position
            root.addChild(entity); return entity
        }
        func box(_ name: String, _ size: SIMD3<Float>, _ material: SimpleMaterial, _ position: SIMD3<Float>, radius: Float = 0.035) {
            part(name, .generateBox(size: size, cornerRadius: radius), material, at: position)
        }
        switch symbol {
        case .home:
            box("porcelain-walls", [1.18,0.94,0.96], porcelain, [0,-0.28,0])
            part("accent-gabled-roof", try prism([[-0.82,0.13],[0,0.94],[0.82,0.13]], depth: 1.2), accent, at: .zero)
            box("chimney", [0.22,0.58,0.22], steel, [0.43,0.62,-0.2])
            box("door-recess", [0.3,0.56,0.045], dark, [-0.22,-0.47,0.5], radius: 0.014)
            box("accent-window", [0.28,0.28,0.055], accent, [0.28,-0.21,0.51], radius: 0.018)
            box("window-cross-horizontal", [0.28,0.035,0.018], porcelain, [0.28,-0.21,0.55], radius: 0.007)
            box("window-cross-vertical", [0.035,0.28,0.018], porcelain, [0.28,-0.21,0.55], radius: 0.007)
        case .nodes:
            let centers: [SIMD3<Float>] = [[0,0.63,0],[-0.64,-0.45,0.2],[0.63,-0.43,-0.14],[0,-0.04,0.65]]
            for (i,j) in [(0,1),(0,2),(1,2),(0,3),(1,3),(2,3)] {
                let a = centers[i], b = centers[j], delta = b-a
                let connector = part("steel-connector-\(i)-\(j)", .generateCylinder(height: simd_length(delta), radius: 0.075), steel, at: (a+b)/2)
                connector.orientation = simd_quatf(from: [0,1,0], to: simd_normalize(delta))
            }
            for (index, position) in centers.enumerated() {
                part("accent-node-\(index)", .generateSphere(radius: index == 3 ? 0.23 : 0.28), index == 3 ? porcelain : accent, at: position)
            }
        case .logs:
            box("back-cover", [1.18,1.48,0.16], dark, [-0.16,0.12,-0.25], radius: 0.07)
            box("page-block", [1.11,1.36,0.32], porcelain, [-0.07,0.04,-0.04], radius: 0.035)
            box("front-cover", [1.18,1.48,0.14], dark, [0.04,-0.04,0.21], radius: 0.055)
            box("accent-spine", [0.19,1.48,0.5], accent, [-0.46,-0.04,-0.02], radius: 0.04)
            for i in 0..<4 {
                box("raised-log-line-\(i)", [i == 3 ? 0.47 : 0.72,0.105,0.06], porcelain, [i == 3 ? 0.04 : 0.16,0.43-Float(i)*0.29,0.31], radius: 0.025)
            }
            box("accent-bookmark", [0.18,0.36,0.04], accent, [0.34,-0.78,0.1], radius: 0.012)
        case .settings:
            let gear = try gearMesh()
            let entity = ModelEntity(mesh: gear, materials: [porcelain, dark, accent]); entity.name = "beveled-gear"
            root.addChild(entity)
        }
        return root
    }

    static func prism(_ polygon: [SIMD2<Float>], depth: Float) throws -> MeshResource {
        var vertices: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = []
        let center = polygon.reduce(SIMD2<Float>.zero,+) / Float(polygon.count), half = depth/2
        func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
            let base = UInt32(vertices.count), normal = simd_normalize(simd_cross(b-a,c-a))
            vertices += [a,b,c]; normals += [normal,normal,normal]; indices += [base,base+1,base+2]
        }
        // Input triangles are normalized to counterclockwise winding.
        var polygon = polygon
        let area = polygon.indices.reduce(Float(0)) { sum,i in
            let a = polygon[i], b = polygon[(i+1)%polygon.count]; return sum + a.x*b.y-b.x*a.y
        }
        if area < 0 { polygon.reverse() }
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i+1)%polygon.count]
            let p = SIMD3<Float>(a.x,a.y,half), q = SIMD3<Float>(b.x,b.y,half)
            let r = SIMD3<Float>(a.x,a.y,-half), s = SIMD3<Float>(b.x,b.y,-half)
            triangle([center.x,center.y,half],p,q); triangle([center.x,center.y,-half],s,r)
            triangle(p,r,s); triangle(p,s,q)
        }
        var mesh = MeshDescriptor(name: "solid-prism")
        mesh.positions = .init(vertices); mesh.normals = .init(normals); mesh.primitives = .triangles(indices)
        return try MeshResource.generate(from: [mesh])
    }

    static func gearMesh() throws -> MeshResource {
        let count = 80
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = [], materials: [UInt32] = []
        func vertex(_ i: Int, inset: Float, z: Float, inner: Bool = false) -> SIMD3<Float> {
            let a = Float(i)*2 * .pi/Float(count)
            let tooth: Float = (i%10 >= 2 && i%10 <= 6) ? 0.98 : 0.76
            let r = inner ? 0.36 + inset : tooth - inset
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
            quad(vertex(i,inset:0.06,z:0.3),vertex(j,inset:0.06,z:0.3),vertex(j,inset:0.05,z:0.3,inner:true),vertex(i,inset:0.05,z:0.3,inner:true),material:0)
            quad(vertex(i,inset:0,z:0.23),vertex(j,inset:0,z:0.23),vertex(j,inset:0.06,z:0.3),vertex(i,inset:0.06,z:0.3),material:2)
            quad(vertex(i,inset:0,z:-0.23),vertex(j,inset:0,z:-0.23),vertex(j,inset:0,z:0.23),vertex(i,inset:0,z:0.23),material:1)
            quad(vertex(i,inset:0.05,z:0.3,inner:true),vertex(j,inset:0.05,z:0.3,inner:true),vertex(j,inset:0,z:0.23,inner:true),vertex(i,inset:0,z:0.23,inner:true),material:2)
            quad(vertex(i,inset:0,z:0.23,inner:true),vertex(j,inset:0,z:0.23,inner:true),vertex(j,inset:0,z:-0.23,inner:true),vertex(i,inset:0,z:-0.23,inner:true),material:1)
            quad(vertex(i,inset:0,z:-0.23),vertex(i,inset:0,z:-0.23,inner:true),vertex(j,inset:0,z:-0.23,inner:true),vertex(j,inset:0,z:-0.23),material:0)
        }
        var mesh = MeshDescriptor(name: "beveled-through-hole-gear")
        mesh.positions = .init(positions); mesh.normals = .init(normals); mesh.primitives = .triangles(indices); mesh.materials = .perFace(materials)
        return try MeshResource.generate(from: [mesh])
    }
}
