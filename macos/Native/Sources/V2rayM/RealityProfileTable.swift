import SwiftUI
import AppKit
import V2rayMKit

/// Fixed native text columns over RealityKit row surfaces. Focus, keyboard
/// selection, double-click activation and context actions share the same IDs.
struct RealityProfileTable: View {
    let profiles: [Profile]
    @Binding var selection: String?
    let busy: Bool
    let controlsDisabled: Bool
    let select: (Profile) -> Void
    let edit: (Profile) -> Void
    let latency: (Profile) -> Void
    let delete: (Profile) -> Void
    @FocusState private var focused: Bool
    static let columns: [(String, CGFloat)] = [("节点", 304), ("协议", 62), ("传输", 64), ("TLS", 64), ("服务器", 170), ("延迟", 75)]
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ForEach(Self.columns, id: \.0) { column in
                    Text(column.0).frame(width: column.1, alignment: .leading)
                }
            }.font(AppFont.caption).foregroundStyle(DashboardTheme.muted)
                .padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading).frame(height: TitleBarGeometry.height)
                .realitySurface(.init(shape: .dashboard(.titleBar), depth: 3, level: 12))
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 2) {
                        ForEach(profiles) { profile in
                            RealityProfileRow(profile: profile, selected: selection == profile.id) {
                                selection = profile.id; focused = true
                            }
                            .id(profile.id)
                            .simultaneousGesture(TapGesture(count: 2).onEnded { if !busy { select(profile) } })
                            .contextMenu {
                                Button("设为当前节点") { select(profile) }.disabled(busy)
                                Button("配置节点") { edit(profile) }.disabled(controlsDisabled)
                                Button("测试延迟") { latency(profile) }.disabled(busy || !profile.canTest)
                                Divider()
                                Button("删除节点", role: .destructive) { delete(profile) }.disabled(busy)
                            }
                        }
                    }.padding(.vertical, 4)
                }
                .realityClipped()
                .focusable().focused($focused).focusEffectDisabled()
                .onKeyPress(.downArrow) { move(1); if let selection { proxy.scrollTo(selection) }; return .handled }
                .onKeyPress(.upArrow) { move(-1); if let selection { proxy.scrollTo(selection) }; return .handled }
                .onKeyPress(.return) {
                    if !busy, let profile = profiles.first(where: { $0.id == selection }) { select(profile) }
                    return .handled
                }
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

private struct RealityProfileRow: View {
    let profile: Profile
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: profile.isCurrent ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(profile.isCurrent ? .green : DashboardTheme.muted)
                    Text(profile.remarks.isEmpty ? profile.address : profile.remarks).lineLimit(1)
                        .help(profile.remarks.isEmpty ? profile.address : profile.remarks)
                }.frame(width: 304, alignment: .leading)
                cell(profile.protocol.uppercased(), width: 62)
                cell(profile.network.isEmpty ? "—" : profile.network, width: 64)
                cell((profile.streamSecurity ?? "").isEmpty ? "—" : profile.streamSecurity!.uppercased(), width: 64)
                cell("\(profile.address):\(profile.port)", width: 170)
                cell(profile.delay > 0 ? "\(profile.delay) ms" : "—", width: 75)
            }.padding(.horizontal, 12).frame(maxWidth: .infinity, alignment: .leading).frame(height: TitleBarGeometry.height)
                .contentShape(Rectangle())
                .realitySurface(.init(shape: .dashboard(.titleBar),
                    depth: 3, level: 15, highlighted: hovering, selected: selected))
        }.buttonStyle(.plain).onHover { hovering = $0 }
            .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
    private func cell(_ text: String, width: CGFloat) -> some View {
        Text(verbatim: text).font(AppFont.caption).foregroundStyle(DashboardTheme.muted)
            .lineLimit(1).frame(width: width, alignment: .leading).help(text)
    }
}
