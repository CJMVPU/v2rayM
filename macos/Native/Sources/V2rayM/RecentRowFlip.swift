import AppKit
import QuartzCore
import SwiftUI
import V2rayMKit

struct RecentRowFace: Equatable {
    let host: String
    let route: String
    let title: String
    init(_ connection: GlobeConnection) {
        host = connection.host; route = connection.route; title = connection.routeTitle
    }
    var color: NSColor { NSColor(route == "proxy" ? DashboardTheme.cyan : route == "direct" ? .green : .orange) }
}

fileprivate struct RowBitmapKey: Equatable {
    let face: RecentRowFace
    let size: CGSize
    let scale: CGFloat
}

/// One scheduler per card, with at most two active turns and one sleeping task.
/// Queues slots, never historical values. No display-link or per-frame work.
@MainActor final class RecentRowFlipScheduler: ObservableObject {
    private final class WeakRow {
        weak var value: CachedRecentRowView?
        init(_ value: CachedRecentRowView) { self.value = value }
    }
    private var pending: [Int: WeakRow] = [:]
    // Shared across slots: a connection moving down the list can reuse its face.
    // A bounded cache holds recent faces, not the connection history.
    private var bitmaps: [(RowBitmapKey, CGImage)] = []
    fileprivate func cachedImage(_ key: RowBitmapKey) -> CGImage? {
        guard let index = bitmaps.firstIndex(where: { $0.0 == key }) else { return nil }
        let entry = bitmaps.remove(at: index); bitmaps.append(entry)
        return entry.1
    }
    fileprivate func retainImage(_ image: CGImage, key: RowBitmapKey) {
        bitmaps.removeAll { $0.0 == key }; bitmaps.append((key, image))
        if bitmaps.count > 28 { bitmaps.removeFirst(bitmaps.count - 28) }
    }
    private var active: [Int: WeakRow] = [:]
    private var worker: Task<Void, Never>?
    private var generation = 0
    private var nextStart = 0.0
    private var lastSlot: Int?
    private var randomState: UInt64
    let timingScale: Double
    private(set) var peakConcurrent = 0
    var onStart: ((Int) -> Void)?
    var activeCount: Int { active.count }
    var pendingCount: Int { pending.count }
    init(timingScale: Double = 1, seed: UInt64 = UInt64.random(in: 1...UInt64.max)) {
        self.timingScale = timingScale; randomState = max(1, seed)
    }
    private func random() -> Double {
        randomState ^= randomState << 13; randomState ^= randomState >> 7; randomState ^= randomState << 17
        return Double(randomState % 1_000_000) / 1_000_000
    }
    func enqueue(_ row: CachedRecentRowView) {
        guard row.canFlip, active[row.slot] == nil else { return }
        if pending[row.slot] == nil {
            row.readyAt = max(row.readyAt, CACurrentMediaTime() + (0.12 + random() * 0.48) * timingScale)
            pending[row.slot] = WeakRow(row)
        }
        pump()
    }
    func cancel(_ row: CachedRecentRowView) {
        if pending[row.slot]?.value === row { pending.removeValue(forKey: row.slot) }
        if active[row.slot]?.value === row { active.removeValue(forKey: row.slot) }
        pump()
    }
    func finished(_ row: CachedRecentRowView) {
        if active[row.slot]?.value === row { active.removeValue(forKey: row.slot) }
        row.readyAt = CACurrentMediaTime() + (2 + random() * 0.8) * timingScale
        pump()
    }
    private func pump() {
        generation += 1; worker?.cancel(); worker = nil
        pending = pending.filter { $0.value.value?.canFlip == true }
        active = active.filter { $0.value.value != nil }
        guard active.count < 2, !pending.isEmpty else { return }
        let deadline = max(nextStart, pending.values.compactMap { $0.value?.readyAt }.min() ?? 0)
        let ticket = generation
        worker = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline - CACurrentMediaTime()))) } catch { return }
            guard let self, ticket == self.generation else { return }
            self.worker = nil
            var eligible = self.pending.values.compactMap(\.value).filter { $0.canFlip && $0.readyAt <= CACurrentMediaTime() }
            // Bound waiting under sustained updates, then prefer non-neighbours.
            // Each slot's jitter defines its deadline, not its vertical position.
            let overdue = eligible.filter { CACurrentMediaTime() - $0.readyAt > 3 * self.timingScale }
            if let oldest = overdue.min(by: { $0.readyAt < $1.readyAt }) { eligible = [oldest] }
            else {
                let separated = eligible.filter { self.lastSlot == nil || abs($0.slot - self.lastSlot!) > 1 }
                if !separated.isEmpty { eligible = separated }
            }
            guard !eligible.isEmpty else { self.pump(); return }
            // Sort before random choice so Dictionary iteration doesn't define cadence.
            eligible.sort { $0.slot < $1.slot }
            let row = eligible[min(eligible.count - 1, Int(self.random() * Double(eligible.count)))]
            self.pending.removeValue(forKey: row.slot)
            self.active[row.slot] = WeakRow(row)
            self.peakConcurrent = max(self.peakConcurrent, self.active.count)
            self.lastSlot = row.slot
            self.nextStart = CACurrentMediaTime() + (0.28 + self.random() * 0.12) * self.timingScale
            row.startFlip(duration: (0.94 + self.random() * 0.12) * self.timingScale)
            self.onStart?(row.slot)
            self.pump()
        }
    }
    deinit { worker?.cancel() }
}

struct CachedRecentRow: NSViewRepresentable {
    let face: RecentRowFace
    let slot: Int
    let scheduler: RecentRowFlipScheduler
    let motion: Bool
    let flips: Bool
    let reduced: Bool
    func makeNSView(context: Context) -> CachedRecentRowView { CachedRecentRowView(slot: slot, scheduler: scheduler) }
    func updateNSView(_ view: CachedRecentRowView, context: Context) {
        view.update(face, motion: motion, flips: flips, reduced: reduced)
    }
    static func dismantleNSView(_ view: CachedRecentRowView, coordinator: ()) { view.stop() }
}

@MainActor final class CachedRecentRowView: DashboardLayerView {
    private typealias CacheKey = RowBitmapKey
    let slot: Int
    private weak var scheduler: RecentRowFlipScheduler?
    private let flat = CALayer(), scene = CALayer(), solid = CATransformLayer()
    private let front = CALayer(), back = CALayer(), top = CALayer(), bottom = CALayer()
    private var cache: [(CacheKey, CGImage)] = []
    private var latest: RecentRowFace?
    private(set) var displayed: RecentRowFace?
    private var incoming: RecentRowFace?
    private var motion = false, flips = false, reduced = false
    private var needsRecovery = false
    private var completion: RowFlipCompletion?
    private var token = 0
    private var lastSize = CGSize.zero
    private var lastScale: CGFloat = 0
    private(set) var turning = false
    private(set) var recovering = false
    private(set) var bitmapBuilds = 0
    private(set) var bitmapSeconds = 0.0
    var readyAt = 0.0
    var canFlip: Bool { !frozen && motion && flips && !reduced && !turning && !recovering && latest != displayed && displayed != nil && bounds.width > 0 && bounds.height > 0 }
    init(slot: Int, scheduler: RecentRowFlipScheduler) {
        self.slot = slot; self.scheduler = scheduler
        super.init(frame: .zero)
        layer?.addSublayer(flat); layer?.addSublayer(scene); scene.addSublayer(solid)
        for face in [front, back, top, bottom] {
            face.isDoubleSided = false; solid.addSublayer(face)
        }
        scene.isHidden = true
        top.backgroundColor = NSColor(white: 0.29, alpha: 1).cgColor
        bottom.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        // Static, explicit shadow outline. No per-frame blur/lighting rebuild.
        scene.shadowColor = NSColor.black.cgColor; scene.shadowOpacity = 0.18
        scene.shadowRadius = 1.5; scene.shadowOffset = CGSize(width: 0, height: 1)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        guard bounds.size != lastSize || scale != lastScale else { return }
        lastSize = bounds.size; lastScale = scale
        cache.removeAll()
        withoutActions {
            flat.frame = bounds; scene.frame = bounds
            var perspective = CATransform3DIdentity; perspective.m34 = -1 / 600
            scene.sublayerTransform = perspective
            solid.position = CGPoint(x: bounds.midX, y: bounds.midY)
            solid.bounds = CGRect(origin: .zero, size: bounds.size)
            for face in [front, back] {
                face.bounds = bounds; face.position = CGPoint(x: bounds.midX, y: bounds.midY); face.contentsScale = scale
            }
            front.transform = CATransform3DMakeTranslation(0, 0, 0.7)
            back.transform = CATransform3DRotate(CATransform3DMakeTranslation(0, 0, -0.7), .pi, 1, 0, 0)
            for (edge, y, angle) in [(top, CGFloat(0), -CGFloat.pi / 2), (bottom, bounds.height, CGFloat.pi / 2)] {
                edge.bounds = CGRect(x: 0, y: 0, width: max(0, bounds.width - 8), height: 1.4)
                edge.position = CGPoint(x: bounds.midX, y: y)
                edge.transform = CATransform3DMakeRotation(angle, 1, 0, 0)
            }
            scene.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 5, cornerHeight: 5, transform: nil)
            if let displayed { flat.contents = image(displayed); front.contents = flat.contents }
            if let incoming { back.contents = image(incoming) }
        }
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true }
    func update(_ face: RecentRowFace, motion: Bool, flips: Bool, reduced: Bool) {
        latest = face; self.motion = motion; self.flips = flips; self.reduced = reduced
        guard !frozen else { return }
        if displayed == nil { showLatest(animated: false); return }
        if reduced { stopAnimation(); showLatest(animated: false); return }
        guard motion else { freeze(); return }
        if needsRecovery {
            needsRecovery = false
            showLatest(animated: true)
        } else if !turning && !recovering {
            if flips { scheduler?.enqueue(self) }
            else { showLatest(animated: displayed != latest) }
        }
    }
    func startFlip(duration: Double) {
        guard canFlip, let displayed, let latest else { scheduler?.cancel(self); return }
        turning = true; incoming = latest; token += 1
        let ticket = token
        let animation = CABasicAnimation(keyPath: "transform.rotation.x")
        animation.fromValue = 0; animation.toValue = Double.pi; animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.28, 0, 0.24, 1)
        let delegate = RowFlipCompletion { [weak self] in
            guard let self, self.token == ticket, !self.frozen else { return }
            self.turning = false; self.displayed = self.incoming
            self.withoutActions {
                self.flat.contents = self.back.contents
                self.flat.opacity = 1; self.scene.isHidden = true; self.scene.opacity = 0
                self.solid.transform = CATransform3DIdentity
                self.front.contents = nil; self.back.contents = nil
            }
            self.incoming = nil; self.completion = nil
            self.scheduler?.finished(self)
            // A newer arrival waits as one coalesced value for the next turn.
            // Prepare its hidden back for that turn; never replace visible text afterward.
            self.scheduler?.enqueue(self)
        }
        completion = delegate; animation.delegate = delegate
        // Prepare the back while it is hidden. Commit the old visible front and
        // animation atomically so no new content flashes before rotation begins.
        let previousImage = image(displayed), nextImage = image(latest)
        withoutActions {
            front.contents = previousImage; back.contents = nextImage
            flat.opacity = 0; scene.opacity = 1; scene.isHidden = false
            solid.transform = CATransform3DMakeRotation(.pi, 1, 0, 0)
            solid.add(animation, forKey: "row-turn")
        }
    }
    private func showLatest(animated: Bool) {
        guard let latest else { return }
        token += 1; let ticket = token
        let wasTurningSurface = !scene.isHidden
        let oldImage = flat.contents
        withoutActions {
            solid.removeAllAnimations(); flat.removeAllAnimations(); scene.removeAllAnimations()
            flat.contents = image(latest); flat.opacity = 1
            if !animated { scene.isHidden = true; scene.opacity = 0; solid.transform = CATransform3DIdentity }
        }
        displayed = latest; turning = false; incoming = nil
        guard animated, oldImage != nil else { recovering = false; scheduler?.cancel(self); return }
        recovering = true
        let duration = 0.4 * (scheduler?.timingScale ?? 1)
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 0; animation.toValue = 1; animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        if !wasTurningSurface {
            withoutActions { front.contents = oldImage; back.contents = nil; solid.transform = CATransform3DIdentity; scene.isHidden = false; scene.opacity = 1 }
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = scene.presentation()?.opacity ?? 1; fade.toValue = 0; fade.duration = duration
        withoutActions { scene.opacity = 0 }
        let delegate = RowFlipCompletion { [weak self] in
            guard let self, self.token == ticket, !self.frozen else { return }
            self.withoutActions { self.scene.isHidden = true; self.solid.transform = CATransform3DIdentity; self.front.contents = nil; self.back.contents = nil }
            self.recovering = false; self.completion = nil
            // A final coalesced change uses a fade, never replays missed flips.
            if self.displayed != self.latest { self.showLatest(animated: true) }
        }
        completion = delegate; animation.delegate = delegate
        scene.add(fade, forKey: "row-out"); flat.add(animation, forKey: "row-in")
    }
    override func freeze() {
        guard !frozen else { return }
        token += 1; completion = nil
        withoutActions {
            let transform = solid.presentation()?.transform ?? solid.transform
            let flatOpacity = flat.presentation()?.opacity ?? flat.opacity
            let sceneOpacity = scene.presentation()?.opacity ?? scene.opacity
            solid.removeAllAnimations(); flat.removeAllAnimations(); scene.removeAllAnimations()
            solid.transform = transform; flat.opacity = flatOpacity; scene.opacity = sceneOpacity
        }
        needsRecovery = true; turning = false; recovering = false
        super.freeze(); scheduler?.cancel(self)
    }
    private func stopAnimation() {
        token += 1; completion = nil; turning = false; recovering = false; needsRecovery = false
        withoutActions { solid.removeAllAnimations(); flat.removeAllAnimations(); scene.removeAllAnimations() }
        scheduler?.cancel(self)
    }
    func stop() { freeze(); cache.removeAll() }
    private func image(_ face: RecentRowFace) -> CGImage? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = window?.backingScaleFactor ?? 2
        let key = CacheKey(face: face, size: bounds.size, scale: scale)
        if let cached = cache.first(where: { $0.0 == key }) { return cached.1 }
        if let shared = scheduler?.cachedImage(key) {
            cache.append((key, shared)); if cache.count > 3 { cache.removeFirst(cache.count - 3) }
            return shared
        }
        let started = CACurrentMediaTime()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(bounds.width * scale)),
            pixelsHigh: Int(ceil(bounds.height * scale)), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            face.color.withAlphaComponent(0.13).setFill()
            NSBezierPath(roundedRect: CGRect(origin: .zero, size: bounds.size), xRadius: 5, yRadius: 5).fill()
            let font = NSFont(name: AppFont.postScriptName, size: 11) ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
            let textHeight = ceil(font.ascender - font.descender + font.leading)
            let y = (bounds.height - textHeight) / 2
            let routeAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(DashboardTheme.muted)]
            let routeWidth = ceil((face.title as NSString).size(withAttributes: routeAttributes).width)
            (face.title as NSString).draw(in: CGRect(x: bounds.width - 8 - routeWidth, y: y, width: routeWidth, height: textHeight), withAttributes: routeAttributes)
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingMiddle
            (face.host as NSString).draw(in: CGRect(x: 8, y: y, width: max(0, bounds.width - 28 - routeWidth), height: textHeight),
                withAttributes: [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let result = bitmap.cgImage else { return nil }
        bitmapBuilds += 1; bitmapSeconds += CACurrentMediaTime() - started
        scheduler?.retainImage(result, key: key)
        cache.append((key, result)); if cache.count > 3 { cache.removeFirst(cache.count - 3) }
        return result
    }
}

private final class RowFlipCompletion: NSObject, CAAnimationDelegate {
    let finished: @MainActor () -> Void
    init(_ finished: @escaping @MainActor () -> Void) { self.finished = finished }
    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        guard flag else { return }
        Task { @MainActor [finished] in finished() }
    }
}
