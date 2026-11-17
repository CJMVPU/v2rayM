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
        wantsLayer = true
        layer?.masksToBounds = false
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
                    else { self?.frozen = false }
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
    func withoutActions(_ body: () -> Void) {
        CATransaction.begin(); CATransaction.setDisableActions(true); body(); CATransaction.commit()
    }
    deinit { observations.forEach { NotificationCenter.default.removeObserver($0) } }
}

struct DashboardRing: NSViewRepresentable {
    let fraction: Double
    let color: Color
    let animate: Bool
    func makeNSView(context: Context) -> RingLayerView { RingLayerView() }
    func updateNSView(_ view: RingLayerView, context: Context) {
        view.update(fraction: fraction, color: NSColor(color).cgColor, animate: animate)
    }
}

@MainActor final class RingLayerView: DashboardLayerView {
    let track = CAShapeLayer(), arc = CAShapeLayer()
    private var pathSize = CGSize(width: -1, height: -1)
    private var target: Double?
    private(set) var pathBuilds = 0
    override init(frame: NSRect = .zero) {
        super.init(frame: frame)
        for shape in [track, arc] {
            shape.fillColor = nil; shape.lineWidth = 5; shape.lineCap = .round
            shape.contentsScale = 2
            layer?.addSublayer(shape)
        }
        track.strokeColor = NSColor.white.withAlphaComponent(0.08).cgColor
        arc.strokeEnd = 0
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        guard pathSize != bounds.size else { return }
        pathSize = bounds.size; pathBuilds += 1
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: max(0, min(bounds.width, bounds.height) / 2),
                    startAngle: .pi / 2, endAngle: .pi * 2.5, clockwise: false)
        withoutActions { track.path = path; arc.path = path }
    }
    func update(fraction: Double, color: CGColor, animate: Bool) {
        guard !frozen else { return }
        let value = min(1, max(0, fraction))
        withoutActions { if arc.strokeColor != color { arc.strokeColor = color } }
        guard target != value || (!animate && arc.animation(forKey: "endpoint") != nil) else { return }
        let from = arc.presentation()?.strokeEnd ?? arc.strokeEnd
        let hadTarget = target != nil
        target = value
        withoutActions { arc.removeAnimation(forKey: "endpoint"); arc.strokeEnd = value }
        if animate, hadTarget, abs(from - value) > 0.00001 {
            let animation = CABasicAnimation(keyPath: "strokeEnd")
            animation.fromValue = from; animation.toValue = value; animation.duration = 1.2
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            arc.add(animation, forKey: "endpoint")
        }
    }
    override func freeze() {
        guard !frozen else { return }
        let current = arc.presentation()?.strokeEnd ?? arc.strokeEnd
        withoutActions { arc.removeAllAnimations(); arc.strokeEnd = current }
        target = current
        super.freeze()
    }
}

/// One identity per data publication, outside the display-link subtree.
final class TrendLayerInput {
    let samples: [TrafficTrendSample]
    init(_ samples: [TrafficTrendSample]) { self.samples = samples }
    // A long sleep can leave two windows separated by days. Do not hand Core
    // Animation a path with a gigantic bounding box. Recenter in coarse buckets,
    // not per frame; retain connected neighbours at both bucket edges.
    func bucket(at date: Date) -> Double {
        guard let first = samples.first, let last = samples.last,
              last.date.timeIntervalSince(first.date) > TrafficTrend.duration * 4 else { return .infinity }
        return floor(date.timeIntervalSince1970 / TrafficTrend.duration)
    }
    func selected(bucket: Double) -> [TrafficTrendSample] {
        guard bucket.isFinite else { return samples }
        func lowerBound(_ time: Double) -> Int {
            var low = 0, high = samples.count
            while low < high {
                let mid = (low + high) / 2
                if samples[mid].date.timeIntervalSince1970 < time { low = mid + 1 } else { high = mid }
            }
            return low
        }
        var lower = lowerBound((bucket - 1) * TrafficTrend.duration)
        var upper = lowerBound((bucket + 2) * TrafficTrend.duration)
        guard lower < upper else { return [] }
        func connected(_ left: Int, _ right: Int) -> Bool {
            samples[left].segment == samples[right].segment && samples[right].date.timeIntervalSince(samples[left].date) < 12
        }
        if lower > 0, connected(lower - 1, lower) { lower -= 1 }
        if upper < samples.count, connected(upper - 1, upper) { upper += 1 }
        return Array(samples[lower..<upper])
    }
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

struct DashboardTrendPlot: NSViewRepresentable {
    let input: TrendLayerInput
    let date: Date
    let ceiling: Double
    let reveal: Double
    var opacity = 1.0
    var retired: TrendLayerInput?
    var retirement: TrafficTrendRetirement?
    func makeNSView(context: Context) -> TrendLayerView { TrendLayerView() }
    func updateNSView(_ view: TrendLayerView, context: Context) {
        view.update(input: input, date: date, ceiling: ceiling, reveal: reveal, opacity: opacity,
                    retired: retired, retirement: retirement)
    }
}

@MainActor final class TrendLayerView: DashboardLayerView {
    private let grid = CAShapeLayer(), baseline = CAShapeLayer(), clip = CALayer()
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
        clip.addSublayer(old.root); clip.addSublayer(current.root)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
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
    private var bucket = Double.nan
    private var size = CGSize.zero
    private var ceiling = Double.nan
    private var reveal = Double.nan
    private var date = Date.distantPast
    private(set) var geometryBuilds = 0
    private(set) var projections = 0
    private(set) var tailBuilds = 0
    init() {
        let colors = [DashboardTheme.cyan, DashboardTheme.purple, DashboardTheme.directUpload, DashboardTheme.directDownload]
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
        input = nil; geometry = nil; selectedSamples = []; bucket = .nan; root.isHidden = true
        for shape in lines + tails + dots { shape.path = nil }
    }
    func resize(_ size: CGSize) {
        guard size != self.size, let input else { return }
        update(input: input, date: date, ceiling: ceiling, reveal: reveal, opacity: Double(root.opacity), size: size)
    }
    func update(input: TrendLayerInput, date: Date, ceiling: Double, reveal: Double, opacity: Double, size: CGSize) {
        var changed = false
        let bucket = input.bucket(at: date)
        if self.input !== input || bucket != self.bucket {
            let selected = input.selected(bucket: bucket)
            if geometry == nil || selectedSamples != selected {
                selectedSamples = selected
                geometry = TrendLayerGeometry(selected); geometryBuilds += 1; changed = true
            }
            self.input = input; self.bucket = bucket
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
