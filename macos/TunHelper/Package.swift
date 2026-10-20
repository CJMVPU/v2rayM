// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "V2rayMTunHelper",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "V2rayMHelper", targets: ["V2rayMHelper"]),
        .executable(name: "V2rayMHelperClient", targets: ["V2rayMHelperClient"]),
    ],
    targets: [
        .target(name: "TunShared"),
        .executableTarget(name: "V2rayMHelper", dependencies: ["TunShared"]),
        .executableTarget(name: "V2rayMHelperClient", dependencies: ["TunShared"]),
        .testTarget(name: "TunSharedTests", dependencies: ["TunShared"]),
    ]
)
