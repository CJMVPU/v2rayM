import XCTest
import AppKit
import SwiftUI
@testable import V2rayMKit
@testable import V2rayM

@MainActor final class DashboardPlotLayerTests: XCTestCase {
    private func samples(_ count: Int = 61) -> [TrafficTrendSample] {
        (0..<count).map { index -> TrafficTrendSample in
            let date = Date(timeIntervalSince1970: 1000 + Double(index) * 5)
            let upload = Double(index % 13) * 20
            let download = Double(index % 19) * 100
            let directUpload = Double(index % 17) * 40
            let directDownload = Double(index % 23) * 80
            return TrafficTrendSample(date: date, upload: upload, download: download,
                directUpload: directUpload, directDownload: directDownload, segment: index < 30 ? 1 : 2)
        }
    }
    private func frameConfiguration(animate: Bool = true, supplied: [TrafficTrendSample]? = nil,
                                    at date: Date? = nil, resume: TrafficTrendCatchUp? = nil,
                                    reduced: Bool = false) -> TrendFrameConfiguration {
        let points = supplied ?? samples()
        let now = date ?? points.last!.date
        return TrendFrameConfiguration(input: TrendLayerInput(points), retired: nil,
            now: now, maximum: 300, animate: animate, presentationActive: true, reduceMotion: reduced,
            catchUp: resume, retirement: nil, scaleFrom: 100, scaleTo: 300, scaleChanged: now, sampleArrived: now)
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
        XCTAssertFalse(view.clock.isRunning, "A stale snapshot cannot scroll through the background interval")
        let resume = TrafficTrendCatchUp(previous: TrafficTrend(), displayedAt: configuration.now, resumedAt: Date())
        view.configure(frameConfiguration(resume: resume))
        XCTAssertTrue(view.clock.isRunning)
    }

    private func assertSameDrawing(_ lhs: [RealityPlotStroke], _ rhs: [RealityPlotStroke],
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(lhs.isEmpty, file: file, line: line)
        XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
        for (a, b) in zip(lhs, rhs) {
            XCTAssertEqual(a.path, b.path, file: file, line: line)
            XCTAssertEqual(a.color, b.color, file: file, line: line)
            XCTAssertEqual(a.offset, b.offset, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(a.opacity, b.opacity, accuracy: 0.001, file: file, line: line)
        }
    }

    func testLongBackgroundBlendsEndpointsAndRepeatedSuspensionKeepsActualComposition() throws {
        let view = TrendLayerView(frame: CGRect(x: 0, y: 0, width: 550, height: 100))
        view.layout()
        let earlier = samples()
        let first = try XCTUnwrap(earlier.last?.date)
        let latest = earlier.map { TrafficTrendSample(date: $0.date.addingTimeInterval(7 * 86400),
            upload: $0.upload + 100, download: $0.download, directUpload: $0.directUpload,
            directDownload: $0.directDownload, segment: $0.segment) }
        let now = try XCTUnwrap(latest.last?.date)
        view.configure(frameConfiguration(supplied: earlier, at: first), at: first)
        let beforeHide = view.plotStrokes()
        view.freeze(); view.thaw()
        let resume = TrafficTrendCatchUp(previous: TrafficTrend(), displayedAt: first, resumedAt: now)
        view.configure(frameConfiguration(supplied: [], at: now, resume: resume), at: now)
        XCTAssertTrue(view.hasHeldFrame)
        view.clock.onFrame?(now.addingTimeInterval(20))
        XCTAssertTrue(view.hasHeldFrame, "An empty interval must hold the last chart")
        assertSameDrawing(beforeHide, view.plotStrokes())
        let ready = now.addingTimeInterval(21)
        view.configure(frameConfiguration(supplied: latest, at: ready, resume: resume), at: ready)
        XCTAssertEqual(view.blendFraction, 0)
        view.clock.onFrame?(ready.addingTimeInterval(TrafficTrendCatchUp.duration / 2))
        XCTAssertEqual(view.blendFraction, 0.5, accuracy: 0.001)
        XCTAssertTrue(view.hasHeldFrame)
        let middle = view.plotStrokes()
        XCTAssertGreaterThan(middle.count, beforeHide.count, "Midpoint draws both endpoints")
        XCTAssertTrue(middle.allSatisfy { abs($0.opacity - 0.5) < 0.001 })
        view.freeze(); view.thaw()
        let again = TrafficTrendCatchUp(holding: resume, resumedAt: ready.addingTimeInterval(50))
        view.configure(frameConfiguration(supplied: latest, at: again.startedAt, resume: again), at: again.startedAt)
        XCTAssertTrue(view.hasHeldFrame)
        XCTAssertEqual(view.blendFraction, 0)
        assertSameDrawing(middle, view.plotStrokes())
        view.clock.onFrame?(again.startedAt.addingTimeInterval(1))
        XCTAssertEqual(view.blendFraction, 1)
        XCTAssertFalse(view.hasHeldFrame)
        XCTAssertEqual(view.current.root.opacity, 1)
    }

    func testReducedMotionRetainsFrozenChartUntilValidTargetThenChangesImmediately() throws {
        let view = TrendLayerView(frame: CGRect(x: 0, y: 0, width: 550, height: 100))
        view.layout()
        let earlier = samples(), now = Date()
        view.configure(frameConfiguration(animate: false, supplied: earlier, reduced: true))
        view.freeze(); view.thaw()
        let resume = TrafficTrendCatchUp(previous: TrafficTrend(), displayedAt: now, resumedAt: now)
        view.configure(frameConfiguration(animate: false, supplied: [], at: now, resume: resume, reduced: true))
        XCTAssertTrue(view.hasHeldFrame)
        view.configure(frameConfiguration(animate: false, supplied: earlier, at: now, resume: resume, reduced: true))
        XCTAssertFalse(view.hasHeldFrame)
        XCTAssertEqual(view.current.root.opacity, 1)
        XCTAssertFalse(view.clock.isRunning)
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
