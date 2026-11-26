// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "V2rayMNative",
    platforms: [.macOS("15.0")],
    products: [.executable(name: "V2rayM", targets: ["V2rayM"])],
    dependencies: [.package(path: "../TunHelper")],
    targets: [
        .systemLibrary(name: "CSystemArchive"),
        .target(name: "V2rayMDomain"),
        .target(name: "V2rayMApplication", dependencies: ["V2rayMDomain"]),
        .target(name: "V2rayMKit", dependencies: ["CSystemArchive", "V2rayMDomain", "V2rayMApplication", .product(name: "TunShared", package: "TunHelper")], resources: [.copy("RuntimeDefaults")]),
        .executableTarget(name: "V2rayM", dependencies: ["V2rayMKit"], resources: [.copy("Resources/Fonts"), .copy("Resources/Globe"), .copy("Resources/Navigation"), .copy("Resources/Dashboard"), .copy("Resources/Controls")]),
        .executableTarget(name: "V2rayMCheck", dependencies: ["V2rayMKit"]),
        .testTarget(name: "V2rayMKitTests", dependencies: ["V2rayMKit", "V2rayMDomain"], resources: [.copy("Fixtures")]),
        .testTarget(name: "V2rayMApplicationTests", dependencies: ["V2rayMApplication"]),
        .testTarget(name: "V2rayMRenderingTests", dependencies: ["V2rayM"]),
    ]
)
