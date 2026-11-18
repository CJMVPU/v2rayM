import Foundation
import RealityKit

/// Compile with ControlAsset.swift. The exported meshes are used directly by
/// the UI; there is no runtime path triangulation or bitmap icon conversion.
@main struct GenerateControlAssets {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw CocoaError(.fileNoSuchFile) }
        let catalog = Entity()
        for asset in ControlAsset.allCases {
            let model = try asset.build()
            catalog.addChild(model)
        }
        try await catalog.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
