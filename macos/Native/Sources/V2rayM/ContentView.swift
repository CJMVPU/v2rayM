import SwiftUI
import AppKit
import V2rayMKit

enum Page: String, CaseIterable, Identifiable {
    case home = "主页", profiles = "节点", logs = "日志", settings = "设置"
    var id: String { rawValue }
    var symbol: RealityNavigationSymbol {
        switch self { case .home: return .home; case .profiles: return .nodes; case .logs: return .logs; case .settings: return .settings }
    }
}
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var page: Page = .home
    @State private var settingsEditing = false
    @State private var selectedProfile: String?
    @State private var importing = false
    @State private var deletingProfile: Profile?
    @State private var editingProfile: Profile?
    private var editingContent: Bool { settingsEditing || importing || editingProfile != nil }
    private var controlsDisabled: Bool { !model.ready || model.busy || model.moduleUpdateActive }
    init(initialPage: Page = .home) { _page = State(initialValue: initialPage) }
    var body: some View {
        RealityWindow {
            VStack(spacing: 0) {
                titleBar.zIndex(1)
                PageSlider(selection: page) { displayedPage in
                    pageContent(displayedPage)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .scrollIndicators(.never)
            .foregroundStyle(DashboardTheme.text)
            .background(HiddenScrollbars())
            .realitySurface(.init(shape: .panel(14), color: NSColor(DashboardTheme.background), depth: 10, level: -20))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .bottomTrailing) {
                Group {
                    if let error = model.error { notice(error, error: true) }
                    else if let message = model.message { notice(message, error: false) }
                }.frame(maxWidth: 440).padding(12)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // Expand the entire clipped surface into the title bar. Expanding only
        // its children leaves the clipping mask below them and hides controls.
        .ignoresSafeArea(.container, edges: .top)
        .task(id: model.message) {
            guard let message = model.message else { return }
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            if model.message == message { model.message = nil }
        }
        .onChange(of: model.homeRequest) { if !editingContent { page = .home } }
        .alert("删除节点？", isPresented: Binding(get: { deletingProfile != nil }, set: { if !$0 { deletingProfile = nil } })) {
            Button("取消", role: .cancel) { deletingProfile = nil }
            Button("删除", role: .destructive) { if let item = deletingProfile { model.deleteProfile(item) }; deletingProfile = nil }
        } message: { Text("正在使用的节点被删除时会断开连接。") }
    }
    @ViewBuilder private func pageContent(_ displayedPage: Page) -> some View {
        if importing {
            ImportPane(close: { importing = false }, save: { try await model.importNodes($0) })
                .environmentObject(model)
        } else if let profile = editingProfile {
            ProfileEditor(profile: profile, close: { editingProfile = nil }).environmentObject(model)
        } else if !model.ready && displayedPage != .home && !settingsEditing {
            ContentUnavailableView {
                RealityLabel(title: model.connecting ? "正在连接本地服务" : "本地服务尚未连接", asset: .desktop)
            } description: { Text(model.connecting ? "首次启动可能需要几秒钟。" : "连接后即可管理节点。") }
            actions: {
                if model.connecting { RealityBusyIndicator() }
                else { Button("重新连接服务") { Task { await model.connect() } } }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch displayedPage {
            case .home: homePage
            case .profiles: profilePage
            case .logs: ObservedLogConsole(state: model.logState)
                .padding(3).realityField().padding(PageLayout.gap)
            case .settings: SettingsPage(navigationLocked: $settingsEditing).environmentObject(model)
            }
        }
    }

    private var titleBar: some View {
        HStack(spacing: 10) {
            WindowControlButtons().frame(width: 50, height: 24)
            HStack(spacing: 4) {
                ForEach(Page.allCases) { item in
                    RealityNavigationIcon(symbol: item.symbol, selected: page == item, label: item.rawValue) {
                        page = item
                    }.disabled(editingContent)
                }
            }.frame(height: 24, alignment: .center)
                .accessibilityElement(children: .contain).accessibilityLabel("页面")
            Spacer(minLength: 8)
            ZStack {
                Toggle("系统代理", isOn: Binding(get: { model.desiredMode == .system }, set: { model.toggleProxy($0) }))
                    .environment(\.realityContentVisible, !model.proxyNeedsRecovery)
                    .toggleStyle(RealityToggleStyle()).fixedSize().disabled(!model.canToggle(.system) || editingContent || model.proxyNeedsRecovery)
                    .opacity(model.proxyNeedsRecovery ? 0 : 1).accessibilityHidden(model.proxyNeedsRecovery)
                if model.proxyNeedsRecovery {
                    Button("恢复代理") { model.recoverProxy() }.disabled(model.busy || model.moduleUpdateActive)
                }
            }
            Toggle("TUN", isOn: Binding(get: { model.desiredMode == .tun }, set: { model.toggleTun($0) }))
                .toggleStyle(RealityToggleStyle()).fixedSize().disabled(!model.canToggle(.tun) || model.tun == nil || editingContent)
        }.controlSize(.small).padding(.horizontal, 12).frame(height: TitleBarGeometry.height)
            .overlay {
                Text("powered by cj")
                    .font(.custom("SnellRoundhand-Bold", size: 17))
                    .foregroundStyle(DashboardTheme.graphite)
                    .shadow(color: .black.opacity(0.95), radius: 0.5, x: 0, y: -1)
                    .shadow(color: .white.opacity(0.16), radius: 0.4, x: 0, y: 1)
                    .allowsHitTesting(false).accessibilityLabel("powered by cj")
            }
            .realitySurface(.init(shape: .dashboard(.titleBar), depth: 4, level: 50))
            .background {
                RealitySurface(style: .init(shape: .panel(TitleBarGeometry.cornerRadius), color: NSColor(white: 0.075, alpha: 1),
                                            depth: 1, level: 44))
                    .offset(y: 1.25).allowsHitTesting(false).accessibilityHidden(true)
            }
            .padding(.horizontal, TitleBarGeometry.sideMargin)
            .padding(.top, TitleBarGeometry.topMargin)
    }

    private func notice(_ text: String, error: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RealityGlyph(asset: error ? .warning : .notice, color: error ? DashboardTheme.error : DashboardTheme.accent, level: 107)
            Text(text).font(AppFont.body).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { if error { model.error = nil } else { model.message = nil } } label: { RealityGlyph(asset: .close, size: 12, level: 107) }
                .buttonStyle(HoverButtonStyle(plain: true)).help("关闭提示").accessibilityLabel("关闭提示")
        }.padding(12)
            .realityCard(radius: 8, depth: 6, level: 100)
    }
    private var profilePage: some View {
        VStack(spacing: PageLayout.gap) {
            if model.profiles.isEmpty {
                ContentUnavailableView {
                    RealityLabel(title: "还没有节点", asset: .network)
                } description: { Text("导入分享链接或配置，添加你的第一个节点。") }
                actions: { Button("导入节点") { importing = true } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                RealityProfileTable(profiles: model.profiles, selection: $selectedProfile,
                    busy: model.busy || model.moduleUpdateActive, controlsDisabled: controlsDisabled,
                    select: { model.select($0) }, edit: { editingProfile = $0 },
                    latency: { item in model.run { try await $0.perform("/api/profiles/\(item.id)/latency") } },
                    delete: { deletingProfile = $0 })
            }
            HStack {
                Text("\(model.profiles.count) 个节点").font(AppFont.caption).foregroundStyle(DashboardTheme.muted)
                Button("导入节点") { importing = true }.disabled(controlsDisabled)
                Spacer()
                let item = model.profiles.first(where: { $0.id == selectedProfile })
                Text(item?.coreType ?? "").font(AppFont.caption).foregroundStyle(DashboardTheme.muted)
                    .frame(width: 44, alignment: .trailing)
                Button("配置节点") { editingProfile = item }
                    .disabled(item == nil || controlsDisabled)
                Button("设为当前节点") { if let item { model.select(item) } }
                    .environment(\.realityContentVisible, item != nil)
                    .disabled(item == nil || model.busy || model.moduleUpdateActive)
                    .opacity(item == nil ? 0 : 1)
                    .accessibilityHidden(item == nil)
            }.padding(.horizontal, 12).frame(height: TitleBarGeometry.height)
                .realitySurface(.init(shape: .dashboard(.titleBar), depth: 3, level: 18))
        }
        .padding(PageLayout.gap)
    }

    private var homePage: some View {
        HomeDashboard()
            .environmentObject(model)
    }

}
