import SwiftUI

enum DashboardSolidKind {
    case disc, card
    var depth: CGFloat { self == .disc ? 18 : 12 }
}

/// Native semantic faces follow an orthographic RealityKit solid. The entity
/// owns thickness and lighting; the faces keep selectable, accessible content.
struct DashboardSolidSurface<Front: View, Back: View>: View, Animatable {
    var angle: Double
    var tilt: Double = 0
    let kind: DashboardSolidKind
    var animates = true
    var hover: Double
    let front: Front
    let back: Back
    @State private var surfaceID = UUID()
    @Environment(\.realityScene) private var scene
    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, Double> {
        get { .init(.init(animates ? angle : 0, animates ? tilt : 0), hover) }
        set { angle = newValue.first.first; tilt = newValue.first.second; hover = newValue.second }
    }
    init(angle: Double, tilt: Double = 0, kind: DashboardSolidKind, animates: Bool = true,
         hovered: Bool = false, front: Front, back: Back) {
        self.angle = angle; self.tilt = tilt; self.kind = kind; self.animates = animates
        hover = hovered ? 1 : 0; self.front = front; self.back = back
    }
    private var renderedAngle: Double { (animates ? angle : 0) - 8 * hover }
    private var renderedTilt: Double { (animates ? tilt : 0) + 5 * hover }
    private var faceScale: CGFloat { 1 + CGFloat(hover) * 0.032 }
    private var frontFacing: Bool { cos(renderedAngle * .pi / 180) >= 0 }
    var body: some View {
        front
            .coordinateSpace(name: surfaceID)
            .environment(\.insideRealitySolid, true)
            .environment(\.realityParentSurface, surfaceID)
            .opacity(frontFacing ? 1 : 0)
            .rotation3DEffect(.degrees(renderedAngle), axis: (x: 0, y: 1, z: 0), perspective: 0)
            .allowsHitTesting(frontFacing)
            .overlay {
                if !frontFacing {
                    back.environment(\.insideRealitySolid, true)
                        .rotation3DEffect(.degrees(renderedAngle - 180), axis: (x: 0, y: 1, z: 0), perspective: 0)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .rotation3DEffect(.degrees(animates ? tilt : 0), axis: (x: 1, y: 0, z: 0), perspective: 0.4)
            .rotation3DEffect(.degrees(5 * hover), axis: (x: 1, y: 0, z: 0), perspective: 0)
            .scaleEffect(faceScale)
            .background {
                GeometryReader { geometry in
                    let frame = scene.map { geometry.frame(in: .named(ObjectIdentifier($0))) }
                    if kind == .card {
                        RealitySurface(style: .init(shape: .shadow(10), depth: 0.25, level: 13.5,
                            angle: renderedAngle, tilt: renderedTilt, faceScale: faceScale, layoutFrame: frame?.offsetBy(dx: 1.5, dy: 2)), attachesToSceneRoot: true)
                    }
                    RealitySurface(style: .init(shape: .dashboard(kind == .disc ? .dial : .card),
                        depth: Float(kind.depth), level: 20, angle: renderedAngle,
                        tilt: renderedTilt, faceScale: faceScale, layoutFrame: frame), id: surfaceID, attachesToSceneRoot: true)
                }
            }
    }
}

private struct InsideRealitySolidKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var insideRealitySolid: Bool {
        get { self[InsideRealitySolidKey.self] }
        set { self[InsideRealitySolidKey.self] = newValue }
    }
}

struct RealityPanelModifier: ViewModifier {
    @Environment(\.insideRealitySolid) private var inside
    var radius: CGFloat = 10
    func body(content: Content) -> some View {
        content.background {
            if !inside { RealitySurface(style: .init(shape: .panel(radius))) }
        }
    }
}

struct DashboardActivationFlip: ViewModifier {
    let active: Bool
    var kind: DashboardSolidKind = .card
    var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dashboardFlipsEnabled) private var flipsEnabled
    @State private var angle = 0.0
    @State private var tilt = 0.0
    @State private var worker: Task<Void, Never>?
    func body(content: Content) -> some View {
        DashboardSolidSurface(angle: angle, tilt: tilt, kind: kind, animates: flipsEnabled && !reduceMotion, hovered: hovered && !reduceMotion, front: content,
            back: ZStack {
                Color.clear
                VStack(spacing: 8) {
                    Text("v2rayM").font(AppFont.size(kind == .disc ? 23 : 18))
                    Text("Xray").font(AppFont.caption).foregroundStyle(DashboardTheme.muted)
                }
            })
            .onChange(of: active) { old, new in
                cancel()
                guard !reduceMotion && flipsEnabled else { return }
                worker = Task { @MainActor in
                    if !old && new {
                        for (target, seconds) in [(170.0, 0.58), (350.0, 0.52), (362.0, 0.16), (360.0, 0.28)] {
                            guard !Task.isCancelled else { return }
                            withAnimation(.easeInOut(duration: seconds)) { angle = target }
                            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                        }
                    } else if old && !new {
                        withAnimation(.easeOut(duration: 0.16)) { tilt = -3 }
                        do { try await Task.sleep(for: .seconds(0.16)) } catch { return }
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeOut(duration: 0.38)) { tilt = 0 }
                        do { try await Task.sleep(for: .seconds(0.38)) } catch { return }
                    }
                    guard !Task.isCancelled else { return }
                    reset(); worker = nil
                }
            }
            .onChange(of: reduceMotion || !flipsEnabled) { _, disabled in if disabled { cancel() } }
            .onDisappear { cancel() }
    }
    private func cancel() { worker?.cancel(); worker = nil; reset() }
    private func reset() {
        guard angle != 0 || tilt != 0 else { return }
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { angle = 0; tilt = 0 }
    }
}

/// Keeps telemetry visible through shutdown; presentation never delays the core.
/// All cards share the same readiness gate, with separate start offsets.
struct DashboardCardTiming {
    var outward: TimeInterval = 0.95
    var inward: TimeInterval = 0.95
    var settle: TimeInterval = 0.30
    var stagger: TimeInterval = 0.55
    var duration: TimeInterval { outward + inward + settle }
}

@MainActor final class DashboardCardPresentation<Value: Equatable>: ObservableObject {
    @Published private(set) var displayed: Value
    @Published private(set) var presentedActive: Bool
    @Published private(set) var angle = 0.0
    private(set) var targetActive: Bool
    private var admitted: Bool
    private var latest: Value
    private var idle: Value
    private var worker: Task<Void, Never>?
    private var generation = 0
    private let slot: Int
    private let timing: DashboardCardTiming
    private let contentWhileHidden: Bool

    init(value: Value, idle: Value, active: Bool, ready: Bool, slot: Int,
         timing: DashboardCardTiming = DashboardCardTiming(), contentWhileHidden: Bool = false) {
        admitted = active && ready
        presentedActive = active && ready; targetActive = active && ready
        displayed = active && ready ? value : idle
        latest = value; self.idle = idle; self.slot = slot; self.timing = timing
        self.contentWhileHidden = contentWhileHidden
    }

    func update(value: Value, idle: Value, active: Bool, ready: Bool, reduced: Bool) {
        latest = value; self.idle = idle
        if !active { admitted = false }
        else if ready { admitted = true }
        let desired = active && admitted
        if reduced {
            cancel()
            targetActive = desired
            if presentedActive != desired { presentedActive = desired }
            setDisplayed(desired ? latest : idle)
            return
        }
        guard desired != targetActive else {
            if worker == nil { setDisplayed(presentedActive ? latest : idle) }
            return
        }
        cancel()
        targetActive = desired
        // Stopping before the first reveal simply cancels the queued opening.
        guard desired || presentedActive else { displayed = idle; return }
        let token = generation
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .seconds(Double(self.slot) * self.timing.stagger))
                guard self.generation == token, !Task.isCancelled else { return }
                withAnimation(.timingCurve(0.35, 0, 0.25, 1, duration: self.timing.outward)) { self.angle = 180 }
                try await Task.sleep(for: .seconds(self.timing.outward))
                guard self.generation == token, !Task.isCancelled else { return }
                // Opening data changes while the branded back faces the viewer.
                // Other cards retain the last face through shutdown; recent connections
                // opt into clearing while this branded back hides the content.
                if desired || self.contentWhileHidden {
                    self.displayed = desired ? self.latest : self.idle; self.presentedActive = desired
                }
                withAnimation(.timingCurve(0.30, 0, 0.20, 1, duration: self.timing.inward)) { self.angle = 362 }
                try await Task.sleep(for: .seconds(self.timing.inward))
                guard self.generation == token, !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: self.timing.settle)) { self.angle = 360 }
                try await Task.sleep(for: .seconds(self.timing.settle))
                guard self.generation == token, !Task.isCancelled else { return }
                self.withoutAnimation {
                    self.angle = 0; self.presentedActive = desired
                    self.displayed = desired ? self.latest : self.idle
                }
                self.worker = nil
            } catch { /* A newer lifecycle request owns presentation. */ }
        }
    }

    private func setDisplayed(_ value: Value) { if displayed != value { displayed = value } }
    func cancel() {
        generation += 1; worker?.cancel(); worker = nil
        withoutAnimation { if angle != 0 { angle = 0 } }
    }
    func disappear() {
        cancel()
        withoutAnimation { presentedActive = targetActive; displayed = targetActive ? latest : idle }
    }
    private func withoutAnimation(_ change: () -> Void) {
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }
}

private struct DashboardCardInput<Value: Equatable>: Equatable {
    let value: Value
    let idle: Value
    let active: Bool
    let ready: Bool
    let reduced: Bool
}

struct DashboardDataCard<Value: Equatable, Content: View>: View {
    let value: Value
    let idle: Value
    let active: Bool
    let ready: Bool
    let hovered: Bool
    let content: (Value, Bool) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.dashboardFlipsEnabled) private var flipsEnabled
    @StateObject private var presentation: DashboardCardPresentation<Value>
    init(value: Value, idle: Value, active: Bool, ready: Bool, slot: Int, contentWhileHidden: Bool = false, hovered: Bool = false,
         @ViewBuilder content: @escaping (Value, Bool) -> Content) {
        self.value = value; self.idle = idle; self.active = active; self.ready = ready; self.hovered = hovered; self.content = content
        _presentation = StateObject(wrappedValue: DashboardCardPresentation(value: value, idle: idle,
            active: active, ready: ready, slot: slot, contentWhileHidden: contentWhileHidden))
    }
    var body: some View {
        DashboardSolidSurface(angle: reduced ? 0 : presentation.angle, kind: .card, animates: flipsEnabled && !reduced, hovered: hovered && !reduced,
            front: content(presentation.displayed, presentation.presentedActive),
            back: ZStack {
                Color.clear
                VStack(spacing: 8) {
                    Text("v2rayM").font(AppFont.size(18))
                    Text("Xray").font(AppFont.caption).foregroundStyle(DashboardTheme.muted)
                }
            })
            .onChange(of: DashboardCardInput(value: value, idle: idle, active: active, ready: ready, reduced: reduced || !flipsEnabled), initial: true) { _, input in
                presentation.update(value: input.value, idle: input.idle, active: input.active,
                                    ready: input.ready, reduced: input.reduced)
            }
            .onDisappear { presentation.disappear() }
    }
}
