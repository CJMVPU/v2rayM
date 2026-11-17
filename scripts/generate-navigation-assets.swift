import Foundation
import RealityKit

/// Build with RealityNavigationAssets.swift, then pass the Navigation folder.
@main struct GenerateNavigationAssets {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Provide an output folder") }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for symbol in RealityNavigationSymbol.allCases {
            let entity = try RealityNavigationAssets.build(symbol)
            let file = directory.appendingPathComponent(symbol.rawValue + ".reality")
            try await entity.write(to: file)
            let loaded = try await Entity(contentsOf: file)
            let bounds = loaded.visualBounds(relativeTo: nil)
            guard bounds.extents.x > 0, bounds.extents.y > 0, bounds.extents.z > 0.1 else { fatalError("Asset lost its volume") }
            print("Exported \(symbol.rawValue): \(bounds.extents)")
        }
    }
}
