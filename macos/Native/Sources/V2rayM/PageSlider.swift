import SwiftUI

enum PageLayout {
    static let gap: CGFloat = 8
}

/// Place both live pages in layout coordinates so native controls and their
/// RealityKit anchors follow the same horizontal movement.
private enum PageSlot: LayoutValueKey { static let defaultValue = 0 }

private struct PageStrip: Layout {
    var origin: CGFloat
    var animatableData: CGFloat {
        get { origin }
        set { origin = newValue }
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for view in subviews {
            let x = bounds.minX + (CGFloat(view[PageSlot.self]) - origin) * bounds.width
            view.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: .init(bounds.size))
        }
    }
}

struct PageSlider<Content: View>: View {
    private struct Slot: Identifiable {
        let id: Page
        let index: Int
    }
    let selection: Page
    @ViewBuilder let content: (Page) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.realityScene) private var scene
    @State private var slots: [Slot]
    @State private var origin = 0
    @State private var requested: Page
    @State private var generation = 0

    init(selection: Page, @ViewBuilder content: @escaping (Page) -> Content) {
        self.selection = selection
        self.content = content
        _slots = State(initialValue: [Slot(id: selection, index: 0)])
        _requested = State(initialValue: selection)
    }
    var body: some View {
        PageStrip(origin: CGFloat(origin)) {
            ForEach(slots) { slot in
                content(slot.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .geometryGroup()
                    .allowsHitTesting(slots.count == 1)
                    .accessibilityHidden(slot.id != selection)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { _ in
                        scene?.requestLayoutSync(recheckScrollAncestors: false)
                    }
                    .layoutValue(key: PageSlot.self, value: slot.index)
            }
        }
        .clipped()
        .onChange(of: selection) { _, next in
            requested = next
            if reduceMotion { settle(on: next) }
            else if slots.count == 1 { slide(to: next) }
        }
        .onChange(of: reduceMotion) { if reduceMotion { settle(on: selection) } }
    }
    private func settle(on page: Page) {
        generation += 1
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            origin = 0
            slots = [Slot(id: page, index: 0)]
        }
    }
    private func slide(to page: Page) {
        guard let source = slots.last, source.id != page else { return }
        let order = Page.allCases
        let forward = order.firstIndex(of: page)! > order.firstIndex(of: source.id)!
        let destination = Slot(id: page, index: source.index + (forward ? 1 : -1))
        slots = [source, destination]
        let ticket = generation
        withAnimation(.timingCurve(0.16, 0.78, 0.28, 1, duration: 0.32), completionCriteria: .removed) {
            origin = destination.index
        } completion: {
            guard generation == ticket else { return }
            slots = [destination]
            if requested != page { slide(to: requested) }
        }
    }
}
