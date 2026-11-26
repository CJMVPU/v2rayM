import AppKit
import SwiftUI
import QuartzCore
import V2rayMKit

/// Owns only graphics; it never polls data or starts a display link.
/// The window's early freeze also blocks stale SwiftUI updates in the same turn.
@MainActor class DashboardLayerView: NSView {
    override var isFlipped: Bool { true }
    private var observations: [NSObjectProtocol] = []
    private(set) var frozen = false
    override init(frame: NSRect) {
        super.init(frame: frame)
        // Own the layer tree explicitly: AppKit must not redraw a view backing
        // store when these independently cached layers move or rotate.
        let root = CALayer()
        root.isGeometryFlipped = true
        root.masksToBounds = false
        layer = root
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observations.forEach { NotificationCenter.default.removeObserver($0) }
        observations.removeAll()
        guard let window else { freeze(); return }
        for name in [Notification.Name.dashboardWillFreeze, .dashboardDidThaw] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    if note.name == .dashboardWillFreeze { self?.freeze() }
                    else { self?.thaw() }
                }
            })
        }
        updateContentsScale()
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateContentsScale() }
    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? 2
        func apply(_ layer: CALayer) { layer.contentsScale = scale; layer.sublayers?.forEach(apply) }
        if let layer { apply(layer) }
    }
    func freeze() { frozen = true }
    func thaw() { frozen = false }
    func withoutActions(_ body: () -> Void) {
        CATransaction.begin(); CATransaction.setDisableActions(true); body(); CATransaction.commit()
    }
    deinit { observations.forEach { NotificationCenter.default.removeObserver($0) } }
}

struct DashboardRing: View {
    let fraction: Double
    let color: Color
    let animate: Bool
    var body: some View {
        Color.clear
            .background { RealitySurface(style: .init(shape: .ringTrack, color: NSColor(DashboardTheme.line), depth: 5, level: 16), attachesToSceneRoot: true) }
            .background {
                RealitySurface(style: .init(shape: .ring(fraction), color: NSColor(color),
                                            depth: 5, level: 20, animatesRing: animate), attachesToSceneRoot: true)
            }
    }
}

final class TrendLayerInput {
    let samples: [TrafficTrendSample]
    init(_ samples: [TrafficTrendSample]) { self.samples = samples }

}

/// Data-space curves are independent of the clock, viewport and vertical scale.
struct TrendLayerGeometry {
    struct Series {
        let history: CGPath
        let dots: [CGPoint]
        let tail: (CGPoint, CGPoint)?
    }
    let origin: Date
    let series: [Series]
    init(_ samples: [TrafficTrendSample]) {
        origin = samples.first?.date ?? .distantPast
        let origin = self.origin
        series = [\TrafficTrendSample.upload, \.download, \.directUpload, \.directDownload].map { key in
            let history = CGMutablePath()
            var dots: [CGPoint] = [], tail: (CGPoint, CGPoint)?
            var previous: TrafficTrendSample?
            var lastPosition = CGPoint.zero
            for (index, point) in samples.enumerated() {
                let position = CGPoint(x: point.date.timeIntervalSince(origin), y: point[keyPath: key])
                if let previous, previous.segment == point.segment, point.date.timeIntervalSince(previous.date) < 12 {
                    if index == samples.count - 1 { tail = (lastPosition, position) }
                    else { Self.curve(history, from: lastPosition, to: position) }
                } else { history.move(to: position); dots.append(position) }
                previous = point; lastPosition = position
            }
            return Series(history: history, dots: dots, tail: tail)
        }
    }
    static func curve(_ path: CGMutablePath, from: CGPoint, to: CGPoint) {
        let middle = (from.x + to.x) / 2
        path.addCurve(to: to, control1: CGPoint(x: middle, y: from.y), control2: CGPoint(x: middle, y: to.y))
    }
}

/// Immutable animation inputs change with telemetry, not with display ticks.
struct TrendFrameConfiguration {
    let input: TrendLayerInput
    let retired: TrendLayerInput?
    let now: Date
    let maximum: Double
    let animate: Bool
    let presentationActive: Bool
    let reduceMotion: Bool
    let catchUp: TrafficTrendCatchUp?
    let retirement: TrafficTrendRetirement?
    let scaleFrom: Double
    let scaleTo: Double
    let scaleChanged: Date
    let sampleArrived: Date
    var enabled: Bool {
        presentationActive && animate && (!input.samples.isEmpty || retirement != nil)
    }
    struct Frame {
        let input: TrendLayerInput
        let date: Date
        let ceiling: Double
        let reveal: Double
        let opacity: Double
        let retired: TrendLayerInput?
        let retirement: TrafficTrendRetirement?
    }
    func frame(at wallDate: Date) -> Frame {
        let date = animate && presentationActive ? wallDate : now
        func eased(_ elapsed: Double) -> Double {
            let t = min(1, max(0, elapsed / 1.2))
            return t * t * (3 - 2 * t)
        }
        let ceiling = animate ? scaleFrom + (scaleTo - scaleFrom) * eased(date.timeIntervalSince(scaleChanged)) : maximum
        return Frame(input: input, date: date, ceiling: ceiling,
            reveal: animate ? eased(date.timeIntervalSince(sampleArrived)) : 1,
            opacity: animate ? (retirement?.progress(at: wallDate) ?? 1) : 1,
            retired: animate ? retired : nil, retirement: animate ? retirement : nil)
    }
}

struct DashboardTrendPlot: NSViewRepresentable {
    @Environment(\.realityScene) private var scene
    let configuration: TrendFrameConfiguration
    func makeNSView(context: Context) -> TrendLayerView { TrendLayerView() }
    func updateNSView(_ view: TrendLayerView, context: Context) { view.setScene(scene); view.configure(configuration) }
    static func dismantleNSView(_ view: TrendLayerView, coordinator: ()) { view.freeze() }
}

@MainActor final class TrendLayerView: DashboardLayerView {
    private let realityAnchor = RealitySurfaceAnchor()
    private let realityPlot = RealityPlotModel()
    private weak var sceneOwner: RealityWindowScene?
    private let grid = CAShapeLayer(), baseline = CAShapeLayer(), clip = CALayer()
    private let held = CALayer()
    private var seenResume: Date?
    private var frozenSnapshotDate: Date?
    private var awaitingResumeSnapshot: Bool { frozenSnapshotDate != nil }
    private var transitioning = false
    private var blendStart: Date?
    private var settledSample: Date?
    private var settledCeiling: Double?
    private var completedBlendAt: Date?
    private(set) var blendFraction = 1.0
    var hasHeldFrame: Bool { !(held.sublayers ?? []).isEmpty }
    let clock = DashboardDisplayClock()
    private var configuration: TrendFrameConfiguration?
    private var screenObserver: NSObjectProtocol?
    let current = TrendLayerGroup(), old = TrendLayerGroup()
    private var gridSize = CGSize(width: -1, height: -1)
    private(set) var gridBuilds = 0
    override init(frame: NSRect = .zero) {
        super.init(frame: frame)
        for (shape, alpha) in [(grid, 0.08), (baseline, 0.13)] {
            shape.fillColor = nil; shape.strokeColor = NSColor.white.withAlphaComponent(alpha).cgColor
            shape.lineWidth = 0.5; shape.contentsScale = 2; layer?.addSublayer(shape)
        }
        clip.masksToBounds = true; layer?.addSublayer(clip)
        clip.addSublayer(held); clip.addSublayer(old.root); clip.addSublayer(current.root)
        clock.onFrame = { [weak self] in self?.renderFrame(at: $0) }
        addSubview(realityAnchor)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func setScene(_ scene: RealityWindowScene?) {
        sceneOwner = scene
        grid.isHidden = scene != nil; baseline.isHidden = scene != nil; clip.isHidden = scene != nil
        realityAnchor.frame = bounds
        realityAnchor.configure(scene: scene, style: .init(shape: .panel(0), color: NSColor(DashboardTheme.background), depth: 0.1, level: 5, insidePage: true))
        scene?.attachDrawing(realityPlot.entity, to: realityAnchor.surfaceID)
    }
    func configure(_ configuration: TrendFrameConfiguration, at date: Date = Date()) {
        self.configuration = configuration
        guard !frozen else { return }
        present(configuration, at: date)
    }

    private func present(_ configuration: TrendFrameConfiguration, at date: Date) {
        let resume = configuration.catchUp
        let newResume = resume != nil && resume?.startedAt != seenResume
        let refreshedAfterFreeze = frozenSnapshotDate.map { configuration.presentationActive && configuration.now > $0 } ?? false
        if newResume || refreshedAfterFreeze {
            if !awaitingResumeSnapshot { captureVisibleFrame() }
            if !hasHeldFrame, let resume, !resume.samples.isEmpty {
                // SwiftUI can recreate the native view during navigation.
                old.update(input: TrendLayerInput(resume.samples), date: resume.displayDate, ceiling: resume.ceiling,
                           reveal: 1, opacity: 1, size: bounds.size)
                captureVisibleFrame()
            }
            seenResume = resume?.startedAt
            frozenSnapshotDate = nil
            transitioning = hasHeldFrame
            blendStart = nil
        }
        guard !awaitingResumeSnapshot else { return }
        renderFrame(at: date)
        attachClock()
    }

    /// Freeze actual paths, viewport offsets and partially blended opacities.
    /// Repeated hide/show therefore starts at exactly the last drawn composition.
    private func captureVisibleFrame() {
        let copies: [CAShapeLayer] = [held, old.root, current.root].flatMap { group -> [CAShapeLayer] in
            guard !group.isHidden, group.opacity > 0 else { return [] }
            return (group.sublayers ?? []).compactMap { layer in
                guard let shape = layer as? CAShapeLayer, let path = shape.path, !path.isEmpty else { return nil }
                let opacity = group.opacity * shape.opacity
                guard opacity >= 1.0 / 255 else { return nil }
                let copy = CAShapeLayer()
                copy.path = path
                copy.strokeColor = shape.strokeColor
                copy.fillColor = shape.fillColor
                copy.lineWidth = shape.lineWidth
                copy.lineCap = shape.lineCap
                copy.lineJoin = shape.lineJoin
                copy.contentsScale = shape.contentsScale
                copy.position = CGPoint(x: group.position.x + shape.position.x, y: 0)
                copy.opacity = opacity
                return copy
            }
        }
        withoutActions {
            held.sublayers = copies
            held.opacity = 1
            old.clear(); current.clear()
        }
    }

    private func attachClock() {
        let blending = transitioning && blendStart != nil && configuration?.reduceMotion == false
        clock.attach(window: window, enabled: !frozen && !awaitingResumeSnapshot &&
                     (blending || (!transitioning && configuration?.enabled == true)))
    }

    private func renderFrame(at date: Date) {
        guard !frozen, !awaitingResumeSnapshot, let configuration else { return }
        let frame = configuration.frame(at: date)
        if transitioning {
            // Missing telemetry may outlast the entire five-minute window.
            // Keep the saved composition until a real target is available.
            guard !frame.input.samples.isEmpty else { updateRealityPlot(); return }
            let start = blendStart ?? date
            blendStart = start
            blendFraction = configuration.reduceMotion ? 1 : TrafficTrendCatchUp.progress(after: date.timeIntervalSince(start))
            withoutActions { held.opacity = Float(1 - blendFraction) }
            update(input: frame.input, date: frame.date, ceiling: configuration.maximum,
                   reveal: 1, opacity: blendFraction)
            if blendFraction >= 1 {
                withoutActions { held.sublayers = nil }
                settledSample = frame.input.samples.last?.date
                settledCeiling = configuration.maximum
                completedBlendAt = date
                transitioning = false
                blendStart = nil
                attachClock()
            }
        } else {
            if settledCeiling != configuration.maximum { settledCeiling = nil }
            let retirement = frame.retirement.flatMap { $0.startedAt > (completedBlendAt ?? .distantPast) ? $0 : nil }
            update(input: frame.input, date: frame.date, ceiling: settledCeiling ?? frame.ceiling,
                   reveal: settledSample != nil && settledSample == frame.input.samples.last?.date ? 1 : frame.reveal,
                   opacity: retirement == nil ? 1 : frame.opacity, retired: frame.retired, retirement: retirement)
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        if let window {
            screenObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification,
                object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.attachClock() }
                }
        }
        attachClock()
    }
    override func freeze() {
        clock.freeze()
        if !frozen, configuration != nil {
            captureVisibleFrame()
            frozenSnapshotDate = configuration?.now
        }
        super.freeze()
    }
    override func thaw() {
        guard frozen else { return }
        super.thaw()
        clock.thaw()
        if let configuration { present(configuration, at: Date()) }
    }
    deinit { if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) } }
    override func layout() {
        super.layout()
        withoutActions {
            clip.frame = bounds
            if gridSize != bounds.size {
                gridSize = bounds.size; gridBuilds += 1
                let lines = CGMutablePath(), bottom = CGMutablePath()
                for index in 0...6 {
                    let path = index == 6 ? bottom : lines
                    let y = 3 + Double(index) / 6 * max(0, bounds.height - 6)
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: bounds.width, y: y))
                }
                grid.path = lines; baseline.path = bottom
            }
            current.resize(bounds.size); old.resize(bounds.size)
        }
        setScene(sceneOwner)
        updateRealityPlot()
    }
    func update(input: TrendLayerInput, date: Date, ceiling: Double, reveal: Double, opacity: Double,
                retired: TrendLayerInput? = nil, retirement: TrafficTrendRetirement? = nil) {
        guard !frozen else { return }
        withoutActions {
            current.update(input: input, date: date, ceiling: ceiling, reveal: reveal, opacity: opacity, size: bounds.size)
            if let retired, let retirement, opacity < 1 {
                old.update(input: retired, date: retirement.displayDate, ceiling: retirement.ceiling,
                           reveal: 1, opacity: 1 - opacity, size: bounds.size)
            } else { old.clear() }
        }
        updateRealityPlot()
    }
    private func updateRealityPlot() {
        guard sceneOwner != nil else { return }
        var strokes: [RealityPlotStroke] = []
        for shape in [grid,baseline] {
            if let path = shape.path, let color = shape.strokeColor { strokes.append(.init(path: path, color: color, width: shape.lineWidth)) }
        }
        strokes += plotStrokes()
        realityPlot.update(strokes, size: bounds.size)
        sceneOwner?.attachDrawing(realityPlot.entity, to: realityAnchor.surfaceID)
    }
    func plotStrokes() -> [RealityPlotStroke] {
        var strokes: [RealityPlotStroke] = []
        for group in [held, old.root, current.root] where !group.isHidden && group.opacity > 0 {
            for case let shape as CAShapeLayer in group.sublayers ?? [] {
                if let path = shape.path, !path.isEmpty, let color = shape.strokeColor ?? shape.fillColor {
                    strokes.append(.init(path: path, color: color, width: shape.strokeColor == nil ? 1.2 : shape.lineWidth,
                                         offset: group.position.x + shape.position.x, opacity: group.opacity * shape.opacity))
                }
            }
        }
        return strokes
    }

}

@MainActor final class TrendLayerGroup {
    let root = CALayer()
    private let lines = (0..<4).map { _ in CAShapeLayer() }
    private let tails = (0..<4).map { _ in CAShapeLayer() }
    private let dots = (0..<4).map { _ in CAShapeLayer() }
    private var input: TrendLayerInput?
    private var geometry: TrendLayerGeometry?
    private var selectedSamples: [TrafficTrendSample] = []
    private var size = CGSize.zero
    private var ceiling = Double.nan
    private var reveal = Double.nan
    private var date = Date.distantPast
    private(set) var geometryBuilds = 0
    private(set) var projections = 0
    private(set) var tailBuilds = 0
    init() {
        let colors = [DashboardTheme.proxyUpload, DashboardTheme.proxyDownload, DashboardTheme.directUpload, DashboardTheme.directDownload]
        for index in 0..<4 {
            for shape in [lines[index], tails[index], dots[index]] {
                shape.contentsScale = 2
                shape.fillColor = shape === dots[index] ? NSColor(colors[index]).cgColor : nil
                shape.strokeColor = shape === dots[index] ? nil : NSColor(colors[index]).cgColor
                shape.lineWidth = 1.5; shape.lineCap = .round; shape.lineJoin = .round
                root.addSublayer(shape)
            }
        }
    }
    func clear() {
        guard input != nil else { return }
        input = nil; geometry = nil; selectedSamples = []; root.isHidden = true
        for shape in lines + tails + dots { shape.path = nil }
    }
    func resize(_ size: CGSize) {
        guard size != self.size, let input else { return }
        update(input: input, date: date, ceiling: ceiling, reveal: reveal, opacity: Double(root.opacity), size: size)
    }
    func update(input: TrendLayerInput, date: Date, ceiling: Double, reveal: Double, opacity: Double, size: CGSize) {
        var changed = false
        if self.input !== input {
            let selected = input.samples
            if geometry == nil || selectedSamples != selected {
                selectedSamples = selected
                geometry = TrendLayerGeometry(selected); geometryBuilds += 1; changed = true
            }
            self.input = input
        }
        guard let geometry else { return }
        root.isHidden = false
        if root.opacity != Float(opacity) { root.opacity = Float(opacity) }
        let ceiling = max(1, ceiling)
        let project = changed || size != self.size || ceiling != self.ceiling
        var transform = CGAffineTransform(a: max(0, size.width - 4) / TrafficTrend.duration, b: 0, c: 0,
                                         d: -max(0, size.height - 6) / ceiling, tx: 2, ty: size.height - 3)
        if project {
            projections += 1
            for (index, series) in geometry.series.enumerated() {
                lines[index].path = series.history.copy(using: &transform)
                let path = CGMutablePath()
                for point in series.dots {
                    let p = point.applying(transform)
                    path.addEllipse(in: CGRect(x: p.x - 1.2, y: p.y - 1.2, width: 2.4, height: 2.4))
                }
                dots[index].path = path
            }
        }
        if project || reveal != self.reveal {
            tailBuilds += 1
            for (index, series) in geometry.series.enumerated() {
                guard let (from, end) = series.tail else { tails[index].path = nil; continue }
                let to = CGPoint(x: from.x + (end.x - from.x) * reveal, y: from.y + (end.y - from.y) * reveal)
                let path = CGMutablePath(); path.move(to: from.applying(transform))
                TrendLayerGeometry.curve(path, from: from.applying(transform), to: to.applying(transform))
                tails[index].path = path
            }
        }
        let offset = selectedSamples.isEmpty ? 0 : (1 - date.timeIntervalSince(geometry.origin) / TrafficTrend.duration) * max(0, size.width - 4)
        if root.position.x != offset { root.position = CGPoint(x: offset, y: 0) }
        self.date = date; self.size = size; self.ceiling = ceiling; self.reveal = reveal
    }
}
