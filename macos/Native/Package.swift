// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "V2rayMNative",
    platforms: [.macOS("15.0")],
    products: [.executable(name: "V2rayM", targets: ["V2rayM"])],
    targets: [
        .target(name: "V2rayMKit"),
        .executableTarget(name: "V2rayM", dependencies: ["V2rayMKit"], resources: [.copy("Resources/Fonts")]),
        .executableTarget(name: "V2rayMCheck", dependencies: ["V2rayMKit"]),
        .testTarget(name: "V2rayMKitTests", dependencies: ["V2rayMKit"]),
    ]
)
