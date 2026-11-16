import SwiftUI

/// A consistent material: the fill remains neutral; the lower edge and shadow
/// provide depth without tinting the card when animation is idle.
struct DashboardRelief: ViewModifier {
    var radius: CGFloat = 10
    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: radius).strokeBorder(
                LinearGradient(colors: [.white.opacity(0.12), .black.opacity(0.32)],
                               startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.28), radius: 1, y: 2)
        .shadow(color: .black.opacity(0.25), radius: 5, y: 4)
    }
}

enum DashboardSolidKind {
    case disc, card, row
    var shape: AnyShape {
        self == .disc ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: self == .row ? 5 : 10))
    }
    var depth: CGFloat { self == .disc ? 10 : self == .card ? 7 : 3 }
}

/// Layered cross-sections give the turn an actual visible side. Only the facing
/// face is drawn; its back text is counter-mirrored, so there is no edge-on jump.
struct DashboardSolidSurface<Front: View, Back: View>: View, Animatable {
    var angle: Double
    let kind: DashboardSolidKind
    let front: Front
    let back: Back
    var animatableData: Double { get { angle } set { angle = newValue } }
    private var vertical: Bool { kind == .row }
    private var frontFacing: Bool { cos(angle * .pi / 180) >= 0 }
    private var activity: Double { abs(sin(angle * .pi / 180)) }
    private func plane<V: View>(_ view: V, depth: CGFloat) -> some View {
        view.rotation3DEffect(.degrees(angle), axis: vertical ? (x: 1, y: 0, z: 0) : (x: 0, y: 1, z: 0),
                              anchorZ: depth, perspective: vertical ? 0.6 : 0.7)
    }
    var body: some View {
        // The original face owns layout. Extrusion must not accept the parent's
        // larger proposal (notably the space reserved for the traffic rings).
        front.hidden().overlay {
            GeometryReader { geometry in
                ZStack {
                    ForEach(0..<9) { index in
                        plane(kind.shape.fill(LinearGradient(colors: [Color(white: 0.34), Color(white: 0.11)],
                            startPoint: .topLeading, endPoint: .bottomTrailing)),
                              depth: kind.depth * (CGFloat(index) / 8 - 0.5))
                            .opacity(min(1, activity * 8))
                            .accessibilityHidden(true).allowsHitTesting(false)
                    }
                    plane(front.clipShape(kind.shape).overlay(light).opacity(frontFacing ? 1 : 0), depth: -kind.depth / 2)
                        .allowsHitTesting(frontFacing)
                    plane(back.clipShape(kind.shape).overlay(light)
                        .scaleEffect(x: vertical ? 1 : -1, y: vertical ? -1 : 1)
                        .opacity(frontFacing ? 0 : 1), depth: kind.depth / 2)
                        .accessibilityHidden(true).allowsHitTesting(false)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .rotation3DEffect(.degrees(activity * (vertical ? 5 : -9)), axis: vertical ? (x: 0, y: 1, z: 0) : (x: 1, y: 0, z: 0), perspective: 0.3)
        .scaleEffect(1 + activity * (vertical ? 0.008 : 0.018))
        .shadow(color: .black.opacity(0.25 + activity * 0.12), radius: vertical ? 1.5 : 5 + activity * 3,
                x: activity * 2, y: vertical ? 1.5 : 4 + activity * 3)
    }
    private var light: some View {
        kind.shape.fill(LinearGradient(colors: [.white.opacity(activity * 0.16), .clear, .black.opacity(activity * 0.30)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
            .allowsHitTesting(false)
    }
}

struct DashboardActivationFlip: ViewModifier {
    let active: Bool
    var kind: DashboardSolidKind = .card
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activation = 0
    @State private var stopping = 0
    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 0.0, trigger: activation) { view, angle in
            DashboardSolidSurface(angle: reduceMotion ? 0 : angle, kind: kind, front: view,
                back: ZStack {
                    kind.shape.fill(DashboardTheme.panel)
                    VStack(spacing: 8) {
                        Text("v2rayM").font(AppFont.size(kind == .disc ? 23 : 18))
                        Text("Xray").font(AppFont.caption).foregroundStyle(DashboardTheme.muted)
                    }
                })
        } keyframes: { _ in
            CubicKeyframe(170, duration: 0.58)
            CubicKeyframe(350, duration: 0.52)
            CubicKeyframe(362, duration: 0.16)
            CubicKeyframe(360, duration: 0.28)
            MoveKeyframe(0)
        }
        .keyframeAnimator(initialValue: 0.0, trigger: stopping) { view, tilt in
            view.rotation3DEffect(.degrees(reduceMotion ? 0 : tilt), axis: (x: 1, y: 0, z: 0), perspective: 0.4)
        } keyframes: { _ in
            CubicKeyframe(-3, duration: 0.16)
            CubicKeyframe(0, duration: 0.38)
        }
        .onChange(of: active) { old, new in
            guard !reduceMotion else { return }
            if !old && new { activation += 1 }
            else if old && !new { stopping += 1 }
        }
    }
}

enum DashboardRowTiming {
    static let minimumRest: TimeInterval = 1.8
    static func delay(slot: Int, identity: String) -> TimeInterval {
        // Slot phases deliberately alternate; identity adds independent jitter.
        let phases = [0.31, 0.74, 0.12, 0.59, 0.22, 0.86, 0.45]
        let hash = identity.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
        return phases[abs(slot % 7)] + Double(hash % 17) * 0.008
    }
}

/// Each slot owns a single coalescing worker. Updates during a turn wait for that
/// turn to settle, then only the latest pending record is shown after a rest.
struct DashboardFlipValue<Value: Equatable, Content: View>: View {
    let value: Value
    let identity: String
    var slot = 0
    let content: (Value) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayed: Value
    @State private var displayedIdentity: String
    @State private var pending: Value
    @State private var pendingIdentity: String
    @State private var incoming: Value
    @State private var angle = 0.0
    @State private var worker: Task<Void, Never>?
    @State private var lastFinish = Date.distantPast
    init(value: Value, identity: String, slot: Int = 0, @ViewBuilder content: @escaping (Value) -> Content) {
        self.value = value; self.identity = identity; self.slot = slot; self.content = content
        _displayed = State(initialValue: value); _incoming = State(initialValue: value)
        _pending = State(initialValue: value)
        _displayedIdentity = State(initialValue: identity); _pendingIdentity = State(initialValue: identity)
    }
    var body: some View {
        DashboardSolidSurface(angle: reduceMotion ? 0 : angle, kind: .row,
            front: content(displayedIdentity == identity ? value : displayed), back: content(incoming))
            .onChange(of: value) { _, _ in enqueue() }
            .onAppear { enqueue() }
            .onDisappear { worker?.cancel(); worker = nil; settle() }
            .onChange(of: reduceMotion) { _, reduced in
                if reduced { worker?.cancel(); worker = nil; settle() }
            }
    }
    private func enqueue() {
        pending = value; pendingIdentity = identity
        guard !reduceMotion else { settle(); return }
        guard worker == nil else { return }
        guard pendingIdentity != displayedIdentity else { displayed = pending; return }
        worker = Task { @MainActor in
            while pendingIdentity != displayedIdentity {
                let rest = max(0, DashboardRowTiming.minimumRest - Date().timeIntervalSince(lastFinish))
                let delay = max(rest, DashboardRowTiming.delay(slot: slot, identity: pendingIdentity))
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled else { return }
                if pendingIdentity == displayedIdentity { break }
                let target = pending, targetID = pendingIdentity
                incoming = target
                withAnimation(.timingCurve(0.35, 0, 0.18, 1, duration: 1.12)) { angle = 180 }
                do { try await Task.sleep(for: .seconds(1.16)) } catch { return }
                guard !Task.isCancelled else { return }
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) { displayed = target; displayedIdentity = targetID; angle = 0 }
                lastFinish = Date()
            }
            worker = nil
        }
    }
    private func settle() {
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) {
            displayed = value; displayedIdentity = identity; pending = value; pendingIdentity = identity
            incoming = value; angle = 0
        }
    }
}
