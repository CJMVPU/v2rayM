import AppKit
import RealityKit
import SwiftUI

/// A fitted instance shares its immutable mesh with every other occurrence.
/// Scale the visual child, leaving its anchor and input coordinates in metres.
@MainActor extension ControlAsset {
    func instance(size: CGSize, depth: Float, material: SimpleMaterial, fit: Bool = false) throws -> ModelEntity {
        let resource = try mesh()
        let entity = ModelEntity(mesh: resource, materials: [material])
        let extent = resource.bounds.extents
        let x = Float(size.width) / (1000 * extent.x), y = Float(size.height) / (1000 * extent.y)
        entity.scale = [fit ? min(x,y) : x, fit ? min(x,y) : y, depth / (1000 * extent.z)]
        entity.position = -resource.bounds.center * entity.scale
        entity.name = rawValue
        return entity
    }
}

struct RealityGlyph: View {
    let asset: ControlAsset
    var size: CGFloat = 14
    var color: Color = DashboardTheme.text
    var level: Float = 82
    @Environment(\.isEnabled) private var enabled
    @Environment(\.realityParentSurface) private var parent
    var body: some View {
        GeometryReader { proxy in
            let local = parent.map { proxy.frame(in: .named($0)) }
            let point = local.map { CGPoint(x: $0.midX, y: $0.midY) }
            RealitySurface(style: .init(shape: .glyph(asset), color: NSColor(color), depth: 1.6,
                level: level, enabled: enabled, facePoint: point))
        }.frame(width: size, height: size)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct RealityLabel: View {
    let title: String
    let asset: ControlAsset
    var color: Color = DashboardTheme.text
    var body: some View {
        HStack(spacing: 6) {
            RealityGlyph(asset: asset, color: color)
            Text(title)
        }
    }
}

extension View {
    /// Track the native viewport independently, so the offset shadow is clipped
    /// together with the card on both axes while settings scroll.
    func realityCard(radius: CGFloat = 10, depth: Float = 5, level: Float = 10, edge: Color = DashboardTheme.panel) -> some View {
        self.realitySurface(.init(shape: .cardPanel(radius), color: NSColor(edge),
                                  depth: depth, level: level))
            .background { RealityContactShadow(radius: radius, level: level - depth/2 - 0.35) }
    }
    func realityField(highlighted: Bool = false) -> some View {
        realitySurface(.init(shape: .well(5), color: NSColor(DashboardTheme.well), depth: 2, level: 22, highlighted: highlighted))
    }
}

struct RealityContactShadow: View {
    let radius: CGFloat
    let level: Float
    var angle: Double = 0
    var body: some View {
        RealitySurface(style: .init(shape: .shadow(radius), depth: 0.25, level: level, angle: angle))
            .offset(x: 1.5, y: 2).allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// A native menu owns keyboard tracking, type selection and accessibility.
/// Only the closed control's text and model are drawn inside the main window.
struct RealityMenuLabel: View {
    let title: String
    let highlighted: Bool
    var body: some View {
        HStack(spacing: 8) {
            Text(title).lineLimit(1)
            RealityGlyph(asset: .down, size: 9)
        }.padding(.horizontal, 7).padding(.vertical, 3).realityField(highlighted: highlighted)
    }
}

struct RealityChoice<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let values: [Value]
    let name: (Value) -> String
    var body: some View {
        RealityMenuButton(title: title, caption: name(selection), values: values,
                          selected: selection, name: name) { selection = $0 }
    }
}

struct RealityMenuButton<Value: Hashable>: View {
    let title: String
    let caption: String
    let values: [Value]
    var selected: Value?
    let name: (Value) -> String
    let activate: (Value) -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false
    var body: some View {
        RealityMenuLabel(title: caption, highlighted: hovered && enabled).fixedSize()
            .accessibilityHidden(true)
            .overlay {
                NativePopup(label: title, caption: caption, values: values, selected: selected,
                            titles: values.map(name), activate: activate)
            }.onHover { hovered = $0 }
    }
}

private struct NativePopup<Value: Hashable>: NSViewRepresentable {
    let label: String
    let caption: String
    let values: [Value]
    let selected: Value?
    let titles: [String]
    let activate: (Value) -> Void
    @Environment(\.isEnabled) private var enabled
    final class Button: NSPopUpButton {
        var pick: ((Int) -> Void)?
        override func draw(_ dirtyRect: NSRect) {}
        @objc func picked() { pick?(indexOfSelectedItem) }
    }
    func makeNSView(context: Context) -> Button {
        let button = Button(frame: .zero, pullsDown: false)
        button.isBordered = false
        button.target = button; button.action = #selector(Button.picked)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return button
    }
    func updateNSView(_ button: Button, context: Context) {
        if button.itemTitles != titles {
            button.removeAllItems()
            // Adding distinct menu items allows duplicate display names.
            for title in titles { button.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: "")) }
        }
        button.selectItem(at: selected.flatMap { values.firstIndex(of: $0) } ?? -1)
        button.isEnabled = enabled && !values.isEmpty
        button.setAccessibilityLabel(label)
        button.setAccessibilityValue(caption)
        button.pick = { index in if values.indices.contains(index) { activate(values[index]) } }
    }
}

struct RealitySegments: View {
    let title: String
    @Binding var selection: String
    let options: [String]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button { selection = option } label: {
                    Text(option).frame(maxWidth: .infinity).padding(.vertical, 3)
                        .realitySurface(.init(shape: .panel(4), color: NSColor(selection == option ? DashboardTheme.selectedPanel : DashboardTheme.panel),
                                              depth: 2, level: 26))
                }.buttonStyle(HoverButtonStyle(plain: true))
                    .accessibilityAddTraits(selection == option ? .isSelected : [])
            }
        }.padding(2).realityField()
        .onMoveCommand { direction in
            guard let index = options.firstIndex(of: selection) else { return }
            if direction == .left && index > 0 { selection = options[index-1] }
            if direction == .right && index+1 < options.count { selection = options[index+1] }
        }.accessibilityElement(children: .contain).accessibilityLabel(title)
    }
}

struct RealityProgressTrack: View {
    /// A nil fraction denotes indeterminate activity; zero retains an empty track.
    var fraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduced
    @Environment(\.dashboardMotionEnabled) private var motion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1/30, paused: fraction != nil || reduced || !motion)) { timeline in
            let phase = reduced || !motion ? 0.5 : 0.5 - 0.5*cos(timeline.date.timeIntervalSinceReferenceDate * 3)
            Color.clear.realitySurface(.init(shape: .well(3), color: NSColor(DashboardTheme.well),
                depth: 1.5, level: 24, progress: fraction ?? 0.22, progressOffset: fraction == nil ? phase : 0))
        }.frame(height: 6)
        .accessibilityElement(children: .ignore).accessibilityLabel("更新进度")
        .accessibilityValue(fraction.map { "\(Int(min(1,max(0,$0))*100))%" } ?? "正在处理")
    }
}

struct RealityBusyIndicator: View {
    var body: some View {
        RealityProgressTrack(fraction: nil).frame(width: 16)
            .accessibilityLabel("正在处理")
    }
}

@MainActor extension ModelEntity {
    func updateProgress(width: CGFloat, fraction: Double, offset: Double) {
        let fill: ModelEntity
        if let existing = findEntity(named: ControlAsset.progressFill.rawValue) as? ModelEntity { fill = existing }
        else {
            let material = SimpleMaterial(color: NSColor(DashboardTheme.accent), roughness: 0.72, isMetallic: false)
            guard let part = try? ControlAsset.progressFill.instance(size: CGSize(width: 24, height: 3),
                    depth: 1.2, material: material) else { return }
            fill = part
            fill.position.z = 0.0014
            addChild(fill)
        }
        let available = max(0, Float(width-3)/1000)
        let length = available * Float(min(1, max(0, fraction)))
        fill.isEnabled = length > 0
        if let bounds = fill.model?.mesh.bounds {
            fill.scale.x = length / bounds.extents.x
            fill.position.x = (available - length) * (Float(offset) - 0.5) - bounds.center.x * fill.scale.x
        }
    }
}
