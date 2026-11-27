// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ProjectTools",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(name: "ArchiveReader"),
        .executableTarget(name: "ProjectTool", dependencies: ["ArchiveReader"]),
        .testTarget(name: "ProjectToolTests", dependencies: ["ProjectTool"]),
    ]
)
