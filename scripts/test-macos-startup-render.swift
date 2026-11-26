// Manual WindowServer regression. Run with xcrun swift (or compile with swiftc).
import AppKit
import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import SQLite3

struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private let files = FileManager.default
private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

struct Gauge: Codable {
    let width: Int, height: Int, brightPixels: Int, threshold: Int, contrast: Int
    var passed: Bool { brightPixels > threshold && contrast > 8 }
}

func measureGauge(_ file: URL) throws -> Gauge {
    guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: file)),
          let image = bitmap.cgImage, image.width >= 400, image.height >= 200 else {
        throw Failure("Invalid window PNG at " + file.path)
    }
    // Left edge of the four permanent gauge tracks. Work in normalized window
    // coordinates so a point-scale window and a Retina capture use the same test.
    let width = image.width, height = image.height
    let left = Int(Double(width) * 0.115), right = Int(Double(width) * 0.175)
    let top = Int(Double(height) * 0.42), bottom = Int(Double(height) * 0.44)
    let w = right - left, h = bottom - top
    guard let crop = image.cropping(to: CGRect(x: left, y: top, width: w, height: h)) else {
        throw Failure("Cannot sample the gauge in " + file.path)
    }
    var pixels = [UInt8](repeating: 0, count: w * h * 4)
    try pixels.withUnsafeMutableBytes { bytes in
        guard let ctx = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw Failure("Cannot decode the sampled pixels")
        }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    var low = 255, high = 0, bright = 0
    for i in stride(from: 0, to: pixels.count, by: 4) {
        let red = Int(pixels[i])
        low = min(low, red); high = max(high, red)
        if red > 45 { bright += 1 }
    }
    let threshold = Int((200 * Double(width) * Double(height) / (1720 * 1200)).rounded())
    return Gauge(width: width, height: height, brightPixels: bright, threshold: threshold, contrast: high - low)
}

final class Interruption: @unchecked Sendable {
    private let lock = NSLock()
    private var interrupted = false
    private var signals: [DispatchSourceSignal] = []
    init() {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.lock.lock(); self.interrupted = true; self.lock.unlock()
            }
            source.resume()
            signals.append(source)
        }
    }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if interrupted { throw Failure("Interrupted") }
    }
}

func stop(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let deadline = now() + 2
    while process.isRunning && now() < deadline { Thread.sleep(forTimeInterval: 0.02) }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
}

func command(_ path: String, _ arguments: [String], until deadline: Double, interruption: Interruption) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    try process.run()
    defer { stop(process) }
    while process.isRunning {
        try interruption.check()
        if now() >= deadline { throw Failure("Timed out running " + path) }
        Thread.sleep(forTimeInterval: 0.01)
    }
    guard process.terminationStatus == 0 else { throw Failure("\(path) exited with \(process.terminationStatus)") }
}

func countProfiles(in data: URL) throws -> Int {
    let file = data.appendingPathComponent("guiConfigs/guiNDB.db")
    var db: OpaquePointer?
    let result = sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READONLY, nil)
    defer { sqlite3_close(db) }
    guard result == SQLITE_OK else { throw Failure("Fresh runtime database is not readable") }
    var stmt: OpaquePointer?
    defer { sqlite3_finalize(stmt) }
    guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM ProfileItem", -1, &stmt, nil) == SQLITE_OK,
          sqlite3_step(stmt) == SQLITE_ROW else { throw Failure("Fresh ProfileItem table is not readable") }
    return Int(sqlite3_column_int64(stmt, 0))
}

struct Sample: Codable {
    let run: Int
    var pid: Int32?
    var firstTrackedSeconds: Double?, firstOpaqueSeconds: Double?, captureSeconds: Double?
    var screenshot: String?, timeoutScreenshot: String?, gauge: Gauge?, profileCount: Int?, error: String?
    var passed = false
}

func sample(_ run: Int, executable: URL, work: URL, output: URL, timeout: Double, interruption: Interruption) -> Sample {
    var sample = Sample(run: run)
    do {
        try interruption.check()
        let data = work.appendingPathComponent("data-\(run)", isDirectory: true)
        let isolatedHome = work.appendingPathComponent("home-\(run)", isDirectory: true)
        try files.createDirectory(at: isolatedHome, withIntermediateDirectories: false)
        let app = Process()
        let logfile = output.appendingPathComponent("app-\(run).log")
        guard files.createFile(atPath: logfile.path, contents: nil) else { throw Failure("Cannot open app log") }
        let log = try FileHandle(forWritingTo: logfile)
        defer { try? log.close() }
        app.executableURL = executable
        app.currentDirectoryURL = work
        app.arguments = ["--data-directory", data.path, "-ApplePersistenceIgnoreState", "YES"]
        app.environment = ["HOME": isolatedHome.path, "CFFIXED_USER_HOME": isolatedHome.path,
                           "TMPDIR": work.path + "/", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        app.standardOutput = log; app.standardError = log
        let start = now(), deadline = start + timeout
        try app.run()
        defer { stop(app) }
        sample.pid = app.processIdentifier
        let file = output.appendingPathComponent("first-\(run).png")
        var lastWindowID: CGWindowID?
        while now() < deadline && sample.screenshot == nil {
            try interruption.check()
            guard app.isRunning else { throw Failure("App exited before capture (status \(app.terminationStatus))") }
            let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
            let window = windows?.first { item in
                guard (item[kCGWindowOwnerPID as String] as? Int32) == app.processIdentifier,
                      (item[kCGWindowLayer as String] as? Int) == 0,
                      let bounds = item[kCGWindowBounds as String] as? [String: Any] else { return false }
                return (bounds["Width"] as? Double ?? 0) > 800 && (bounds["Height"] as? Double ?? 0) > 500
            }
            if let window {
                lastWindowID = window[kCGWindowNumber as String] as? CGWindowID
                if sample.firstTrackedSeconds == nil { sample.firstTrackedSeconds = now() - start }
                if window[kCGWindowIsOnscreen as String] as? Bool == true,
                   (window[kCGWindowAlpha as String] as? Double ?? 0) > 0.99,
                   let id = window[kCGWindowNumber as String] as? Int {
                    sample.firstOpaqueSeconds = now() - start
                    try command("/usr/sbin/screencapture", ["-x", "-o", "-l", String(id), file.path], until: deadline, interruption: interruption)
                    sample.screenshot = file.lastPathComponent
                    sample.captureSeconds = now() - start
                    sample.gauge = try measureGauge(file)
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.004)
        }
        guard sample.screenshot != nil else {
            // A still-transparent window can explain a timeout. Keep it as a
            // diagnostic only, and re-check ownership before asking WindowServer.
            if let id = lastWindowID, app.isRunning,
               let listed = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
               listed.first?[kCGWindowOwnerPID as String] as? Int32 == app.processIdentifier {
                let diagnostic = output.appendingPathComponent("timeout-\(run).png")
                if (try? command("/usr/sbin/screencapture", ["-x", "-o", "-l", String(id), diagnostic.path],
                                 until: now() + 2, interruption: interruption)) != nil {
                    sample.timeoutScreenshot = diagnostic.lastPathComponent
                }
            }
            throw Failure("Timed out waiting for the first opaque app window")
        }
        // SQLite initialization may legitimately complete after the first native
        // frame. Preserve that first screenshot while waiting for the empty store.
        while now() < deadline && sample.profileCount == nil {
            try interruption.check()
            guard app.isRunning else { throw Failure("App exited before database verification") }
            sample.profileCount = try? countProfiles(in: data)
            if sample.profileCount == nil { Thread.sleep(forTimeInterval: 0.025) }
        }
        guard sample.profileCount == 0 else { throw Failure("Expected a readable empty profile database") }
        guard sample.gauge?.passed == true else { throw Failure("First visible frame has no dashboard gauge") }
        sample.passed = true
    } catch { sample.error = error.localizedDescription }
    return sample
}

let usage = """
Usage: xcrun swift scripts/test-macos-startup-render.swift APP_OR_RELEASE_EXECUTABLE --report DIRECTORY [--runs 5] [--timeout 12]
       xcrun swift scripts/test-macos-startup-render.swift --check-image FIRST_FRAME.png [...]
Run the launch test as a normal user in an unlocked macOS GUI session with screen recording access.
The report directory must be empty. Each trial launches a private ad-hoc signed copy with a fresh data directory.
"""

func run(_ args: [String]) throws -> Bool {
    if args == ["--help"] || args == ["-h"] { print(usage); return true }
    if args.first == "--check-image", args.count > 1 {
        var passed = true
        for path in args.dropFirst() {
            let gauge = try measureGauge(URL(fileURLWithPath: path))
            print("\(path): \(gauge.brightPixels) bright pixels, threshold \(gauge.threshold), contrast \(gauge.contrast), \(gauge.passed ? "PASS" : "FAIL")")
            passed = passed && gauge.passed
        }
        return passed
    }
    guard let input = args.first, !input.hasPrefix("-") else { throw Failure(usage) }
    var runs = 5, timeout = 12.0, report: URL?
    var options = args.dropFirst().makeIterator()
    while let key = options.next() {
        guard let value = options.next() else { throw Failure(usage) }
        switch key {
        case "--runs": guard let n = Int(value), n > 0 else { throw Failure(usage) }; runs = n
        // Keep each empty-store launch below the application's first 60s maintenance tick.
        case "--timeout": guard let s = Double(value), s.isFinite, s > 0, s <= 45 else { throw Failure("Timeout must be in (0,45] seconds") }; timeout = s
        case "--report": report = URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
        default: throw Failure(usage)
        }
    }
    guard let output = report else { throw Failure(usage) }
    guard getuid() != 0, geteuid() != 0 else { throw Failure("Launch validation must run as a normal user") }
    guard CGSessionCopyCurrentDictionary() != nil, !NSScreen.screens.isEmpty else { throw Failure("An active WindowServer session is required") }
    let source = URL(fileURLWithPath: input).standardizedFileURL
    let packaged = source.pathExtension == "app"
    let binary = (packaged ? source.appendingPathComponent("Contents/MacOS/V2rayM") : source).resolvingSymlinksInPath()
    let resources = packaged ? source.appendingPathComponent("Contents/Resources") : source.deletingLastPathComponent()
    guard (try? binary.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
          files.isExecutableFile(atPath: binary.path) else { throw Failure("Missing release executable: " + binary.path) }
    try files.createDirectory(at: output, withIntermediateDirectories: true)
    guard try files.contentsOfDirectory(atPath: output.path).isEmpty else { throw Failure("Report directory must be empty") }
    let work = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("v2raym-render-" + UUID().uuidString, isDirectory: true)
    try files.createDirectory(at: work, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? files.removeItem(at: work) }
    let interruption = Interruption()
    let executable = work.appendingPathComponent("V2rayM")
    try files.copyItem(at: binary, to: executable)
    let original = try Data(contentsOf: executable, options: .mappedIfSafe)
    let digest = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
    let fixture: [String: Any] = ["source": source.path, "sourceExecutableSHA256": digest,
        "os": ProcessInfo.processInfo.operatingSystemVersionString, "runs": runs, "timeoutSeconds": timeout]
    try JSONSerialization.data(withJSONObject: fixture, options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("fixture.json"), options: .atomic)
    try command("/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", "v2raym.render-test." + UUID().uuidString, executable.path],
                until: now() + 15, interruption: interruption)
    for name in ["V2rayMNative_V2rayM.bundle", "V2rayMNative_V2rayMKit.bundle"] {
        try files.copyItem(at: resources.appendingPathComponent(name).resolvingSymlinksInPath(), to: work.appendingPathComponent(name))
    }
    var results = [Sample]()
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    for i in 1...runs {
        let trial = sample(i, executable: executable, work: work, output: output, timeout: timeout, interruption: interruption)
        results.append(trial)
        try encoder.encode(results).write(to: output.appendingPathComponent("result.json"), options: .atomic)
        print("Run \(i)/\(runs), \(trial.passed ? "PASS" : (trial.error ?? "FAIL")), bright pixels \(trial.gauge?.brightPixels ?? 0)")
        try interruption.check()
    }
    return results.allSatisfy(\.passed)
}

do { exit(try run(Array(CommandLine.arguments.dropFirst())) ? EXIT_SUCCESS : EXIT_FAILURE) }
catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(EXIT_FAILURE) }
