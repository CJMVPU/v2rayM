import XCTest
import AppKit
import SwiftUI
@testable import V2rayMKit
@testable import V2rayM

@MainActor final class DashboardPlotLayerTests: XCTestCase {
    private func samples(_ count: Int = 61) -> [TrafficTrendSample] {
        (0..<count).map { index in
            TrafficTrendSample(date: Date(timeIntervalSince1970: 1000 + Double(index) * 5),
                upload: Double(index % 13) * 20, download: Double(index % 19) * 100,
                directUpload: Double(index % 17) * 40, directDownload: Double(index % 23) * 80, segment: index < 30 ? 1 : 2)
        }
    }
    private func frameConfiguration(animate: Bool = true) -> TrendFrameConfiguration {
        let points = samples()
        let now = points.last!.date
        return TrendFrameConfiguration(input: TrendLayerInput(points), replayInput: TrendLayerInput([]), retired: nil,
            now: now, maximum: 300, animate: animate, presentationActive: true, replaying: false,
            catchUp: nil, retirement: nil, scaleFrom: 100, scaleTo: 300, scaleChanged: now, sampleArrived: now)
    }
    func testNativeFrameInterpolationAndPausedDate() {
        let configuration = frameConfiguration()
        let frame = configuration.frame(at: configuration.now.addingTimeInterval(0.6))
        XCTAssertEqual(frame.ceiling, 200, accuracy: 0.0001)
        XCTAssertEqual(frame.reveal, 0.5, accuracy: 0.0001)
        XCTAssertEqual(frame.date, configuration.now.addingTimeInterval(0.6))
        XCTAssertTrue(configuration.enabled)
        let paused = frameConfiguration(animate: false)
        let stopped = paused.frame(at: paused.now.addingTimeInterval(10))
        XCTAssertEqual(stopped.date, paused.now); XCTAssertEqual(stopped.ceiling, 300)
        XCTAssertEqual(stopped.reveal, 1); XCTAssertFalse(paused.enabled)
    }
    func testNativeClockRejectsStaleConfigurationUntilWindowThaws() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 550, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = TrendLayerView(frame: window.contentLayoutRect)
        window.contentView = view; view.layout()
        defer { view.freeze(); window.close() }
        let configuration = frameConfiguration()
        view.configure(configuration)
        XCTAssertTrue(view.clock.isRunning)
        NotificationCenter.default.post(name: .dashboardWillFreeze, object: window)
        let position = view.current.root.position
        view.configure(configuration)
        view.clock.onFrame?(configuration.now.addingTimeInterval(5))
        XCTAssertFalse(view.clock.isRunning)
        XCTAssertEqual(view.current.root.position, position)
        NotificationCenter.default.post(name: .dashboardDidThaw, object: window)
        XCTAssertTrue(view.clock.isRunning)
        view.clock.onFrame?(configuration.now.addingTimeInterval(0.6))
        XCTAssertNotEqual(view.current.root.position, position)
        XCTAssertEqual(view.current.geometryBuilds, 1)
    }
    func testSteadyScrollingAndRevealReuseHistoryAndGrid() {
        let view = TrendLayerView(frame: CGRect(x: 0, y: 0, width: 550, height: 100))
        view.layout()
        let input = TrendLayerInput(samples())
        let now = input.samples.last!.date
        func update(_ frame: Int, reveal: Double = 1, ceiling: Double = 2400) {
            view.update(input: input, date: now.addingTimeInterval(Double(frame) / 120), ceiling: ceiling, reveal: reveal, opacity: 1)
        }
        update(0)
        for frame in 1...600 { update(frame) }
        XCTAssertEqual(view.current.geometryBuilds, 1)
        XCTAssertEqual(view.current.projections, 1)
        XCTAssertEqual(view.current.tailBuilds, 1)
        XCTAssertEqual(view.gridBuilds, 1)
        for frame in 0..<144 { update(frame, reveal: Double(frame) / 144) }
        XCTAssertEqual(view.current.geometryBuilds, 1)
        XCTAssertEqual(view.current.projections, 1, "A growing endpoint must not project the historical curves")
        for frame in 0..<144 { update(frame, ceiling: 2400 + Double(frame)) }
        XCTAssertEqual(view.current.geometryBuilds, 1, "Vertical rescaling must reuse data-space geometry")
        XCTAssertEqual(view.gridBuilds, 1)
        view.freeze()
        let position = view.current.root.position
        update(9999)
        XCTAssertEqual(view.current.root.position, position, "Late frame updates must not move the frozen surface")
    }
    func testEqualPublicationsReuseGeometryButNewSampleRebuilds() {
        let group = TrendLayerGroup(), points = samples()
        let now = points.last!.date
        for _ in 0..<10 {
            group.update(input: TrendLayerInput(points), date: now, ceiling: 2400, reveal: 1, opacity: 1, size: CGSize(width: 550, height: 100))
        }
        XCTAssertEqual(group.geometryBuilds, 1)
        group.update(input: TrendLayerInput(samples(62)), date: now, ceiling: 2400, reveal: 1, opacity: 1, size: CGSize(width: 550, height: 100))
        XCTAssertEqual(group.geometryBuilds, 2)
    }
    func testDiscontinuitiesRemainSeparateAndOnlyLastConnectedSegmentIsTail() {
        var points = samples(4)
        points[2] = TrafficTrendSample(date: points[2].date, upload: 1, download: 2, directUpload: 3, directDownload: 4, segment: 8)
        let geometry = TrendLayerGeometry(points)
        for series in geometry.series {
            XCTAssertEqual(series.dots.count, 3)
            XCTAssertNil(series.tail, "Different sessions must not acquire a tail bridge")
        }
        let connected = TrendLayerGeometry(samples(4))
        XCTAssertEqual(connected.series[0].tail?.0.x, 10)
        XCTAssertEqual(connected.series[0].tail?.1.x, 15)
        var gaps = samples(2)
        gaps[1] = TrafficTrendSample(date: gaps[0].date.addingTimeInterval(12), upload: 0, download: 0, directUpload: 0, directDownload: 0, segment: 1)
        XCTAssertNil(TrendLayerGeometry(gaps).series[0].tail)
    }
    func testLongSleepUsesBoundedBucketsWithoutBridgingMissingHistory() {
        let earlier = samples()
        let later = earlier.map { TrafficTrendSample(date: $0.date.addingTimeInterval(7 * 86400),
            upload: $0.upload, download: $0.download, directUpload: $0.directUpload,
            directDownload: $0.directDownload, segment: $0.segment + 10) }
        let input = TrendLayerInput(earlier + later)
        XCTAssertEqual(input.selected(bucket: input.bucket(at: earlier.last!.date)), earlier)
        XCTAssertEqual(input.selected(bucket: input.bucket(at: later.last!.date)), later)
        XCTAssertTrue(input.selected(bucket: input.bucket(at: earlier.last!.date.addingTimeInterval(3600))).isEmpty)
    }
    func testProjectionPreservesStrokeWidthDotSizeAndLatestEndpoint() throws {
        let input = TrendLayerInput(samples(4)), group = TrendLayerGroup()
        let now = input.samples.last!.date
        for ceiling in [100.0, 2400.0, 10000.0] {
            group.update(input: input, date: now, ceiling: ceiling, reveal: 1, opacity: 1, size: CGSize(width: 550, height: 100))
            let layers = try XCTUnwrap(group.root.sublayers)
            let tail = try XCTUnwrap(layers[1] as? CAShapeLayer)
            let dots = try XCTUnwrap(layers[2] as? CAShapeLayer)
            XCTAssertEqual(tail.lineWidth, 1.5)
            XCTAssertEqual(try XCTUnwrap(dots.path).boundingBoxOfPath.height, 2.4, accuracy: 0.00001)
            let end = try XCTUnwrap(tail.path).currentPoint
            XCTAssertEqual(end.x + group.root.position.x, 548, accuracy: 0.00001)
            XCTAssertEqual(end.y, 97 - input.samples.last!.upload / ceiling * 94, accuracy: 0.00001)
        }
    }
    func testRingRetainsFullPathAndFreezesPresentationUntilThaw() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = RingLayerView(frame: window.contentLayoutRect)
        window.contentView = view; view.layout()
        defer { window.close() }
        let path = view.arc.path
        view.update(fraction: 0.2, color: NSColor.cyan.cgColor, animate: false)
        view.update(fraction: 0.8, color: NSColor.cyan.cgColor, animate: true)
        XCTAssertNotNil(view.arc.animation(forKey: "endpoint"))
        NotificationCenter.default.post(name: .dashboardWillFreeze, object: window)
        let frozen = view.arc.strokeEnd
        XCTAssertNil(view.arc.animation(forKey: "endpoint"))
        view.update(fraction: 1, color: NSColor.cyan.cgColor, animate: true)
        XCTAssertEqual(view.arc.strokeEnd, frozen)
        NotificationCenter.default.post(name: .dashboardDidThaw, object: window)
        view.update(fraction: 0.4, color: NSColor.cyan.cgColor, animate: true)
        XCTAssertNotNil(view.arc.animation(forKey: "endpoint"))
        XCTAssertEqual(view.arc.path, path)
        XCTAssertEqual(view.pathBuilds, 1)
    }

    /// Opt-in CPU microbenchmark. Includes layer-property updates, but does not
    /// measure GPU execution, WindowServer composition or actual display FPS.
    func testGeometryCPUComparison() throws {
        guard let output = ProcessInfo.processInfo.environment["V2RAYM_PLOT_BENCHMARK"] else {
            throw XCTSkip("Set V2RAYM_PLOT_BENCHMARK for geometry CPU comparison")
        }
        let points = samples(), input = TrendLayerInput(points), size = CGSize(width: 550, height: 100)
        let now = points.last!.date
        var checksum = 0.0
        func legacy(date: Date, ceiling: Double, reveal: Double) {
            for key in [\TrafficTrendSample.upload, \.download, \.directUpload, \.directDownload] {
                var line = Path(), dots = Path()
                var previous: TrafficTrendSample?, position: CGPoint?
                for point in points {
                    var next = CGPoint(x: 2 + (1 - date.timeIntervalSince(point.date) / 300) * (size.width - 4),
                                       y: size.height - 3 - point[keyPath: key] / ceiling * (size.height - 6))
                    if let previous, let position, previous.segment == point.segment, point.date.timeIntervalSince(previous.date) < 12 {
                        if point.id == points.last?.id { next = CGPoint(x: position.x + (next.x - position.x) * reveal, y: position.y + (next.y - position.y) * reveal) }
                        let mid = (position.x + next.x) / 2
                        line.addCurve(to: next, control1: CGPoint(x: mid, y: position.y), control2: CGPoint(x: mid, y: next.y))
                    } else { line.move(to: next); dots.addEllipse(in: CGRect(x: next.x - 1.2, y: next.y - 1.2, width: 2.4, height: 2.4)) }
                    previous = point; position = next
                }
                checksum += (line.isEmpty ? 0 : 1) + (dots.isEmpty ? 0 : 1)
            }
        }
        var results: [String: Any] = [:]
        for scenario in ["reveal", "scale", "steady"] {
            var oldTimes: [Double] = [], newTimes: [Double] = []
            for round in 0..<7 {
                let group = TrendLayerGroup()
                group.update(input: input, date: now, ceiling: 2400, reveal: 1, opacity: 1, size: size)
                func run(_ old: Bool) -> Double {
                    let start = ProcessInfo.processInfo.systemUptime
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    for frame in 0..<1200 {
                        let phase = Double(frame % 144) / 144
                        let date = now.addingTimeInterval(Double(frame) / 120)
                        let ceiling = scenario == "scale" ? 2400 + phase * 1200 : 2400
                        let reveal = scenario == "reveal" ? phase : 1
                        // Old settled mode already cached paths: no geometry work.
                        if old { if scenario != "steady" { legacy(date: date, ceiling: ceiling, reveal: reveal) } }
                        else { group.update(input: input, date: date, ceiling: ceiling, reveal: reveal, opacity: 1, size: size) }
                    }
                    CATransaction.commit()
                    return (ProcessInfo.processInfo.systemUptime - start) * 1000
                }
                if round % 2 == 0 { oldTimes.append(run(true)); newTimes.append(run(false)) }
                else { newTimes.append(run(false)); oldTimes.append(run(true)) }
            }
            results[scenario] = ["oldMilliseconds": oldTimes, "newMilliseconds": newTimes, "framesPerRound": 1200]
        }
        results["checksum"] = checksum
        results["scope"] = "CPU geometry/property updates only; old steady excludes Canvas paint and is not an end-to-end comparison"
        try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    }
}
