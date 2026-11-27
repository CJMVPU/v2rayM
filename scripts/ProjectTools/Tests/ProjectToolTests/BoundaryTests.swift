import Foundation
import XCTest
@testable import ProjectTool

final class BoundaryTests: XCTestCase {
    private var root: URL!
    private let manifest = #".target(name: "V2rayMDomain"), .target(name: "V2rayMApplication", dependencies: ["V2rayMDomain"])"#

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try write("macos/Native/Package.swift", manifest)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func write(_ path: String, _ text: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testApplicationImportsAndInfrastructure() throws {
        XCTAssertTrue(try domainBoundaries(root).isEmpty)
        for declaration in ["import V2rayMKit", "@preconcurrency import V2rayMKit", "internal import V2rayMKit", "import struct V2rayMKit.APIClient"] {
            try write("macos/Native/Sources/V2rayMApplication/Bad.swift", declaration)
            XCTAssertFalse(try domainBoundaries(root).isEmpty, declaration)
        }
        try write("macos/Native/Sources/V2rayMApplication/Bad.swift", "import Foundation")
        try write("macos/Native/Sources/V2rayMDomain/Bad.swift", "import Foundation\nlet process = Process()")
        XCTAssertFalse(try domainBoundaries(root).isEmpty)
    }

    func testManifestFormattingAndDependencies() throws {
        try write("macos/Native/Package.swift", manifest.replacingOccurrences(of: "name:", with: "\n name:")
            .replacingOccurrences(of: "[\"V2rayMDomain\"]", with: "[\n \"V2rayMDomain\",\n]"))
        XCTAssertTrue(try domainBoundaries(root).isEmpty)
        try write("macos/Native/Package.swift", manifest.replacingOccurrences(of: "\"V2rayMDomain\")", with: "\"V2rayMDomain\", dependencies: [\"V2rayMKit\"])"))
        XCTAssertFalse(try domainBoundaries(root).isEmpty)
    }

    func testRetiredEnginesAndManagedProjects() throws {
        for path in [".github/workflows/new.yml", ".github/workflows/test-release.yml", ".github/workflows/smoke-download.yaml", "scripts/xray/library/new.go", "contracts/new.json", "macos/TunHelper/Sources/New.swift", "scripts/new-download.sh", "scripts/ProjectTools/Sources/ProjectTool/New.swift"] {
            try write(path, "download mihomo and sing-box and rules.srs")
            XCTAssertTrue(try productBoundaries(root).contains { $0.contains(path) }, path)
        }
        for (path, text) in [("macos/Other/ServiceLib.csproj", "<Project/>"), ("Legacy/Example.cs", "class Example {}"), (".github/workflows/new.yml", "uses: actions/setup-dotnet@v5"), ("scripts/build.sh", "dotnet publish Project")] {
            try write(path, text)
            XCTAssertTrue(try productBoundaries(root).contains { $0.contains(path) }, path)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("v2rayN"), withIntermediateDirectories: true)
        XCTAssertTrue(try productBoundaries(root).contains { $0.contains("v2rayN") })
    }
    func testBoundaryReportsEachOffendingLineOnce() throws {
        let path = "scripts/release.sh"
        try write(path, "# 发布\ndotnet build && dotnet test\nsing-box mihomo\n# OK\nDOTNET publish && rule.srs")
        XCTAssertEqual(try productBoundaries(root), [
            "\(path):2: retired managed toolchain", "\(path):3: retired engine reference",
            "\(path):5: retired managed toolchain", "\(path):5: retired engine reference"
        ])
    }

    func testRetiredInterpreterSourcesAndEntryPoints() throws {
        for (path, body) in [("tools/task.py", "pass"), ("macos/Native/Tests/Fixture.swift", #"/usr/bin/python3"#),
                             ("scripts/loopback/check.go", "/usr/bin/python3"), ("scripts/operator.command", "/usr/bin/python3 fixture"),
                             (".github/workflows/new.yml", "uses: actions/setup-python@v6"), ("pyproject.toml", ""),
                             ("scripts/new-tool", "#!/usr/bin/env python")] {
            try write(path, body)
            XCTAssertTrue(try productBoundaries(root).contains { $0.contains(path) }, path)
        }
    }

}
