import SwiftUI
import AppKit
import V2rayMKit

/// Fixed native text columns over RealityKit row surfaces. Focus, keyboard
/// selection, double-click activation and context actions share the same IDs.
struct RealityProfileTable: View {
    let profiles: [Profile]
    @Binding var selection: String?
    let controlsDisabled: Bool
    let select: (Profile) -> Void
    let edit: (Profile) -> Void
    let latency: (Profile) -> Void
    let delete: (Profile) -> Void
    @FocusState private var focused: Bool
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: PageLayout.gap) {
                    ForEach(profiles) { profile in
                        RealityProfileRow(profile: profile, selected: selection == profile.id) {
                            selection = profile.id; focused = true
                        }
                        .id(profile.id)
                        .simultaneousGesture(TapGesture(count: 2).onEnded { if !controlsDisabled { select(profile) } })
                        .contextMenu {
                            Button("设为当前节点") { select(profile) }.disabled(controlsDisabled)
                            Button("配置节点") { edit(profile) }.disabled(controlsDisabled)
                            Button("测试延迟") { latency(profile) }.disabled(controlsDisabled || !profile.canTest)
                            Divider()
                            Button("删除节点", role: .destructive) { delete(profile) }.disabled(controlsDisabled)
                        }
                    }
                }
            }
            .realityClipped()
            .focusable().focused($focused).focusEffectDisabled()
            .onKeyPress(.downArrow) { move(1); if let selection { proxy.scrollTo(selection) }; return .handled }
            .onKeyPress(.upArrow) { move(-1); if let selection { proxy.scrollTo(selection) }; return .handled }
            .onKeyPress(.return) {
                if !controlsDisabled, let profile = profiles.first(where: { $0.id == selection }) { select(profile) }
                return .handled
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel("节点表格")
    }
    private func move(_ delta: Int) {
        guard !profiles.isEmpty else { return }
        let current = profiles.firstIndex { $0.id == selection } ?? (delta > 0 ? -1 : profiles.count)
        selection = profiles[min(profiles.count - 1, max(0, current + delta))].id
    }
}

struct RealityProfileRow: View {
    let profile: Profile
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    private var name: String { profile.remarks.isEmpty ? profile.address : profile.remarks }
    private var network: String { profile.network.isEmpty ? "—" : profile.network }
    private var security: String { profile.streamSecurity.flatMap { $0.isEmpty ? nil : $0.uppercased() } ?? "—" }
    private var server: String {
        let host = profile.address
        return host.contains(":") && !host.hasPrefix("[") ? "[\(host)]:\(profile.port)" : "\(host):\(profile.port)"
    }
    private var delay: String { Self.delayLabel(profile.delay) }
    var accessibilitySummary: String {
        [profile.isCurrent ? "当前节点" : nil, "协议 " + profile.protocol.uppercased(), "传输 " + network, "TLS " + security,
         "服务器 " + server, "延迟 " + delay].compactMap { $0 }.joined(separator: "，")
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                HStack(spacing: 8) {
                    RealityGlyph(asset: profile.isCurrent ? .current : .circle, color: profile.isCurrent ? Color.green : DashboardTheme.muted)
                    Text(name).lineLimit(1).help(name)
                }.frame(width: 304, alignment: .leading)
                cell("协议", profile.protocol.uppercased(), width: 62)
                cell("传输", network, width: 64)
                cell("TLS", security, width: 64)
                cell("服务器", server, width: 170)
                cell("延迟", delay, width: 75)
            }.padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading).frame(height: TitleBarGeometry.height)
                .contentShape(Rectangle())
                .realitySurface(.init(shape: .dashboard(.titleBar),
                    depth: 3, level: 15, highlighted: hovering, selected: selected))
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityLabel(Text(verbatim: name))
            .accessibilityValue(Text(verbatim: accessibilitySummary))
    }
    static func delayLabel(_ delay: Int) -> String {
        if delay < 0 { return "失败" }
        return delay == 0 ? "未测" : "\(delay) ms"
    }
    private func cell(_ label: String, _ text: String, width: CGFloat) -> some View {
        Text(verbatim: text).font(AppFont.caption).foregroundStyle(DashboardTheme.muted)
            .lineLimit(1).frame(width: width, alignment: .leading).help(label + " " + text)
    }
}
