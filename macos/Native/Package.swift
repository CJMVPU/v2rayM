// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "V2rayMNative",
    platforms: [.macOS("15.0")],
    products: [.executable(name: "V2rayM", targets: ["V2rayM"])],
    targets: [
        .target(name: "V2rayMDomain"),
        .target(name: "V2rayMApplication", dependencies: ["V2rayMDomain"]),
        .target(name: "V2rayMKit", dependencies: ["V2rayMDomain", "V2rayMApplication"]),
        .executableTarget(name: "V2rayM", dependencies: ["V2rayMKit"], resources: [.copy("Resources/Fonts"), .copy("Resources/Globe"), .copy("Resources/Navigation")]),
        .executableTarget(name: "V2rayMCheck", dependencies: ["V2rayMKit"]),
        .testTarget(name: "V2rayMKitTests", dependencies: ["V2rayMKit"]),
        .testTarget(name: "V2rayMApplicationTests", dependencies: ["V2rayMApplication"]),
        .testTarget(name: "V2rayMRenderingTests", dependencies: ["V2rayM"]),
    ]
)
