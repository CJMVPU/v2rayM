import SwiftUI
import Combine
import RealityKit

/// These snapshots contain only this app's page. The shared RealityKit scene
/// supplies the artwork, and AppKit supplies text, controls and scroll views.
@MainActor final class PageFaceView: NSView {
    let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    weak var scene: RealityWindowScene?
    var page: Page?
    override var isFlipped: Bool { true }
    override init(frame: CGRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        hosting.sizingOptions = []
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    func snapshot() async -> CGImage? {
        guard let stage = scene?.stage, window != nil, !bounds.isEmpty else { return nil }
        window?.contentView?.layoutSubtreeIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        stage.synchronize()
        // Wait for the renderer to consume the layout on its next scene update.
        let image: NSImage? = await withCheckedContinuation { continuation in
            var tick: (any Cancellable)?
            var pending = true
            func finish(_ image: NSImage?) {
                guard pending else { return }
                pending = false
                tick?.cancel()
                tick = nil
                continuation.resume(returning: image)
            }
            tick = stage.renderer.scene.subscribe(to: SceneEvents.Update.self) { _ in
                tick?.cancel()
                tick = nil
                DispatchQueue.main.async {
                    stage.renderer.snapshot(saveToHDR: false) { finish($0) }
                }
            }
            // A minimized window may never produce a frame.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { finish(nil) }
        }
        guard let image, !Task.isCancelled, let window, !stage.bounds.isEmpty,
              let text = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: text)
        let scale = window.backingScaleFactor
        guard let output = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((bounds.width * scale).rounded()),
            pixelsHigh: Int((bounds.height * scale).rounded()), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        output.size = bounds.size
        guard let graphics = NSGraphicsContext(bitmapImageRep: output) else { return nil }
        let frame = convert(bounds, to: stage)
        let sx = image.size.width / stage.bounds.width, sy = image.size.height / stage.bounds.height
        let crop = CGRect(x: frame.minX * sx, y: (stage.bounds.height - frame.maxY) * sy,
                          width: frame.width * sx, height: frame.height * sy)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        image.draw(in: bounds, from: crop, operation: .copy, fraction: 1)
        text.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        return output.cgImage
    }
}

struct PageTurnHost<Content: View>: NSViewRepresentable {
    let page: Page
    let navigation: PageCubeNavigation
    @Environment(\.realityScene) private var scene
    @ViewBuilder var content: Content
    func makeNSView(context: Context) -> PageFaceView { PageFaceView(frame: .zero) }
    func updateNSView(_ view: PageFaceView, context: Context) {
        navigation.view = view
        view.scene = scene
        scene?.nativePage = view
        // A second NSHostingView has its own SwiftUI environment. Forward
        // window-wide appearance and motion settings, never a card's parent,
        // local coordinate space, clip viewport, or front/back visibility.
        let root = content.environment(\.realityScene, scene)
            .environment(\.realityParentSurface, nil)
            .environment(\.realityViewport, nil)
            .environment(\.insideRealitySolid, false)
            .environment(\.realityContentVisible, true)
            .environment(\.dashboardMotionEnabled, context.environment.dashboardMotionEnabled)
            .environment(\.dashboardVisibilityOverride, context.environment.dashboardVisibilityOverride)
            .environment(\.scenePhase, context.environment.scenePhase)
            .disabled(!context.environment.isEnabled)
            .environment(\.font, context.environment.font)
            .environment(\.colorScheme, context.environment.colorScheme)
            .tint(DashboardTheme.accent)
            .foregroundStyle(DashboardTheme.text)
        if let scene {
            view.hosting.rootView = AnyView(root.coordinateSpace(name: ObjectIdentifier(scene)))
        } else { view.hosting.rootView = AnyView(root) }
        if view.page != page { view.page = page; navigation.pageDidMount() }
    }
}

@MainActor final class PageCubeNavigation {
    weak var view: PageFaceView?
    private var readiness: AsyncStream<Void>.Continuation?
    private var editorReady = false
    func pageDidMount() { readiness?.yield(()) }
    func editorDidLoad() { editorReady = true; readiness?.yield(()) }
    private var task: Task<Void, Never>?
    func cancel() { task?.cancel() }

    func turn(to target: Page, mount: @escaping () -> Bool, finished: @escaping () -> Void) {
        guard let view, view.window != nil else { _ = mount(); finished(); return }
        let overlay = PageCubeOverlay(frame: view.bounds)
        overlay.autoresizingMask = [.width, .height]
        view.addSubview(overlay, positioned: .above, relativeTo: view.hosting)
        overlay.startCursor()
        editorReady = false
        task = Task { @MainActor in
            defer {
                readiness?.finish()
                readiness = nil
                overlay.stopCursor()
                overlay.removeFromSuperview()
                finished()
                task = nil
            }
            let source = await view.snapshot()
            guard !Task.isCancelled else { return }
            if let source { overlay.cover(with: source) }
            let (events, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            readiness = signal
            let needsEditor = mount()
            guard source != nil else { return }
            var iterator = events.makeAsyncIterator()
            while view.page != target || (needsEditor && !editorReady) {
                guard await iterator.next() != nil, !Task.isCancelled else { return }
            }
            guard let destination = await view.snapshot(), !Task.isCancelled else { return }
            overlay.stopCursor()
            await overlay.rotate(to: destination, returning: target == .home)
        }
    }
}
