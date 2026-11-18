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
        // Folded enamel marks share bevel widths, open silhouettes and a silver edge.
        switch symbol {
        case .home:
            bar("accent-eave-left", from: [-0.69,0.12,0], to: [0,0.80,0], radius: 0.115, material: accent)
            bar("accent-eave-right", from: [0,0.80,0], to: [0.69,0.12,0], radius: 0.115, material: accent)
            box("left-jamb", [0.23,0.81,0.37], porcelain, [-0.49,-0.26,0])
            box("right-jamb", [0.23,0.81,0.37], porcelain, [0.49,-0.26,0])
            box("threshold", [1.16,0.20,0.37], porcelain, [0,-0.62,0])
        case .nodes:
            bar("upper-branch", from: [-0.52,0,0], to: [0.43,0.55,0], radius: 0.09, material: porcelain)
            bar("lower-branch", from: [-0.52,0,0], to: [0.43,-0.55,0], radius: 0.09, material: porcelain)
            for (i,pos) in [SIMD3<Float>(-0.52,0,0),[0.44,0.56,0],[0.44,-0.56,0]].enumerated() {
                let tile = part("accent-junction-\(i)", .generateBox(size: [0.43,0.43,0.38], cornerRadius: 0.08), accent, at: pos)
                tile.orientation = simd_quatf(angle: .pi/4, axis: [0,0,1])
            }
        case .logs:
            for i in 0..<3 {
                let x = i == 2 ? Float(-0.12) : 0
                box("accent-entry-\(i)", [i == 2 ? 0.76 : 1,0.24,0.34], accent, [0.19+x,0.51-Float(i)*0.51,0], radius: 0.07)
                box("bullet-\(i)", [0.23,0.24,0.34], porcelain, [-0.59,0.51-Float(i)*0.51,0], radius: 0.06)
            }
        case .settings:
            let entity = ModelEntity(mesh: try gearMesh(), materials: [porcelain, dark, accent])
            entity.name = "navigation-gear"
            root.addChild(entity)
        }
        return root
    }

    static func gearMesh() throws -> MeshResource {
        let count = 120
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = [], materials: [UInt32] = []
        func vertex(_ i: Int, inset: Float, z: Float, inner: Bool = false) -> SIMD3<Float> {
            let a = Float(i)*2 * .pi/Float(count)
            let tooth: Float = 0.84 + 0.12 * tanh(2.4 * cos(8*a))
            let r = inner ? 0.40 + inset : tooth - inset
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
