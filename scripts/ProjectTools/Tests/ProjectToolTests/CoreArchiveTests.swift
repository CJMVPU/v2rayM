import Foundation
import XCTest
@testable import ProjectTool

final class CoreArchiveTests: XCTestCase {
    func testFullAndDataOnlyModesRejectMissingAndUnsafeFiles() throws {
        let fm = FileManager.default, tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundle = "v2rayN-macos-arm64", tree = tmp.appendingPathComponent(bundle + "/bin")
        try fm.createDirectory(at: tree.appendingPathComponent("xray"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let data: Set<String> = ["geoip.dat", "geosite.dat"], full = data.union(["xray/xray", "xray/LICENSE"])
        for name in full.union(["extra"]) { try Data(name.utf8).write(to: tree.appendingPathComponent(name)) }
        let archive = tmp.appendingPathComponent("inputs.zip")
        func pack() throws {
            try? fm.removeItem(at: archive)
            _ = try output(["/usr/bin/zip", "-qyr", archive.path, bundle], at: tmp)
        }
        for includesCore in [true, false] {
            if !includesCore { try fm.removeItem(at: tree.appendingPathComponent("xray")) }
            try pack()
            for mode in ["full", "--data-only"] {
                let dest = tmp.appendingPathComponent(UUID().uuidString)
                let args = [archive.path, bundle, dest.path, "pinned", mode]
                if !includesCore && mode == "full" {
                    XCTAssertThrowsError(try extractCoreBundle(args))
                    XCTAssertFalse(fm.fileExists(atPath: dest.path))
                } else {
                    try extractCoreBundle(args)
                    let names = mode == "full" ? full : data
                    let receipt = try readObject(dest.appendingPathComponent("core-bundle-source.json"))
                    let hashes = Dictionary(uniqueKeysWithValues: names.map { ($0, digest(Data($0.utf8))) })
                    XCTAssertEqual(receipt["files"] as? [String: String], hashes)
                    XCTAssertEqual(receipt["archiveSHA256"] as? String, try fileDigest(archive))
                    XCTAssertEqual(receipt["commit"] as? String, "pinned")
                    var actual = Set<String>()
                    try visitFiles(dest) { _, relative in actual.insert(relative) }
                    XCTAssertEqual(actual, names.union(["core-bundle-source.json"]))
                    if mode == "full" { XCTAssertTrue(fm.isExecutableFile(atPath: dest.appendingPathComponent("xray/xray").path)) }
                }
            }
        }
        let unsafe = tree.appendingPathComponent("link")
        try fm.createSymbolicLink(atPath: unsafe.path, withDestinationPath: "../outside")
        try pack()
        let dest = tmp.appendingPathComponent("rejected")
        XCTAssertThrowsError(try extractCoreBundle([archive.path, bundle, dest.path, "pinned", "--data-only"]))
        XCTAssertFalse(fm.fileExists(atPath: dest.path))
        try fm.removeItem(at: unsafe)
        try Data("escape".utf8).write(to: tmp.appendingPathComponent(bundle + "/escape"))
        // zip retains ".." in the entry name when given a relative path.
        try pack()
        _ = try output(["/usr/bin/zip", "-q", archive.path, bundle + "/bin/../escape"], at: tmp)
        XCTAssertThrowsError(try extractCoreBundle([archive.path, bundle, dest.path, "pinned", "--data-only"]))
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fetch-macos-cores.sh")
        XCTAssertThrowsError(try output(["env", "CORE_BUNDLE_REF=wrong", "bash", script.path, "osx-arm64", dest.path, "--data-only"]))
        XCTAssertFalse(fm.fileExists(atPath: dest.path))
    }
}
