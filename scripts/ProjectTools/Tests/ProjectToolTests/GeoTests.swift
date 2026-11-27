import Foundation
import XCTest
@testable import ProjectTool

final class GeoTests: XCTestCase {
    func testDownloadedAndExplicitInputUseSamePinAndTables() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let target = root.appendingPathComponent("macos/Native/Sources/V2rayM/Resources/Globe")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try fm.createDirectory(at: lockFile(root).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("DB-IP".utf8).write(to: target.appendingPathComponent("ATTRIBUTION.txt"))
        let archive = root.appendingPathComponent("fixture.csv.gz")
        let sample = "1.0.0.1,1.0.0.2,NA,US,,\"Some, City\",41,-87\r\n::1,::2,EU,FR,,Paris,48,2\r\n"
        try output(["/usr/bin/gzip", "-c"], input: Data(sample.utf8)).write(to: archive)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let server = Process(), control = Pipe(), ready = Pipe()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        server.arguments = [repo.appendingPathComponent("macos/Native/Tests/V2rayMKitTests/Fixtures/LoopbackPeer.swift").path, "build-geo", archive.path]
        server.standardInput = control
        server.standardOutput = ready
        try server.run()
        defer { try? control.fileHandleForWriting.close(); server.waitUntilExit() }
        let port = try XCTUnwrap(Int(String(decoding: ready.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let base = "http://127.0.0.1:\(port)"
        let sha = try fileDigest(archive)
        func setPin(_ hash: String, path: String = "/archive") throws {
            try writeObject(["geolocation": ["sha256": hash, "sourceURL": base + path, "file": archive.lastPathComponent]], to: lockFile(root))
        }
        XCTAssertThrowsError(try output(["/usr/bin/curl", "-fsS", base + "/archive"]))
        try setPin(sha, path: "/denied")
        XCTAssertThrowsError(try prepareGeo(root: root, args: []))
        try setPin("wrong")
        for options in [[], ["--source", archive.path]] {
            XCTAssertThrowsError(try prepareGeo(root: root, args: options))
            XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("places.bin").path))
        }
        try setPin(sha)
        try prepareGeo(root: root, args: [])
        try prepareGeo(root: root, args: ["--verify-only"])
        let before = try geoNames.map { try fileDigest(target.appendingPathComponent($0)) }
        try prepareGeo(root: root, args: ["--source", archive.path])
        XCTAssertEqual(try geoNames.map { try fileDigest(target.appendingPathComponent($0)) }, before)
        try Data("modified".utf8).write(to: target.appendingPathComponent("places.bin"))
        XCTAssertThrowsError(try prepareGeo(root: root, args: ["--verify-only"]))
    }
}
