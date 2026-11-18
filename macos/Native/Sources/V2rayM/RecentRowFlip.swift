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
    var color: NSColor { NSColor(route == "proxy" ? DashboardTheme.proxyUpload : route == "direct" ? DashboardTheme.directUpload : DashboardTheme.warning) }
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
    @Environment(\.realityScene) private var scene
    @Environment(\.realityParentSurface) private var parent
    let face: RecentRowFace
    let slot: Int
    let rowOffset: CGFloat
    let scheduler: RecentRowFlipScheduler
    let motion: Bool
    let flips: Bool
    let reduced: Bool
    func makeNSView(context: Context) -> CachedRecentRowView { CachedRecentRowView(slot: slot, scheduler: scheduler) }
    func updateNSView(_ view: CachedRecentRowView, context: Context) {
        view.setScene(scene, parent: parent, offset: rowOffset)
        view.update(face, motion: motion, flips: flips, reduced: reduced)
    }
    static func dismantleNSView(_ view: CachedRecentRowView, coordinator: ()) { view.stop() }
}

/// The existing bounded scheduler now drives RealityKit entities and cached
/// face textures. No CATransformLayer or Core Animation face stack is rendered.
@MainActor final class CachedRecentRowView: DashboardLayerView {
    private typealias CacheKey = RowBitmapKey
    let slot: Int
    private weak var scheduler: RecentRowFlipScheduler?
    private let surface = RealitySurfaceAnchor()
    private weak var sceneOwner: RealityWindowScene?
    private var rowOffset: CGFloat = 0
    private var parentID: UUID?
    private var cache: [(CacheKey, CGImage)] = []
    private var latest: RecentRowFace?
    private(set) var displayed: RecentRowFace?
    private(set) var preparedFace: RecentRowFace?
    private var motion = false, flips = false, reduced = false
    private var needsRecovery = false
    private var worker: Task<Void, Never>?
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
        addSubview(surface)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    func setScene(_ scene: RealityWindowScene?, parent: UUID? = nil, offset: CGFloat = 0) {
        rowOffset = offset
        sceneOwner = scene; parentID = parent; synchronizeSurface()
    }
    private func synchronizeSurface() {
        surface.frame = bounds
        surface.configure(scene: sceneOwner, style: .init(shape: .panel(5),
            color: NSColor(DashboardTheme.well), depth: 1.4, level: 30, parentID: parentID, rowOffset: rowOffset))
        if !turning, let displayed, let bitmap = image(displayed) { surface.textureImage = bitmap }
    }
    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        guard bounds.size != lastSize || scale != lastScale else { return }
        lastSize = bounds.size; lastScale = scale; cache.removeAll()
        synchronizeSurface()
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true }
    func update(_ face: RecentRowFace, motion: Bool, flips: Bool, reduced: Bool) {
        latest = face; self.motion = motion; self.flips = flips; self.reduced = reduced
        guard !frozen else { return }
        if displayed == nil { showLatest(animated: false); return }
        if reduced { stopAnimation(); showLatest(animated: false); return }
        guard motion else { freeze(); return }
        if needsRecovery {
            needsRecovery = false; showLatest(animated: true)
        } else if !turning && !recovering {
            if flips { scheduler?.enqueue(self) }
            else { showLatest(animated: displayed != latest) }
        }
    }
    func startFlip(duration: Double) {
        guard canFlip, let latest else { scheduler?.cancel(self); return }
        turning = true; preparedFace = latest; token += 1
        let ticket = token
        let nextImage = image(latest)
        sceneOwner?.turn(surface.surfaceID, degrees: 90, duration: duration / 2)
        worker = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(duration / 2)) } catch { return }
            guard let self, self.token == ticket, !self.frozen else { return }
            if let nextImage { self.surface.textureImage = nextImage }
            self.sceneOwner?.turn(self.surface.surfaceID, degrees: -90, duration: 0)
            self.sceneOwner?.turn(self.surface.surfaceID, degrees: 0, duration: duration / 2)
            do { try await Task.sleep(for: .seconds(duration / 2)) } catch { return }
            guard self.token == ticket, !self.frozen else { return }
            self.sceneOwner?.turn(self.surface.surfaceID, degrees: 0, duration: 0)
            self.displayed = self.preparedFace; self.preparedFace = nil; self.turning = false; self.worker = nil
            self.scheduler?.finished(self); self.scheduler?.enqueue(self)
        }
    }
    private func showLatest(animated: Bool) {
        guard let latest else { return }
        stopAnimation()
        displayed = latest
        if let bitmap = image(latest) { surface.textureImage = bitmap }
        sceneOwner?.turn(surface.surfaceID, degrees: 0, duration: 0)
        guard animated else { return }
        recovering = true
        let ticket = token
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: .seconds(0.4 * (self.scheduler?.timingScale ?? 1))) } catch { return }
            guard self.token == ticket, !self.frozen else { return }
            self.recovering = false; self.worker = nil
            if self.displayed != self.latest { self.showLatest(animated: true) }
        }
    }
    override func freeze() {
        guard !frozen else { return }
        stopAnimation(); needsRecovery = true
        super.freeze()
    }
    private func stopAnimation() {
        token += 1; worker?.cancel(); worker = nil
        turning = false; recovering = false; preparedFace = nil
        sceneOwner?.turn(surface.surfaceID, degrees: 0, duration: 0)
        scheduler?.cancel(self)
    }
    func stop() { freeze(); surface.detach(); cache.removeAll() }
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
                withAttributes: [.font: font, .foregroundColor: NSColor(DashboardTheme.text), .paragraphStyle: paragraph])
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let result = bitmap.cgImage else { return nil }
        bitmapBuilds += 1; bitmapSeconds += CACurrentMediaTime() - started
        scheduler?.retainImage(result, key: key)
        cache.append((key, result)); if cache.count > 3 { cache.removeFirst(cache.count - 3) }
        return result
    }
}
