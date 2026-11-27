// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ProjectTools",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../../macos/SystemArchive")],
    targets: [
        .executableTarget(name: "ProjectTool", dependencies: [.product(name: "CSystemArchive", package: "SystemArchive")]),
        .testTarget(name: "ProjectToolTests", dependencies: ["ProjectTool"]),
    ]
)
