import SwiftUI

/// A half turn out and back in: the edge-on jump avoids mirrored text on the back.
struct DashboardActivationFlip: ViewModifier {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activation = 0
    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 0.0, trigger: activation) { view, angle in
            view.rotation3DEffect(.degrees(reduceMotion ? 0 : angle), axis: (x: 0, y: 1, z: 0), perspective: 0.35)
        } keyframes: { _ in
            CubicKeyframe(-90, duration: 0.22)
            MoveKeyframe(90)
            CubicKeyframe(0, duration: 0.32)
        }
        .onChange(of: active) { old, new in
            if !old && new && !reduceMotion { activation += 1 }
        }
    }
}

/// A stable row slot swaps content only while edge-on. A newer update cancels
/// the pending swap, so fast refreshes cannot restore an obsolete connection.
struct DashboardFlipValue<Value: Equatable, Content: View>: View {
    let value: Value
    let identity: String
    let content: (Value) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayed: Value
    @State private var displayedIdentity: String
    @State private var angle = 0.0
    init(value: Value, identity: String, @ViewBuilder content: @escaping (Value) -> Content) {
        self.value = value; self.identity = identity; self.content = content
        _displayed = State(initialValue: value)
        _displayedIdentity = State(initialValue: identity)
    }
    var body: some View {
        content(displayedIdentity == identity ? value : displayed)
            .rotation3DEffect(.degrees(reduceMotion ? 0 : angle), axis: (x: 1, y: 0, z: 0), perspective: 0.25)
            .task(id: identity) {
                guard identity != displayedIdentity, !reduceMotion else {
                    settle(); return
                }
                withAnimation(.easeIn(duration: 0.18)) { angle = -90 }
                do { try await Task.sleep(for: .milliseconds(180)) }
                catch { return }
                guard !Task.isCancelled else { return }
                var transaction = Transaction(); transaction.disablesAnimations = true
                withTransaction(transaction) {
                    displayed = value; displayedIdentity = identity; angle = 90
                }
                // Give SwiftUI a frame to install the new front face at the same edge.
                do { try await Task.sleep(for: .milliseconds(16)) }
                catch { return }
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24)) { angle = 0 }
            }
            .onChange(of: reduceMotion) { _, reduced in if reduced { settle() } }
    }
    private func settle() {
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { displayed = value; displayedIdentity = identity; angle = 0 }
    }
}
