import Foundation
import Darwin
import XCTest
@testable import V2rayMKit

final class RotatingProcessLogTests: XCTestCase {
    func testLargeWritesKeepOnlyTwoBoundedFilesAndPrivatePermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("current.log"), previous = root.appendingPathComponent("previous.log")
        let output = try RotatingProcessLog(current: current, previous: previous, maximumBytes: 16)
        let payload = Data((0..<47).map(UInt8.init))
        try output.append(payload)
        output.finish()
        XCTAssertEqual(try Data(contentsOf: previous), payload[16..<32])
        XCTAssertEqual(try Data(contentsOf: current), payload[32..<47])
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: current.path)[.posixPermissions] as? Int, 0o600)
    }
    func testOversizedLegacyLogIsTrimmedAtStartup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("current.log"), previous = root.appendingPathComponent("previous.log")
        let legacy = Data((0..<100).map(UInt8.init))
        try legacy.write(to: current)
        let output = try RotatingProcessLog(current: current, previous: previous, maximumBytes: 16)
        output.finish()
        XCTAssertEqual(try Data(contentsOf: previous), legacy.suffix(16))
        XCTAssertEqual(try Data(contentsOf: current).count, 0)
    }
    func testFinishDoesNotWaitForAnInheritedWriterToClose() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("current.log"), previous = root.appendingPathComponent("previous.log")
        let output = try RotatingProcessLog(current: current, previous: previous, maximumBytes: 1024)
        let inherited = dup(output.pipe.fileHandleForWriting.fileDescriptor)
        XCTAssertGreaterThanOrEqual(inherited, 0)
        defer { if inherited >= 0 { Darwin.close(inherited) } }
        try output.pipe.fileHandleForWriting.write(contentsOf: Data("tail".utf8))
        output.didStart()
        let start = Date()
        output.finish()
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertEqual(try String(contentsOf: current, encoding: .utf8), "tail")
    }
    func testChildOutputIsContinuouslyDrainedAndFinalBytesAreRetained() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("current.log"), previous = root.appendingPathComponent("previous.log")
        let output = try RotatingProcessLog(current: current, previous: previous, maximumBytes: 1024)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "i=0; while [ $i -lt 10000 ]; do echo fixture-output; i=$((i+1)); done; echo FINAL"]
        process.standardOutput = output.pipe; process.standardError = output.pipe
        try process.run(); output.didStart(); process.waitUntilExit(); output.finish()
        XCTAssertEqual(process.terminationStatus, 0)
        let latest = try Data(contentsOf: current), old = try Data(contentsOf: previous)
        XCTAssertLessThanOrEqual(latest.count, 1024); XCTAssertLessThanOrEqual(old.count, 1024)
        XCTAssertTrue(String(decoding: latest, as: UTF8.self).hasSuffix("FINAL\n"))
    }
}
