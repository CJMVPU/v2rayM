import SwiftUI
import AppKit
import V2rayMKit

private enum Page: String, CaseIterable, Identifiable {
    case home = "主页", profiles = "节点", logs = "日志", settings = "设置"
    var id: String { rawValue }
}
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var page: Page = .home
    @State private var selectedProfile: String?
    @State private var importing = false
    @State private var deletingProfile: Profile?
    @State private var editingProfile: Profile?
    private var controlsDisabled: Bool { !model.ready || model.busy || model.moduleUpdateActive }
    var body: some View {
        VStack(spacing: 0) {
            titleBar
            if !model.ready && page != .home {
                ContentUnavailableView {
                    Label(model.connecting ? "正在连接本地服务" : "本地服务尚未连接", systemImage: "desktopcomputer")
                } description: { Text(model.connecting ? "首次启动可能需要几秒钟。" : "连接后即可管理节点。") }
                actions: {
                    if model.connecting { ProgressView().controlSize(.small) }
                    else { Button("重新连接服务") { Task { await model.connect() } } }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch page {
                case .home: homePage
                case .profiles: profilePage
                case .logs: LogConsole(entries: model.logs)
                case .settings: settingsPage
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .scrollIndicators(.hidden)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.32), lineWidth: 1.5)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) {
            Group {
                if let error = model.error { notice(error, error: true) }
                else if let message = model.message { notice(message, error: false) }
            }.frame(maxWidth: 440).padding(12)
        }
        // Expand the entire clipped surface into the title bar. Expanding only
        // its children leaves the clipping mask below them and hides controls.
        .ignoresSafeArea(.container, edges: .top)
        .task(id: model.message) {
            guard let message = model.message else { return }
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            if model.message == message { model.message = nil }
        }
        .sheet(isPresented: $importing) { ImportSheet { model.importNodes($0) } }
        .sheet(item: $editingProfile) { ProfileEditor(profile: $0).environmentObject(model) }
        .alert("删除节点？", isPresented: Binding(get: { deletingProfile != nil }, set: { if !$0 { deletingProfile = nil } })) {
            Button("取消", role: .cancel) { deletingProfile = nil }
            Button("删除", role: .destructive) { if let item = deletingProfile { model.deleteProfile(item) }; deletingProfile = nil }
        } message: { Text("正在使用的节点被删除时会断开连接。") }
    }
    private var titleBar: some View {
        HStack(spacing: 10) {
            WindowControlButtons().frame(width: 52, height: 34)
            HStack(spacing: 4) {
                ForEach(Page.allCases) { item in
                    Button { page = item } label: {
                        Group {
                            if item == .home { Image(systemName: "house") }
                            else { Text(item.rawValue) }
                        }
                            .foregroundStyle(page == item ? Color.accentColor : Color.secondary)
                            .frame(width: 44, height: 29)
                            .background {
                                if page == item {
                                    BottomJoinedTab().fill(Color(nsColor: .controlBackgroundColor))
                                        .overlay(BottomJoinedTab().stroke(Color.primary.opacity(0.18), lineWidth: 1))
                                }
                            }
                            .contentShape(Rectangle())
                    }.buttonStyle(HoverButtonStyle(plain: true))
                        .help(item.rawValue)
                        .accessibilityLabel(item.rawValue)
                        .accessibilityAddTraits(page == item ? [.isSelected] : [])
                }
            }.frame(height: 34, alignment: .bottom)
                .accessibilityElement(children: .contain).accessibilityLabel("页面")
            Spacer(minLength: 8)
            Button("导入节点") { importing = true }.disabled(controlsDisabled)
            if model.proxyNeedsRecovery {
                Button("恢复代理") { model.recoverProxy() }.disabled(model.busy || model.moduleUpdateActive)
            } else {
                Toggle("系统代理", isOn: Binding(get: { model.systemProxyEnabled && model.status?.coreRunning == true && model.tun?.isRunning != true }, set: { model.toggleProxy($0) }))
                    .toggleStyle(.switch).fixedSize().disabled(controlsDisabled)
            }
            Toggle("TUN", isOn: Binding(get: { model.tun?.isRunning == true }, set: { model.toggleTun($0) }))
                .toggleStyle(.switch).fixedSize().disabled(controlsDisabled || model.tun == nil)
            Image(systemName: model.status?.runtimeState == "faulted" ? "exclamationmark.circle.fill" : model.proxyRunning ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(model.status?.runtimeState == "faulted" ? .orange : model.proxyRunning ? .green : .secondary)
                .help(model.proxyDescription).accessibilityLabel(model.proxyDescription)
        }.controlSize(.small).padding(.leading, 12).padding(.trailing, 12).frame(height: 34)
            .background(alignment: .bottom) {
                Rectangle().fill(Color.primary.opacity(0.32)).frame(height: 2)
            }
            .background(Color(nsColor: .windowBackgroundColor))
    }
    private func notice(_ text: String, error: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: error ? "exclamationmark.circle.fill" : "info.circle.fill")
                .foregroundStyle(error ? .orange : .blue)
            Text(text).font(AppFont.body).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { if error { model.error = nil } else { model.message = nil } } label: { Image(systemName: "xmark") }
                .buttonStyle(HoverButtonStyle(plain: true)).help("关闭提示").accessibilityLabel("关闭提示")
        }.padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(error ? Color.orange.opacity(0.35) : Color.primary.opacity(0.12)))
            .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
    }
    private var profilePage: some View {
        VStack(spacing: 0) {
            if model.profiles.isEmpty {
                ContentUnavailableView {
                    Label("还没有节点", systemImage: "network")
                } description: { Text("点击标题栏的“导入节点”添加分享链接或配置。") }
                actions: { Button("导入节点") { importing = true } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.profiles, selection: $selectedProfile) {
                    TableColumn("节点") { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.isCurrent ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.isCurrent ? .green : .secondary)
                            Text(item.remarks.isEmpty ? item.address : item.remarks)
                                .lineLimit(1).frame(height: 22).help(item.remarks.isEmpty ? item.address : item.remarks)
                        }
                    }.width(304)
                    TableColumn("协议") { Text($0.protocol.uppercased()).font(AppFont.caption).foregroundStyle(.secondary) }.width(62)
                    TableColumn("传输") { Text($0.network.isEmpty ? "—" : $0.network).foregroundStyle(.secondary) }.width(64)
                    TableColumn("TLS") { Text(($0.streamSecurity ?? "").isEmpty ? "—" : ($0.streamSecurity ?? "").uppercased()).foregroundStyle(.secondary) }.width(64)
                    TableColumn("服务器") { Text(verbatim: "\($0.address):\($0.port)").foregroundStyle(.secondary).lineLimit(1).help("\($0.address):\($0.port)") }.width(170)
                    TableColumn("延迟") { Text($0.delay > 0 ? "\($0.delay) ms" : "—").monospacedDigit() }.width(75)
                }
                .controlSize(.small)
                .environment(\.defaultMinListRowHeight, 22)
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let item = model.profiles.first(where: { $0.id == id }) {
                        Button("设为当前节点") { model.select(item) }.disabled((model.busy || model.moduleUpdateActive))
                        Button("配置节点") { editingProfile = item }.disabled(controlsDisabled)
                        Button("测试延迟") { model.run { try await $0.perform("/api/profiles/\(item.id)/latency") } }.disabled((model.busy || model.moduleUpdateActive) || !item.canTest)
                        Divider()
                        Button("删除节点", role: .destructive) { deletingProfile = item }.disabled((model.busy || model.moduleUpdateActive))
                    }
                } primaryAction: { ids in
                    if let id = ids.first, let item = model.profiles.first(where: { $0.id == id }) { model.select(item) }
                }
            }
            Divider()
            HStack {
                Text("\(model.profiles.count) 个节点").font(AppFont.caption).foregroundStyle(.secondary)
                Spacer()
                let item = model.profiles.first(where: { $0.id == selectedProfile })
                Text(item?.coreType ?? "").font(AppFont.caption).foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                Button("配置节点") { editingProfile = item }
                    .disabled(item == nil || controlsDisabled)
                Button("设为当前节点") { if let item { model.select(item) } }
                    .disabled(item == nil || model.busy || model.moduleUpdateActive)
                    .opacity(item == nil ? 0 : 1)
                    .accessibilityHidden(item == nil)
            }.padding(.horizontal, 12).frame(height: 34)
        }
    }

    private var homePage: some View {
        HomeDashboard(showNodes: { page = .profiles }, showSettings: { page = .settings }, showLogs: { page = .logs })
            .environmentObject(model)
    }
    private func activateRoute(_ route: RoutingProfile) {
        guard !route.isActive else { return }
        model.run { try await $0.perform("/api/settings/routing-profiles/\(route.id)/activate") }
    }

    private func settingsSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(AppFont.body).foregroundStyle(.secondary)
            content()
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
    }
    private var settingsPage: some View {
        ScrollView {
            VStack(spacing: 1) {
                settingsSection("代理设置") {
                    HStack(spacing: 12) {
                        Text("路由规则").fixedSize()
                        ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(model.routes) { route in
                                Button { activateRoute(route) } label: {
                                    HStack(spacing: 7) {
                                        Image(systemName: route.isActive ? "largecircle.fill.circle" : "circle")
                                            .foregroundStyle(route.isActive ? Color.accentColor : Color.secondary)
                                        Text(route.remarks).lineLimit(1).fixedSize()
                                            .foregroundStyle(route.isActive ? Color.accentColor : Color.primary)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(HoverButtonStyle(plain: true)).disabled(controlsDisabled)
                                    .accessibilityLabel(route.remarks)
                                    .accessibilityAddTraits(route.isActive ? [.isSelected] : [])
                            }
                        }
                        }
                    }
                    LabeledContent("代理端口", value: model.status?.configuredProxyPort.map(String.init) ?? "—")
                    LabeledContent("Xray 内核", value: model.status?.xrayAvailable == true ? "已安装" : "未安装")
                }
                settingsSection("配置") { AdvancedSettingsPanel().environmentObject(model) }
                settingsSection("更新") { ModuleUpdatePanel().environmentObject(model) }
                settingsSection("TUN 后台服务") {
                    LabeledContent("TUN 状态", value: model.tun?.isRunning == true ? "运行中" : "已关闭")
                    LabeledContent("后台服务", value: model.tun?.helperDescription ?? "正在检查")
                    HStack {
                        if model.tun?.helperAvailable != true {
                            Button("安装并授权后台服务") { model.authorizeTun() }.disabled(controlsDisabled)
                        }
                        Button("打开后台服务设置") { model.openTunApproval() }.disabled(controlsDisabled)
                    }
                    Text("开启前请先暂停其他软件的 TUN 或 VPN。")
                        .font(AppFont.caption).foregroundStyle(.secondary)
                }
                settingsSection("日志与数据") {
                    Text("日志按顺序追加，最多保留 10,000 行；超出容量后淘汰最旧记录，切换代理模式不会清空。")
                        .font(AppFont.caption).foregroundStyle(.secondary)
                    Text(model.dataDirectory.path).font(AppFont.caption).textSelection(.enabled)
                    Button("在访达中打开") { NSWorkspace.shared.open(model.dataDirectory) }
                }
            }.frame(maxWidth: .infinity)
        }.scrollIndicators(.hidden).background(Color(nsColor: .separatorColor))
    }
}
private struct ImportSheet: View {
    @Environment(\.dismiss) var dismiss
    let save: (String) -> Void
    @State private var content = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导入节点").font(AppFont.title)
            Text("粘贴分享链接或兼容的配置内容，可一次导入多个节点。").foregroundStyle(.secondary)
            TextEditor(text: $content).font(AppFont.body).border(.separator).frame(height: 220)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("导入") { save(content); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 560).font(AppFont.body)
    }
}

/// The selected tab opens onto the content below; the outline has no bottom edge.
private struct BottomJoinedTab: Shape {
    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 8
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}
