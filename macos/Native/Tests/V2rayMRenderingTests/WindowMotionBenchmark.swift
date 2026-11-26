import XCTest
import SwiftUI
import RealityKit
import ScreenCaptureKit
import CoreImage
import ImageIO
@testable import V2rayM
@testable import V2rayMKit

/// Opt-in: sample only this fixture window, including its composited native and
/// RealityKit layers. An optional preview captures one synthetic settings turn.
private final class FrameSampler: NSObject, SCStreamOutput {
    struct Frame: Codable {
        let time: Double
        let ring: UInt64
        let page: UInt64
    }
    let queue = DispatchQueue(label: "v2rayM.window-benchmark")
    private(set) var frames: [Frame] = []
    private var previewWindow: ClosedRange<Double>?
    private var previewFrames: [(Double, CGImage)] = []
    private lazy var context = CIContext()
    func beginPreview(at time: Double) { previewWindow = time...(time + 1.15) }
    func writePreview(to url: URL) throws {
        let frames = previewFrames
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, frames.count, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for (index, frame) in frames.enumerated() {
            let delay = index + 1 < frames.count ? max(0.02, frames[index+1].0 - frame.0) : 1
            CGImageDestinationAddImage(destination, frame.1,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let info = (CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]])?.first, (info[.status] as? Int) == SCFrameStatus.complete.rawValue,
              let buffer = sample.imageBuffer else { return }
        let time = sample.presentationTimeStamp.seconds
        if previewWindow?.contains(time) == true, time - (previewFrames.last?.0 ?? 0) >= 0.026 {
            let image = CIImage(cvPixelBuffer: buffer)
            if let frame = context.createCGImage(image, from: image.extent) { previewFrames.append((time, frame)) }
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let pixels = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return }
        let strideBytes = CVPixelBufferGetBytesPerRow(buffer)
        var ring: UInt64 = 0, page: UInt64 = 0
        for y in stride(from: 30, to: CVPixelBufferGetHeight(buffer), by: 2) {
            let row = pixels.advanced(by: y * strideBytes)
            for x in stride(from: 0, to: CVPixelBufferGetWidth(buffer), by: 2) {
                let i = 4*x
                let b = Int(row[i]), g = Int(row[i+1]), r = Int(row[i+2])
                if x < 280 && y < 230 && max(r,g,b) - min(r,g,b) > 65 {
                    ring = ring &* 31 &+ UInt64(y*512+x)
                }
                if x % 6 == 0 && y % 6 == 0 {
                    page = page &* 31 &+ UInt64((r+g+b)/24)
                }
            }
        }
        frames.append(Frame(time: sample.presentationTimeStamp.seconds, ring: ring, page: page))
    }
}

@MainActor final class WindowMotionBenchmark: XCTestCase {
    func testCompositedRingAndNavigation() async throws {
        guard let path = ProcessInfo.processInfo.environment["V2RAYM_WINDOW_BENCHMARK"] else {
            throw XCTSkip("Set V2RAYM_WINDOW_BENCHMARK to a JSON output file")
        }
        AppFont.register()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = AppModel(dataDirectory: directory)
        model.ready = true
        model.systemProxyEnabled = true
        model.profiles = try JSONDecoder().decode([Profile].self, from: Data("""
        [{"indexId":"test","remarks":"测试节点","protocol":"vless","address":"example.invalid","port":443,"network":"xhttp","coreType":"Xray","delay":42,"isCurrent":true,"totalUp":1024,"totalDown":2048,"canTest":true}]
        """.utf8))
        let formatter = ISO8601DateFormatter()
        let start = Date().addingTimeInterval(-360)
        func traffic(_ date: Date, _ rate: Int) throws {
            let data = """
            {"coreRunning":true,"xrayAvailable":true,"runtimeState":"running","runningProfileId":"test","coreStartedAt":"\(formatter.string(from:start))","trafficEnabled":true,"traffic":{"proxyUp":\(rate),"proxyDown":\(rate*2),"directUp":\(rate*3),"directDown":\(rate*4),"sampleSeconds":60,"sampledAt":"\(formatter.string(from:date))"}}
            """
            let status = try JSONDecoder().decode(RuntimeStatus.self, from: Data(data.utf8))
            model.telemetry.record(status, now: date)
            model.status = status
            model.lastStatusRefresh = date
        }
        let now = Date()
        for i in 0...60 { try traffic(now.addingTimeInterval(Double(i-60)*5), 1000 + i%5*500) }
        let entries = (1...90).map { LogEntry(timestamp: formatter.string(from: now), source: "core",
            message: "from tcp:127.0.0.1:1234 accepted tcp:192.0.2.\($0):443 [socks >> proxy]", sequence: Int64($0)) }
        model.dashboard.update(state: try XCTUnwrap(model.status), node: nil, recent: GlobeConnection.recent(entries, previous: [], since: .distantPast))
        model.logState.entries = entries
        let window = NSWindow(contentRect: .init(x: 100, y: 100, width: 860, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ContentView().environmentObject(model)
            .environment(\.dashboardVisibilityOverride, true).font(AppFont.body)
            .buttonStyle(HoverButtonStyle()).environment(\.colorScheme, .dark))
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        try await Task.sleep(for: .seconds(1))
        func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
        func click(_ page: Page) async throws {
            func ready() -> NSButton? { views(host).compactMap { $0 as? NSButton }.first { $0.toolTip == page.rawValue && $0.isEnabled } }
            let deadline = ContinuousClock.now + .seconds(2)
            while ready() == nil && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            let button = try XCTUnwrap(ready(), "Unavailable navigation target: " + page.rawValue)
            button.sendAction(button.action, to: button.target)
        }
        let source = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let target = try XCTUnwrap(source.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let config = SCStreamConfiguration()
        config.width = 430
        config.height = 300
        config.ignoreShadowsSingleWindow = true
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let hz = window.screen?.maximumFramesPerSecond ?? 60
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(hz))
        let sampler = FrameSampler()
        let stream = SCStream(filter: .init(desktopIndependentWindow: target), configuration: config, delegate: nil)
        try stream.addStreamOutput(sampler, type: .screen, sampleHandlerQueue: sampler.queue)
        try await stream.startCapture()
        let stage = try XCTUnwrap(views(host).compactMap { $0 as? RealityStageView }.first)
        var updates: [Double] = []
        func clock() -> Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
        let ticks = stage.renderer.scene.subscribe(to: SceneEvents.Update.self) { _ in updates.append(clock()) }
        struct Span: Codable {
            let name: String
            let start, end: Double
            let meshes: Int
        }
        var spans: [Span] = []
        func measure(_ name: String, _ work: () async throws -> Void) async throws {
            let start = clock(), meshes = stage.owner.meshBuilds
            try await work()
            spans.append(.init(name: name, start: start, end: clock(), meshes: stage.owner.meshBuilds - meshes))
        }
        try await Task.sleep(for: .milliseconds(300))
        let preview = ProcessInfo.processInfo.environment["V2RAYM_TURN_PREVIEW"]
        for round in 0..<3 {
            try await measure("ring") {
                try traffic(Date(), round == 1 ? 2800 : 260)
                try await Task.sleep(for: .milliseconds(1250))
            }
            for page in [Page.logs, .home, .settings, .home, .profiles, .home] {
                try await measure("cube-" + page.rawValue) {
                    if preview != nil, round == 0, page == .settings {
                        let time = clock()
                        sampler.queue.sync { sampler.beginPreview(at: time) }
                    }
                    try await click(page)
                    try await Task.sleep(for: .milliseconds(780))
                }
                try await Task.sleep(for: .milliseconds(100))
            }

        }
        ticks.cancel()
        try await stream.stopCapture()
        if let preview { try sampler.queue.sync { try sampler.writePreview(to: URL(fileURLWithPath: preview)) } }
        struct Result: Codable {
            let hz: Int
            let spans: [Span]
            let updates: [Double]
            let frames: [FrameSampler.Frame]
        }
        let frames = sampler.queue.sync { sampler.frames }
        for span in spans {
            let samples = frames.filter { span.start <= $0.time && $0.time <= span.end }
            let signatures = samples.map { span.name == "ring" ? $0.ring : $0.page }
            XCTAssertGreaterThan(Set(signatures).count, 2, "No measurable motion in " + span.name)
        }
        try JSONEncoder().encode(Result(hz: hz, spans: spans, updates: updates, frames: frames)).write(to: URL(fileURLWithPath: path))
    }
}
