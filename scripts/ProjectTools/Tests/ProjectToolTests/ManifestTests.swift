import Foundation
import XCTest
@testable import ProjectTool

final class ManifestTests: XCTestCase {
    var root: URL!
    var fm: FileManager { .default }

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try fm.removeItem(at: root) }
    func put(_ name: String, _ text: String) throws {
        let path = root.appendingPathComponent(name)
        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: path)
    }

    func testTrackedUntrackedAndVersionChangesInvalidateSnapshot() throws {
        try put("VERSION", "0.3.3\n")
        try put("macos/Native/fixture.swift", "let x = 1")
        for args in [["git", "init", "-q"], ["git", "add", "."], ["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"]] {
            _ = try output(args, at: root)
        }
        let baseline = try sourceSnapshot(root)
        try assertSource(baseline, root: root)
        for (name, text) in [("new.swift", "untracked"), ("macos/Native/fixture.swift", "changed"), ("VERSION", "0.3.4")] {
            let path = root.appendingPathComponent(name)
            let previous = try? Data(contentsOf: path)
            try put(name, text)
            XCTAssertEqual(try sourceSnapshot(root)["dirty"] as? Bool, true)
            XCTAssertThrowsError(try assertSource(baseline, root: root))
            if let previous { try previous.write(to: path) } else { try fm.removeItem(at: path) }
        }
        try put("VERSION", "0.3.3.1")
        XCTAssertThrowsError(try sourceSnapshot(root))
    }

    func testPackagedArtifactsAndData() throws {
        try put(embeddedLibrary, "library")
        try put("Contents/MacOS/V2rayM", "host")
        let exe = root.appendingPathComponent("Contents/MacOS/V2rayM")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        let helperName = "Contents/MacOS/V2rayMHelper"
        let helper = root.appendingPathComponent(helperName)
        try put(helperName, "host")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        let plist = root.appendingPathComponent("Contents/Info.plist")
        var info = ["CFBundleShortVersionString": "0.3.6", "CFBundleVersion": "0.3.6", "CFBundleExecutable": "V2rayM"]
        func saveInfo() throws { try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist) }
        try saveInfo()
        let dir = root.appendingPathComponent("Contents/Resources/Backend/bin")
        let dat = ["geoip.dat", "geosite.dat"]
        for name in dat { try put("Contents/Resources/Backend/bin/" + name, name) }
        let hashes = Dictionary(uniqueKeysWithValues: dat.map { ($0, digest(Data($0.utf8))) })
        let inputs: Object = ["coreBundleDataSHA256": hashes, "coreBundleCommit": "pinned"]
        var receipt: Object = ["source": ["version": "0.3.6"], "artifacts": [embeddedLibrary: digest(Data("library".utf8)), helperName: digest(Data("host".utf8))], "resourceDigests": [:] as [String: String], "runtimeData": try runtimeData(dir, inputs: inputs)]
        func verify() throws { try verifyApp(root, receipt: receipt, inputs: inputs) }
        try verify()
        let artifacts: [String: String] = try receipt.required("artifacts")
        try fm.removeItem(at: helper)
        receipt["artifacts"] = artifacts.filter { $0.key != helperName }
        XCTAssertThrowsError(try verify())
        try put(helperName, "host")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        XCTAssertThrowsError(try verify())
        receipt["artifacts"] = artifacts
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: helper.path)
        XCTAssertThrowsError(try verify())
        try fm.removeItem(at: helper)
        try fm.createSymbolicLink(at: helper, withDestinationURL: exe)
        XCTAssertThrowsError(try verify())
        try fm.removeItem(at: helper)
        try put(helperName, "host")
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        try verify()
        for extra in ["Contents/MacOS/other-core", "Contents/libcoreclr.dylib", "Contents/libhostfxr.dylib", "Contents/ServiceLib.dll", "Contents/v2rayN.WebAPI", "Contents/v2rayN.WebAPI.runtimeconfig.json", "Contents/xray", "Contents/Resources/stale.py", "Contents/libpython3.dylib"] {
            try put(extra, "")
            XCTAssertThrowsError(try verify(), extra)
            try fm.removeItem(at: root.appendingPathComponent(extra))
        }
        for key in info.keys.sorted() {
            let original = info.updateValue("wrong", forKey: key)
            try saveInfo()
            XCTAssertThrowsError(try verify(), key)
            info[key] = original
            try saveInfo()
        }
        for name in dat {
            try Data("changed".utf8).write(to: dir.appendingPathComponent(name))
            XCTAssertThrowsError(try verify())
            try Data(name.utf8).write(to: dir.appendingPathComponent(name))
        }
        let originFile = dir.appendingPathComponent("core-bundle-source.json")
        let origin: Object = ["repository": "2dust/v2rayN-core-bin", "commit": "pinned", "files": hashes]
        for (key, value) in [("repository", "other" as Any), ("commit", "other"), ("files", [:] as Object)] {
            var invalid = origin
            invalid[key] = value
            try writeObject(invalid, to: originFile)
            XCTAssertThrowsError(try runtimeData(dir, inputs: inputs))
        }
        try writeObject(origin, to: originFile)
        for wrong in [[:], ["geoip.dat": hashes["geoip.dat"]!], hashes.merging(["extra": "invalid"]) { $1 }] {
            receipt["runtimeData"] = ["origin": origin, "SHA256": wrong] as Object
            XCTAssertThrowsError(try verify())
        }
        receipt["runtimeData"] = try runtimeData(dir, inputs: inputs)
        try verify()
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: exe.path)
        XCTAssertThrowsError(try verify())
        try fm.removeItem(at: exe)
        XCTAssertThrowsError(try verify())
        let lib = root.appendingPathComponent(embeddedLibrary)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lib.path)
        try fm.createSymbolicLink(at: exe, withDestinationURL: lib)
        XCTAssertThrowsError(try verify())
    }

    func testPinnedCoreAndEmbeddedPatchProvenance() throws {
        let common = "common.patch", extra = "embedded.patch"
        for name in [common, extra] { try put("patches/xray/" + name, name) }
        let pin: Object = ["revision": "revision", "sourceSHA256": "archive", "patches": [common: digest(Data(common.utf8))], "version": "1.2.3", "buildMarker": "fixed-m2"]
        let libraryPatches = [extra: digest(Data(extra.utf8))]
        let inputs: Object = ["xray": pin, "xrayLibraryPatches": libraryPatches, "goVersion": "1.27.3"]
        try put("contracts/macos-build-inputs.json", "")
        try writeObject(inputs, to: lockFile(root))
        let source = "Xray source: revision\nArchive SHA256: archive\nPatches: common.patch\nBuild: fixed-m2\n"
        try put("xray/SOURCE.txt", source)
        let version = "Xray 1.2.3 fixture fixed-m2 (go1.27.3 darwin/arm64)"
        try verifyCore(root: root, directory: root, versionOutput: version)
        for (from, to) in [("fixed-m2", ""), ("fixed-m2", "fixed-m1"), ("1.27.3", "1.27.2")] {
            XCTAssertThrowsError(try verifyCore(root: root, directory: root, versionOutput: version.replacingOccurrences(of: from, with: to)))
        }
        try put("xray/SOURCE.txt", source.replacingOccurrences(of: common, with: "other"))
        XCTAssertThrowsError(try verifyCore(root: root, directory: root, versionOutput: version))
        try put("lib.dylib", "fixture")
        let lib = root.appendingPathComponent("lib.dylib")
        let bridge = "scripts/xray/library/main.go"
        try put(bridge, "bridge")
        try writeLibraryReceipt(root: root, binary: lib)
        try verifyLibrary(root: root, library: lib)
        try put(bridge, "changed")
        XCTAssertThrowsError(try verifyLibrary(root: root, library: lib))
        try fm.removeItem(at: root.appendingPathComponent(bridge))
        XCTAssertThrowsError(try writeLibraryReceipt(root: root, binary: lib))
        XCTAssertThrowsError(try verifyLibrary(root: root, library: lib))
        try put(bridge, "bridge")
        try put("lib.dylib", "changed")
        XCTAssertThrowsError(try verifyLibrary(root: root, library: lib))
        try put("lib.dylib", "fixture")
        for name in [common, extra] {
            try put("patches/xray/" + name, "changed")
            XCTAssertThrowsError(try verifyLibrary(root: root, library: lib))
            try put("patches/xray/" + name, name)
        }
    }
}
