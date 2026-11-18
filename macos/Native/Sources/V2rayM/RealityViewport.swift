import AppKit
import SwiftUI

private struct RealityViewportKey: EnvironmentKey { static let defaultValue: UUID? = nil }
extension EnvironmentValues {
    var realityViewport: UUID? {
        get { self[RealityViewportKey.self] }
        set { self[RealityViewportKey.self] = newValue }
    }
}

extension View {
    /// SwiftUI's clip can be narrower than an AppKit scroll view's safe-area
    /// extended clip. Apply the same viewport to the separate RealityKit scene.
    func realityClipped() -> some View { modifier(RealityViewportModifier()) }
}

private struct RealityViewportModifier: ViewModifier {
    @State private var id = UUID()
    func body(content: Content) -> some View {
        content.environment(\.realityViewport, id)
            .background { RealityViewport(id: id).allowsHitTesting(false).accessibilityHidden(true) }
            .clipped()
    }
}

private struct RealityViewport: NSViewRepresentable {
    let id: UUID
    @Environment(\.realityScene) private var scene
    func makeNSView(context: Context) -> RealityViewportAnchor { RealityViewportAnchor(id: id) }
    func updateNSView(_ view: RealityViewportAnchor, context: Context) {
        view.owner = scene; scene?.registerViewport(view); scene?.requestLayoutSync()
    }
    static func dismantleNSView(_ view: RealityViewportAnchor, coordinator: ()) {
        view.owner?.removeViewport(view.id)
    }
}

@MainActor final class RealityViewportAnchor: NSView {
    let id: UUID
    weak var owner: RealityWindowScene?
    init(id: UUID) { self.id = id; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); owner?.requestLayoutSync() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); owner?.requestLayoutSync() }
}
