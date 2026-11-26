// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "V2rayMTunHelper",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "TunShared", targets: ["TunShared"]),
        .executable(name: "V2rayMHelper", targets: ["V2rayMHelper"]),
        .executable(name: "V2rayMHelperClient", targets: ["V2rayMHelperClient"]),
    ],
    targets: [
        .target(name: "TunShared"),
        .target(name: "CTunDevice"),
        .target(name: "TunNetworkControl", dependencies: ["TunShared", "CTunDevice"]),
        .executableTarget(name: "V2rayMHelper", dependencies: ["TunShared", "TunNetworkControl"]),
        .executableTarget(name: "V2rayMHelperClient", dependencies: ["TunShared"]),
        .testTarget(name: "TunSharedTests", dependencies: ["TunShared", "TunNetworkControl"]),
    ]
)
