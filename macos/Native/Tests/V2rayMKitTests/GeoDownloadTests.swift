import Foundation
import XCTest
@testable import V2rayMKit

final class GeoDownloadTests: XCTestCase {
    func testDownloadsRejectBadHeadersAndBoundIdleAndTricklingPeers() async throws {
        let script = try XCTUnwrap(Bundle.module.url(forResource: "LoopbackPeer", withExtension: "swift", subdirectory: "Fixtures"))
        let peer = Process(), input = Pipe(), output = Pipe()
        peer.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        peer.arguments = [script.path, "geo"]
        peer.standardInput = input
        peer.standardOutput = output
        try peer.run()
        defer { try? input.fileHandleForWriting.close(); peer.waitUntilExit() }
        let port = try XCTUnwrap(Int(String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func download(_ scenario: String, idle: TimeInterval, total: TimeInterval) async throws {
            try await NativeGeoAssets.download(to: directory, source: "http://127.0.0.1:\(port)/\(scenario)/{0}.dat",
                proxyEndpoints: nil, idleTimeout: idle, fileTimeout: total) { _, _, _ in }
        }
        for (scenario, idle, total, expected) in [("failure", 5.0, 10.0, "HTTP 503"), ("oversized", 5, 10, "大小上限"),
                                                 ("unbounded", 5, 10, "大小上限"), ("idle", 1, 10, "下载超时"),
                                                 ("trickle", 4, 2, "下载超时")] {
            let start = ProcessInfo.processInfo.systemUptime
            do { try await download(scenario, idle: idle, total: total); XCTFail("unexpected success: \(scenario)") }
            catch let failure as ClientFailure {
                XCTAssertTrue(failure.detail?.contains("geoip.dat") == true)
                XCTAssertTrue(failure.detail?.contains(expected) == true, "\(scenario): \(failure)")
            }
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 6, scenario)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [], scenario)
        }
        let cancelled = Task { try await download("trickle", idle: 5, total: 10) }
        try await Task.sleep(for: .milliseconds(250))
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("cancelled transfer succeeded") } catch is CancellationError {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        try await download("redirect", idle: 5, total: 10)
        for name in NativeGeoAssets.names {
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(name + ".dat")), Data(repeating: 118, count: 1024 * 1024))
        }
    }
}
