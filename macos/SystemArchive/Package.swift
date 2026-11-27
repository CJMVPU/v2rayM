// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SystemArchive",
    products: [.library(name: "CSystemArchive", targets: ["CSystemArchive"])],
    targets: [.systemLibrary(name: "CSystemArchive")]
)
