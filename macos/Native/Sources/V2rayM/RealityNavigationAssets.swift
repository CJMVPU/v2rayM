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
        // Soft clay colours and broad rounded shapes remain readable at 22 pt.
        let porcelain = SimpleMaterial(color: NSColor(red: 0.76, green: 0.89, blue: 0.98, alpha: 1), roughness: 0.85, isMetallic: false)
        let accent = SimpleMaterial(color: NSColor(red: 0.25, green: 0.68, blue: 0.85, alpha: 1), roughness: 0.85, isMetallic: false)
        let dark = SimpleMaterial(color: NSColor(red: 0.26, green: 0.45, blue: 0.65, alpha: 1), roughness: 0.9, isMetallic: false)
        @discardableResult func part(_ name: String, _ mesh: MeshResource, _ material: SimpleMaterial, at position: SIMD3<Float>) -> ModelEntity {
            let entity = ModelEntity(mesh: mesh, materials: [material]); entity.name = name; entity.position = position
            root.addChild(entity); return entity
        }
        func box(_ name: String, _ size: SIMD3<Float>, _ material: SimpleMaterial, _ position: SIMD3<Float>, radius: Float = 0.035) {
            part(name, .generateBox(size: size, cornerRadius: radius), material, at: position)
        }
        func bar(_ name: String, from a: SIMD3<Float>, to b: SIMD3<Float>, radius: Float, material: SimpleMaterial) {
            let delta = b-a
            let entity = part(name, .generateBox(size: [radius*2,simd_length(delta)+radius*2,radius*2], cornerRadius: radius), material, at: (a+b)/2)
            entity.orientation = simd_quatf(from: [0,1,0], to: simd_normalize(delta))
        }
        switch symbol {
        case .home:
            box("soft-house", [1.12,0.96,0.56], porcelain, [0,-0.27,0], radius: 0.18)
            bar("accent-roof-left", from: [-0.68,0.16,0], to: [0,0.79,0], radius: 0.16, material: accent)
            bar("accent-roof-right", from: [0,0.79,0], to: [0.68,0.16,0], radius: 0.16, material: accent)
            box("accent-door", [0.34,0.46,0.12], accent, [0,-0.48,0.3], radius: 0.1)
        case .nodes:
            let centers: [SIMD3<Float>] = [[0,0.59,0],[-0.59,-0.43,0.08],[0.59,-0.43,-0.08]]
            for (i,j) in [(0,1),(0,2),(1,2)] {
                bar("soft-link-\(i)-\(j)", from: centers[i], to: centers[j], radius: 0.115, material: porcelain)
            }
            for (index, position) in centers.enumerated() {
                part("accent-node-\(index)", .generateSphere(radius: 0.32), accent, at: position)
            }
        case .logs:
            box("accent-log-slab", [1.24,1.62,0.48], accent, .zero, radius: 0.19)
            for i in 0..<3 {
                box("soft-log-line-\(i)", [i == 2 ? 0.48 : 0.78,0.16,0.12], porcelain,
                    [i == 2 ? -0.15 : 0,0.42-Float(i)*0.4,0.26], radius: 0.075)
            }
        case .settings:
            let entity = ModelEntity(mesh: try gearMesh(), materials: [accent, dark, porcelain])
            entity.name = "soft-gear"
            root.addChild(entity)
        }
        return root
    }

    static func gearMesh() throws -> MeshResource {
        let count = 120
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = [], materials: [UInt32] = []
        func vertex(_ i: Int, inset: Float, z: Float, inner: Bool = false) -> SIMD3<Float> {
            let a = Float(i)*2 * .pi/Float(count)
            let tooth: Float = 0.85 + 0.12 * cos(6*a)
            let r = inner ? 0.30 + inset : tooth - inset
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
        var mesh = MeshDescriptor(name: "soft-six-lobe-gear")
        mesh.positions = .init(positions); mesh.normals = .init(normals); mesh.primitives = .triangles(indices); mesh.materials = .perFace(materials)
        return try MeshResource.generate(from: [mesh])
    }
}
