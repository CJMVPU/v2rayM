import Combine
import AppKit
import SwiftUI
import RealityKit

/// A single point-aligned RealityKit scene owns the window's visual surfaces.
/// Native views remain responsible for focus, editing, accessibility and actions.
/// Rendering never reads AppModel or performs network operations.
enum RealityShape: Equatable {
    case panel(CGFloat)
    case disc
    case ring(Double)
    case dashboard(DashboardBodyAsset)
    case symbol(RealityNavigationSymbol)

    var isNavigationSymbol: Bool {
        if case .symbol = self { return true }
        return false
    }
}

struct RealitySurfaceStyle: Equatable {
    var shape: RealityShape = .panel(10)
    var color = NSColor(calibratedWhite: 0.19, alpha: 1)
    var depth: Float = 6
    var level: Float = 10
    var highlighted = false
    var selected = false
    var enabled = true
    var angle: Double = 0
    var tilt: Double = 0
    var viewportID: UUID? = nil
    var parentID: UUID? = nil
    var rowOffset: CGFloat? = nil
    var visible = true
    var flipToken = 0
    var allowsFlip = true
    var switchOn: Bool? = nil
}

private struct RealitySceneKey: EnvironmentKey {
    static let defaultValue: RealityWindowScene? = nil
}
private struct RealityParentKey: EnvironmentKey { static let defaultValue: UUID? = nil }
private struct RealityContentVisibleKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var realityParentSurface: UUID? {
        get { self[RealityParentKey.self] }
        set { self[RealityParentKey.self] = newValue }
    }
    var realityContentVisible: Bool {
        get { self[RealityContentVisibleKey.self] }
        set { self[RealityContentVisibleKey.self] = newValue }
    }
    var realityScene: RealityWindowScene? {
        get { self[RealitySceneKey.self] }
        set { self[RealitySceneKey.self] = newValue }
    }
}

struct RealityWindow<Content: View>: View {
    @Environment(\.dashboardVisibilityOverride) private var visibilityOverride
    @State private var scene = RealityWindowScene()
    @StateObject private var visibility = DashboardVisibilityCoordinator()
    @ViewBuilder var content: Content
    var body: some View {
        content
            .environment(\.realityScene, scene)
            .background { RealityStage(scene: scene).allowsHitTesting(false).accessibilityHidden(true) }
            .background {
                DashboardVisibilityObserver(rendering: visibility.phase.rendersMotion) { state in
                    if let visibilityOverride {
                        if visibilityOverride { scene.stage?.resume() } else { scene.stage?.suspend() }
                        return
                    }
                    if !state.permitsRendering { scene.stage?.suspend() }
                    visibility.update(state)
                    if state.permitsRendering && visibility.phase.rendersMotion { scene.stage?.resume() }
                }
            }
            .onChange(of: visibility.phase) { _, phase in
                if phase.rendersMotion { scene.stage?.resume() }
            }
            .onDisappear { visibility.stop() }
    }
}

extension View {
    func realitySurface(_ style: RealitySurfaceStyle = .init()) -> some View {
        background { RealitySurface(style: style).allowsHitTesting(false).accessibilityHidden(true) }
    }
}

struct RealitySurface: NSViewRepresentable {
    var style: RealitySurfaceStyle
    var id: UUID? = nil
    @Environment(\.realityScene) private var scene
    @Environment(\.realityParentSurface) private var parent
    @Environment(\.realityViewport) private var viewport
    @Environment(\.realityContentVisible) private var visible
    func makeNSView(context: Context) -> RealitySurfaceAnchor { RealitySurfaceAnchor(id: id ?? UUID()) }
    func updateNSView(_ view: RealitySurfaceAnchor, context: Context) {
        var style = style; style.parentID = parent; style.visible = visible; style.viewportID = viewport
        view.configure(scene: scene, style: style)
    }
    static func dismantleNSView(_ view: RealitySurfaceAnchor, coordinator: ()) { view.detach() }
}

/// Anchors follow AppKit layout and scroll clipping without publishing geometry
/// into SwiftUI state or introducing a second frame clock.
@MainActor final class RealitySurfaceAnchor: NSView {
    let surfaceID: UUID
    weak var owner: RealityWindowScene?
    var style = RealitySurfaceStyle()
    var textureImage: CGImage? { didSet { synchronize() } }
    private var scrollObservations: [NSObjectProtocol] = []
    private var observedClipIDs: [ObjectIdentifier] = []
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    init(id: UUID = UUID()) { surfaceID = id; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    func configure(scene: RealityWindowScene?, style: RealitySurfaceStyle) {
        if owner !== scene { detach(); owner = scene; scene?.register(self) }
        self.style = style
        synchronize()
        scene?.requestLayoutSync()
    }
    override func layout() { super.layout(); synchronize() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); synchronize() }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        synchronize()
    }
    private func observeScrollAncestors() {
        var clips: [NSClipView] = []
        var ancestor = superview
        while let view = ancestor {
            if let clip = view as? NSClipView { clips.append(clip) }
            ancestor = view.superview
        }
        let ids = clips.map(ObjectIdentifier.init)
        guard ids != observedClipIDs else { return }
        scrollObservations.forEach { NotificationCenter.default.removeObserver($0) }
        observedClipIDs = ids
        scrollObservations = clips.map { clip in
            clip.postsBoundsChangedNotifications = true
            return NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                object: clip, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.synchronize() }
                }
        }
    }
    func synchronize() {
        // SwiftUI can attach the anchor before its hosting ancestors enter a
        // scroll view. Discover again after layout/window attachment, and watch
        // every clip so nested horizontal controls also follow vertical scroll.
        observeScrollAncestors()
        guard let owner, let stage = owner.stage, window != nil, stage.window === window else { return }
        if let offset = style.rowOffset, style.parentID != nil {
            // Row anchors can live in a detached SwiftUI transform host during
            // a parent turn. Use the stack layout in card-local coordinates.
            let local = CGRect(x: -bounds.width / 2, y: offset * (bounds.height + 4) - bounds.height / 2,
                               width: bounds.width, height: bounds.height)
            owner.update(surfaceID, frame: local, visible: local, style: style)
            if let textureImage { owner.setFace(textureImage, for: surfaceID) }
            return
        }
        let rect = convert(bounds, to: stage)
        let visible = convert(visibleRect, to: stage).intersection(stage.bounds)
        owner.update(surfaceID, frame: rect, visible: visible, style: style)
        if let textureImage { owner.setFace(textureImage, for: surfaceID) }
    }
    func detach() {
        owner?.remove(surfaceID); owner = nil
        scrollObservations.forEach { NotificationCenter.default.removeObserver($0) }
        scrollObservations.removeAll(); observedClipIDs.removeAll()
    }
    deinit { scrollObservations.forEach { NotificationCenter.default.removeObserver($0) } }
}

private struct RealityStage: NSViewRepresentable {
    let scene: RealityWindowScene
    func makeNSView(context: Context) -> RealityStageView { RealityStageView(owner: scene) }
    func updateNSView(_ view: RealityStageView, context: Context) { view.synchronize() }
    static func dismantleNSView(_ view: RealityStageView, coordinator: ()) { view.stop() }
}

@MainActor final class RealityStageView: NSView {
    let renderer = ARView(frame: .zero)
    let owner: RealityWindowScene
    private let frozenImage = NSImageView()
    private var suspensionGeneration = 0
    private(set) var suspended = false
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    init(owner: RealityWindowScene) {
        self.owner = owner
        super.init(frame: .zero)
        renderer.environment.background = .color(NSColor(calibratedWhite: 0.105, alpha: 1))
        frozenImage.imageScaling = .scaleAxesIndependently
        addSubview(frozenImage)
        addSubview(renderer)
        owner.attach(self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override func layout() {
        super.layout(); renderer.frame = bounds; frozenImage.frame = bounds; synchronize()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { suspend(); return }
        // Only this window's visibility coordinator may freeze the shared scene.
        // Dashboard subtree observers also publish lifecycle notifications.
        resume()
    }
    func synchronize() { owner.resize(bounds.size); owner.synchronizeAnchors() }
    func suspend() {
        guard !suspended else { return }
        suspended = true
        suspensionGeneration += 1
        let generation = suspensionGeneration
        owner.root.stopAllAnimations(recursive: true)
        owner.cancelNavigationAnimations()
        // Keep a static image when the window is visible but inactive. A stale
        // asynchronous snapshot must never remove a renderer that has resumed.
        renderer.snapshot(saveToHDR: false) { [weak self] image in
            guard let self, self.suspended, self.suspensionGeneration == generation else { return }
            if let image { self.frozenImage.image = image; self.renderer.removeFromSuperview() }
        }
    }
    func resume() {
        suspensionGeneration += 1
        suspended = false
        if renderer.superview == nil { addSubview(renderer); renderer.frame = bounds }
        synchronize()
    }
    func stop() {
        suspend(); owner.detach(self)
        renderer.removeFromSuperview(); frozenImage.image = nil
    }
}

@MainActor final class RealityWindowScene {
    private final class WeakAnchor {
        weak var view: RealitySurfaceAnchor?
        init(_ view: RealitySurfaceAnchor) { self.view = view }
    }
    private final class WeakViewport {
        weak var view: RealityViewportAnchor?
        init(_ view: RealityViewportAnchor) { self.view = view }
    }
    private var viewports: [UUID: WeakViewport] = [:]
    func registerViewport(_ view: RealityViewportAnchor) { viewports[view.id] = WeakViewport(view) }
    func removeViewport(_ id: UUID) { viewports.removeValue(forKey: id) }
    private struct Item {
        var frame: CGRect
        var style: RealitySurfaceStyle
        let entity: ModelEntity
    }
    weak var stage: RealityStageView?
    let root = AnchorEntity(world: .zero)
    let camera = Entity()
    private var anchors: [UUID: WeakAnchor] = [:]
    private var items: [UUID: Item] = [:]
    private var faces: [UUID: (CGImage, ModelEntity, CGSize)] = [:]
    private var turnTimes: [UUID: Double] = [:]
    private struct Slide {
        var from: Float
        var to: Float
        var elapsed: Double = 0
    }
    private var slides: [UUID: Slide] = [:]
    private var motionSubscription: (any Cancellable)?
    private var size = CGSize.zero
    private var layoutSyncQueued = false
    private(set) var meshBuilds = 0
    var entityCount: Int { items.count }
    var activeNavigationFlips: Int { turnTimes.count }
    init() {
        camera.position = [0, 0, 4]
        root.addChild(camera)
        let key = DirectionalLight()
        key.light.intensity = 1600
        key.look(at: .zero, from: [-1, 2, 4], relativeTo: nil)
        root.addChild(key)
        let fill = DirectionalLight()
        fill.light.intensity = 500
        fill.look(at: .zero, from: [2, -1, 3], relativeTo: nil)
        root.addChild(fill)
    }
    func attach(_ stage: RealityStageView) {
        self.stage = stage
        stage.renderer.scene.addAnchor(root)
    }
    func detach(_ stage: RealityStageView) {
        guard self.stage === stage else { return }
        stage.renderer.scene.removeAnchor(root); self.stage = nil
    }
    func register(_ view: RealitySurfaceAnchor) { anchors[view.surfaceID] = WeakAnchor(view) }
    func remove(_ id: UUID) {
        turnTimes.removeValue(forKey: id)
        slides.removeValue(forKey: id)
        retireClockIfIdle()
        items.removeValue(forKey: id)?.entity.removeFromParent(); anchors.removeValue(forKey: id); faces.removeValue(forKey: id)
    }
    func synchronizeAnchors() {
        for (id, anchor) in anchors {
            if let view = anchor.view { view.synchronize() } else { remove(id) }
        }
    }
    func requestLayoutSync() {
        guard !layoutSyncQueued else { return }
        layoutSyncQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutSyncQueued = false
            self.stage?.window?.contentView?.layoutSubtreeIfNeeded()
            self.synchronizeAnchors()
        }
    }
    func resize(_ newSize: CGSize) {
        guard newSize.width > 0, newSize.height > 0, newSize != size else { return }
        size = newSize
        var lens = OrthographicCameraComponent()
        // Orthographic scale is the half-height of the visible frustum.
        lens.scale = Float(size.height) / 2000
        lens.scaleDirection = .vertical
        lens.near = 0.01; lens.far = 10
        camera.components.set(lens)
    }
    static func position(_ frame: CGRect, viewport: CGSize, level: Float) -> SIMD3<Float> {
        [Float(frame.midX - viewport.width / 2) / 1000,
         Float(viewport.height / 2 - frame.midY) / 1000, level / 1000]
    }
    func update(_ id: UUID, frame: CGRect, visible: CGRect, style: RealitySurfaceStyle) {
        var visible = visible
        if let viewportID = style.viewportID {
            guard let viewport = viewports[viewportID]?.view, let stage, viewport.window === stage.window else {
                items[id]?.entity.isEnabled = false; return
            }
            visible = visible.intersection(viewport.convert(viewport.bounds, to: stage))
        }
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0,
              !visible.isNull, visible.width > 0, visible.height > 0 else {
            items[id]?.entity.isEnabled = false; return
        }
        // Panels in scroll views are clipped to their native visible region.
        // Rings and turning solids are not resized during their animation.
        let clipped = style.angle == 0 && style.tilt == 0 ? frame.intersection(visible) : frame
        guard !clipped.isNull, !clipped.isEmpty, clipped.width.isFinite, clipped.height.isFinite else {
            items[id]?.entity.isEnabled = false; return
        }
        let previous = items[id]
        let entity = previous?.entity ?? ModelEntity()
        if previous?.frame == clipped, previous?.style == style {
            entity.isEnabled = style.visible
            if style.parentID != nil { place(id) }
            return
        }
        if previous == nil { entity.name = "surface-" + id.uuidString }
        let geometryChanged = previous?.frame.size != clipped.size || previous?.style.shape != style.shape || previous?.style.depth != style.depth
        let selectionChanged = previous?.style.selected != style.selected
        if geometryChanged || (selectionChanged && style.shape.isNavigationSymbol) {
            if case .symbol(let symbol) = style.shape {
                entity.model = nil
                entity.children.removeAll()
                do {
                    let asset = try RealityNavigationAssets.load(symbol, selected: style.selected)
                    asset.scale = SIMD3<Float>(repeating: Float(min(clipped.width,clipped.height)) / 2000)
                    // Center the model itself. Book pages and recessed details
                    // need not have their authored origin at the visual midpoint.
                    asset.position -= asset.visualBounds(relativeTo: nil).center
                    entity.addChild(asset)
                } catch {
                    // This is a packaging fault, not a silent flat-icon fallback.
                    NSLog("v2rayM navigation asset %@ could not load: %@", symbol.rawValue, String(describing: error))
                    entity.isEnabled = false; return
                }
            } else if case .dashboard(let body) = style.shape {
                do {
                    let shell = try body.load()
                    shell.name = "dashboard-shell"
                    shell.scale = [Float(clipped.width)/1000, Float(clipped.height)/1000, style.depth/1000]
                    entity.findEntity(named: "dashboard-shell")?.removeFromParent()
                    entity.addChild(shell)
                } catch {
                    NSLog("Dashboard asset %@: %@", body.rawValue, String(describing: error))
                    entity.isEnabled = false; return
                }
            } else {
                guard let mesh = try? RealityGeometry.mesh(shape: style.shape, size: clipped.size, depth: style.depth) else {
                    entity.isEnabled = false; return
                }
                if style.rowOffset != nil {
                    let pivot = (entity.findEntity(named: "row-pivot") as? ModelEntity) ?? ModelEntity()
                    pivot.name = "row-pivot"
                    pivot.model = ModelComponent(mesh: mesh, materials: [material(style)])
                    if pivot.parent == nil { entity.addChild(pivot) }
                } else {
                    entity.model = ModelComponent(mesh: mesh, materials: [material(style)])
                }
            }
            meshBuilds += 1
        } else if previous?.style.color != style.color || previous?.style.highlighted != style.highlighted || previous?.style.enabled != style.enabled {
            entity.model?.materials = [material(style)]
        }
        if style.shape == .dashboard(.titleBar),
           geometryChanged || selectionChanged || previous?.style.highlighted != style.highlighted,
           let shell = entity.findEntity(named: "dashboard-shell") {
            let tone: CGFloat = style.selected ? 0.36 : style.highlighted ? 0.28 : 0.20
            func applyFace(_ part: Entity) {
                if let model = part as? ModelEntity, var component = model.model, component.materials.count >= 5 {
                    component.materials[4] = SimpleMaterial(color: NSColor(white: tone, alpha: 1), roughness: 0.78, isMetallic: false)
                    model.model = component
                }
                for child in part.children { applyFace(child) }
            }
            applyFace(shell)
        } else if case .dashboard = style.shape, geometryChanged || previous?.style.highlighted != style.highlighted,
           let shell = entity.findEntity(named: "dashboard-shell") {
            // Lift the bevel into the light on hover, keeping content and hit regions stable.
            shell.orientation = simd_quatf(angle: style.highlighted ? 0.045 : 0, axis: [1, 0, 0])
        }
        entity.isEnabled = style.visible
        if case .symbol = style.shape, !style.allowsFlip || !style.enabled {
            turnTimes.removeValue(forKey: id)
            retireClockIfIdle()
        }
        if turnTimes[id] == nil && style.rowOffset == nil { entity.orientation = Self.orientation(style) }
        items[id] = Item(frame: clipped, style: style, entity: entity)
        place(id)
        if let on = style.switchOn {
            updateSwitch(id, on: on, previous: previous?.style.switchOn, animated: style.allowsFlip)
        }
        for (childID, child) in items where child.style.parentID == id { place(childID) }
        if case .symbol = style.shape {
            tintNavigation(entity, style: style)
            if previous != nil, previous?.style.flipToken != style.flipToken, style.allowsFlip, style.enabled {
                flipNavigation(id)
            }
        }
    }
    private static func orientation(_ style: RealitySurfaceStyle) -> simd_quatf {
        simd_quatf(angle: Float(style.angle * .pi / 180), axis: [0,1,0]) * simd_quatf(angle: Float(style.tilt * .pi / 180), axis: [1,0,0])
    }
    private func tintNavigation(_ entity: Entity, style: RealitySurfaceStyle) {
        entity.components.set(OpacityComponent(opacity: style.enabled ? 1 : 0.4))
        // Preserve the authored colours, including the book's textured cover.
        let size: Float = style.highlighted && style.enabled ? 1.07 : 1
        entity.scale = SIMD3(repeating: size)
    }
    func cancelNavigationAnimations() {
        for id in turnTimes.keys {
            if let item = items[id] { item.entity.orientation = Self.orientation(item.style) }
        }
        for (id, slide) in slides { drawSwitch(id, progress: slide.to) }
        slides.removeAll()
        turnTimes.removeAll()
        retireClockIfIdle()
    }

    private func flipNavigation(_ id: UUID) {
        guard turnTimes[id] == nil, stage?.suspended == false else { return }
        turnTimes[id] = 0
        startMotionClock()
    }

    private func startMotionClock() {
        guard motionSubscription == nil, let stage else { return }
        motionSubscription = stage.renderer.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
            MainActor.assumeIsolated { self?.advanceMotion(by: event.deltaTime) }
        }
    }

    private func retireClockIfIdle() {
        if turnTimes.isEmpty && slides.isEmpty {
            motionSubscription?.cancel()
            motionSubscription = nil
        }
    }

    /// Advance only on render updates. A delayed frame during a page switch
    /// must not consume the entire animation before the next pose is drawn.
    func advanceMotion(by delta: Double) {
        let step = min(1.0/30.0, max(0, delta))
        for (id, elapsed) in turnTimes {
            guard let item = items[id] else { continue }
            let next = elapsed + step
            let t = min(1, next/0.42)
            let angle = Float(2 * .pi * t * t * (3 - 2*t))
            item.entity.orientation = Self.orientation(item.style) * simd_quatf(angle: angle, axis: [0,1,0])
            if t == 1 { turnTimes.removeValue(forKey: id) }
            else { turnTimes[id] = next }
        }
        for (id, var slide) in slides {
            slide.elapsed += step
            let t = Float(min(1, slide.elapsed/0.20))
            drawSwitch(id, progress: slide.from + (slide.to-slide.from)*t*t*(3-2*t))
            if t == 1 { slides.removeValue(forKey: id) }
            else { slides[id] = slide }
        }
        retireClockIfIdle()
    }

    private func updateSwitch(_ id: UUID, on: Bool, previous: Bool?, animated: Bool) {
        guard let item = items[id] else { return }
        let target: Float = on ? 1 : 0
        if item.entity.findEntity(named: "switch-thumb") == nil {
            let thumb = ModelEntity(mesh: .generateSphere(radius: 0.007), materials: [
                SimpleMaterial(color: .white, roughness: 0.8, isMetallic: false)])
            thumb.name = "switch-thumb"
            thumb.scale.z = 0.28
            thumb.position.z = 0.003
            item.entity.addChild(thumb)
        }
        guard animated, stage?.suspended == false, let previous else {
            slides.removeValue(forKey: id)
            drawSwitch(id, progress: target)
            retireClockIfIdle()
            return
        }
        let thumb = item.entity.findEntity(named: "switch-thumb")!
        let current = min(1, max(0, (thumb.position.x + 0.006)/0.012))
        if on != previous {
            slides[id] = Slide(from: current, to: target)
            startMotionClock()
        }
        drawSwitch(id, progress: slides[id] == nil ? target : current)
    }

    private func drawSwitch(_ id: UUID, progress: Float) {
        guard let item = items[id] else { return }
        item.entity.findEntity(named: "switch-thumb")?.position.x = -0.006 + 0.012 * progress
        let off = NSColor(calibratedWhite: 0.26, alpha: 1)
        var style = item.style
        style.color = off.blended(withFraction: CGFloat(progress), of: NSColor(DashboardTheme.cyan)) ?? off
        item.entity.model?.materials = [material(style)]
    }

    private func place(_ id: UUID) {
        guard let item = items[id] else { return }
        let world = Self.position(item.frame, viewport: size, level: item.style.level)
        if let parentID = item.style.parentID, parentID != id, let parent = items[parentID] {
            if item.style.rowOffset != nil {
                item.entity.position = [0, -Float(item.frame.midY)/1000, (parent.style.depth + Float(item.frame.height) + item.style.depth)/2000 + 0.0002]
                item.entity.isEnabled = item.style.visible && cos(parent.style.angle * .pi/180) >= 0
            } else {
                item.entity.position = world - Self.position(parent.frame, viewport: size, level: parent.style.level)
            }
            if item.entity.parent !== parent.entity { parent.entity.addChild(item.entity) }
        } else if item.style.parentID != nil {
            item.entity.removeFromParent()
        } else {
            item.entity.position = world
            if item.entity.parent !== root { root.addChild(item.entity) }
        }
    }
    private func material(_ style: RealitySurfaceStyle) -> SimpleMaterial {
        let base = style.color.usingColorSpace(.deviceRGB) ?? style.color
        let color = style.highlighted && style.enabled ? base.blended(withFraction: 0.22, of: .white)! : base
        return SimpleMaterial(color: style.enabled ? color : color.blended(withFraction: 0.45, of: .darkGray)!,
                              roughness: style.highlighted ? 0.32 : 0.62, isMetallic: true)
    }

    func setFace(_ image: CGImage, for id: UUID) {
        guard let item = items[id] else { return }
        if faces[id]?.0 === image, faces[id]?.2 == item.frame.size { return }
        guard let texture = try? TextureResource.generate(from: image, options: .init(semantic: .color)) else { return }
        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        material.blending = .transparent(opacity: .init(floatLiteral: 1))
        let face = faces[id]?.1 ?? ModelEntity()
        face.model = ModelComponent(mesh: .generatePlane(width: Float(item.frame.width) / 1000,
                                                         height: Float(item.frame.height) / 1000), materials: [material])
        face.position.z = item.style.depth / 2000 + 0.0001
        if face.parent == nil { (item.entity.findEntity(named: "row-pivot") ?? item.entity).addChild(face) }
        faces[id] = (image, face, item.frame.size)
    }
    func turn(_ id: UUID, degrees: Float, duration: Double) {
        guard let pivot = items[id]?.entity.findEntity(named: "row-pivot"), duration == 0 || stage?.suspended != true else { return }
        var target = pivot.transform
        target.rotation = simd_quatf(angle: degrees * .pi / 180, axis: [1, 0, 0])
        if duration == 0 { pivot.stopAllAnimations(); pivot.orientation = target.rotation }
        else { pivot.move(to: target, relativeTo: pivot.parent, duration: duration, timingFunction: .easeInOut) }
    }
    func attachDrawing(_ entity: Entity, to id: UUID) {
        guard let item = items[id] else { return }
        if entity.parent !== item.entity { item.entity.addChild(entity) }
        entity.position.z = item.style.depth / 2000 + 0.0002
    }
}

/// Point-space geometry is converted once to metres. All generated meshes have
/// real side faces; cards are not stacks of two-dimensional SwiftUI shapes.
enum RealityGeometry {
    static func outline(shape: RealityShape, size: CGSize) -> [SIMD2<Float>] {
        let w = Float(size.width / 1000), h = Float(size.height / 1000)
        switch shape {
        case .disc:
            return (0..<96).map { i in
                let a = Float(i) * 2 * .pi / 96
                return [cos(a) * w / 2, sin(a) * h / 2]
            }
        case .panel(let radius):
            let r = min(Float(radius / 1000), min(w, h) / 2)
            if r <= 0 { return [[w/2,h/2],[-w/2,h/2],[-w/2,-h/2],[w/2,-h/2]] }
            let centers: [SIMD2<Float>] = [[w/2-r, h/2-r], [-w/2+r, h/2-r], [-w/2+r, -h/2+r], [w/2-r, -h/2+r]]
            return centers.enumerated().flatMap { corner, center in
                (0...8).map { i in
                    let a = Float(corner) * .pi / 2 + Float(i) * .pi / 16
                    return center + SIMD2<Float>(cos(a), sin(a)) * r
                }
            }
        case .ring, .symbol, .dashboard: return []
        }
    }
    @MainActor static func mesh(shape: RealityShape, size: CGSize, depth: Float) throws -> MeshResource {
        if case .symbol = shape { throw CocoaError(.featureUnsupported) }
        var points: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], indices: [UInt32] = []
        func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, normal: SIMD3<Float>) {
            let start = UInt32(points.count); points += [a,b,c]; normals += [normal,normal,normal]
            indices += [start,start+1,start+2]
        }
        let half = max(0.0001, depth / 2000)
        if case .ring(let input) = shape {
            let fraction = Float(min(1, max(0, input.isFinite ? input : 0)))
            let radius = max(0.001, Float(min(size.width, size.height)) / 2000 - 0.0025)
            let tube: Float = 0.0025
            let segments = max(1, Int(ceil(128 * fraction))), sides = 8
            for segment in 0..<segments {
                let a = Float(segment) / Float(segments) * 2 * .pi * max(0.00001, fraction) - .pi / 2
                let b = Float(segment + 1) / Float(segments) * 2 * .pi * max(0.00001, fraction) - .pi / 2
                for side in 0..<sides {
                    let c = Float(side) * 2 * .pi / Float(sides), d = Float(side + 1) * 2 * .pi / Float(sides)
                    func vertex(_ theta: Float, _ phi: Float) -> SIMD3<Float> {
                        [cos(theta) * (radius + cos(phi) * tube), -sin(theta) * (radius + cos(phi) * tube), sin(phi) * tube]
                    }
                    let p = vertex(a,c), q = vertex(b,c), r = vertex(b,d), s = vertex(a,d)
                    let normal = simd_normalize(simd_cross(q-p, r-p))
                    triangle(p,q,r,normal: normal); triangle(p,r,s,normal: normal)
                }
            }
        } else {
            let polygon = outline(shape: shape, size: size)
            for i in polygon.indices {
                let a = polygon[i], b = polygon[(i+1) % polygon.count]
                guard simd_length_squared(b-a) > 1e-16 else { continue }
                let frontA = SIMD3<Float>(a.x,a.y,half), frontB = SIMD3<Float>(b.x,b.y,half)
                let backA = SIMD3<Float>(a.x,a.y,-half), backB = SIMD3<Float>(b.x,b.y,-half)
                triangle([0,0,half],frontA,frontB,normal: [0,0,1])
                triangle([0,0,-half],backB,backA,normal: [0,0,-1])
                let edge = b-a
                let normal = simd_normalize(SIMD3<Float>(edge.y,-edge.x,0))
                triangle(frontA,backA,backB,normal: normal); triangle(frontA,backB,frontB,normal: normal)
            }
        }
        var descriptor = MeshDescriptor(name: "v2rayM-surface")
        descriptor.positions = MeshBuffers.Positions(points)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(indices)
        return try MeshResource.generate(from: [descriptor])
    }
}
