import SwiftUI
import AppKit
import V2rayMKit

private enum Page: String, CaseIterable, Identifiable {
    case profiles = "节点", subscriptions = "订阅", logs = "日志", settings = "设置"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .profiles: "network"; case .subscriptions: "arrow.triangle.2.circlepath";
        case .logs: "text.alignleft"; case .settings: "slider.horizontal.3" }
    }
}
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var page: Page? = .profiles
    @State private var selectedProfile: String?
    @State private var importing = false
    @State private var addingSubscription = false
    @State private var editingSubscription: Subscription?
    @State private var deletingSubscription: Subscription?
    @State private var deletingProfile: Profile?
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 27)).foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text("v2rayM").font(.title2.weight(.semibold))
                        Text("为 macOS 而生").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 16).padding(.top, 20)
                List(Page.allCases, selection: $page) { item in
                    Label(item.rawValue, systemImage: item.symbol).tag(item)
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 7) {
                    Label(model.ready ? "本地服务已连接" : model.connecting ? "正在启动本地服务" : "本地服务未连接",
                          systemImage: model.ready ? "checkmark.circle.fill" : "circle.dotted")
                        .foregroundStyle(model.ready ? .green : .secondary)
                    Text("\(model.profiles.count) 个节点 · \(model.subscriptions.count) 个订阅").foregroundStyle(.secondary)
                }.font(.caption).padding(16)
            }.navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 240)
        } detail: {
            VStack(spacing: 0) {
                connectionBar
                if let error = model.error { notice(error, error: true) }
                else if let message = model.message { notice(message, error: false) }
                if !model.ready {
                    ContentUnavailableView {
                        Label(model.connecting ? "正在连接本地服务" : "本地服务尚未连接", systemImage: "desktopcomputer")
                    } description: {
                        Text(model.connecting ? "首次启动可能需要几秒钟。" : "连接后即可管理节点和订阅。")
                    } actions: {
                        if model.connecting { ProgressView().controlSize(.small) }
                        else { Button("重新连接") { Task { await model.connect() } }.buttonStyle(.borderedProminent) }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    switch page ?? .profiles {
                    case .profiles: profilePage
                    case .subscriptions: subscriptionPage
                    case .logs: logPage
                    case .settings: settingsPage
                    }
                }
            }
            .navigationTitle((page ?? .profiles).rawValue)
            .toolbar {
                if model.busy || model.operations.contains(where: { $0 != "core" }) { ProgressView().controlSize(.small) }
                Button { model.run { _ in } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .disabled(!model.ready || model.busy).help("刷新列表（⌘R）")
            }
        }
        .frame(minWidth: 880, minHeight: 600)
        .sheet(isPresented: $importing) { ImportSheet { content, group in model.importNodes(content, subscription: group) } }
        .sheet(isPresented: $addingSubscription) { SubscriptionSheet(existing: nil) { model.saveSubscription(name: $0, url: $1, enabled: $2, existing: nil) } }
        .sheet(item: $editingSubscription) { item in
            SubscriptionSheet(existing: item) { model.saveSubscription(name: $0, url: $1, enabled: $2, existing: item) }
        }
        .alert("删除订阅？", isPresented: Binding(get: { deletingSubscription != nil }, set: { if !$0 { deletingSubscription = nil } })) {
            Button("取消", role: .cancel) { deletingSubscription = nil }
            Button("删除订阅及节点", role: .destructive) { if let item = deletingSubscription { model.deleteSubscription(item) }; deletingSubscription = nil }
        } message: { Text("该订阅下的节点也会被删除。正在使用其中节点时会先断开连接。") }
        .alert("删除节点？", isPresented: Binding(get: { deletingProfile != nil }, set: { if !$0 { deletingProfile = nil } })) {
            Button("取消", role: .cancel) { deletingProfile = nil }
            Button("删除", role: .destructive) { if let item = deletingProfile { model.deleteProfile(item) }; deletingProfile = nil }
        } message: { Text("正在使用的节点被删除时会断开连接。") }
    }
    private var connectionBar: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(model.status?.coreRunning == true ? Color.green.opacity(0.12) : Color.secondary.opacity(0.08))
                Image(systemName: "power").font(.title2).foregroundStyle(model.status?.coreRunning == true ? .green : .secondary)
            }.frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.status?.coreRunning == true ? "已连接" : "未连接").font(.headline)
                Text(model.status?.coreRunning == true ? (model.status?.runningProfileName ?? "代理内核运行中") : "选择一个节点，开始连接")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 10)
            if model.proxyNeedsRecovery {
                Button("恢复系统代理") { model.recoverProxy() }.disabled(model.busy)
            } else {
                Toggle("系统代理", isOn: Binding(get: { model.systemProxyEnabled }, set: { model.toggleProxy($0) }))
                    .toggleStyle(.switch).fixedSize().disabled(!model.ready || model.busy).help("让支持系统代理的应用通过当前节点访问网络")
            }
            Button(model.status?.coreRunning == true ? "断开连接" : "连接") { model.toggleCore() }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.ready || model.busy || model.proxyNeedsRecovery)
        }.padding(20).background(.background)
    }
    private func notice(_ text: String, error: Bool) -> some View {
        HStack {
            Image(systemName: error ? "exclamationmark.circle.fill" : "info.circle.fill")
                .foregroundStyle(error ? .orange : .blue)
            Text(text).font(.callout).textSelection(.enabled)
            Spacer()
            Button { if error { model.error = nil } else { model.message = nil } } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
        }.padding(12).background(error ? Color.orange.opacity(0.08) : Color.blue.opacity(0.06))
    }
    private var profilePage: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("分组", selection: $model.subscriptionFilter) {
                    Text("全部节点").tag("")
                    ForEach(model.subscriptions) { Text($0.remarks).tag($0.id) }
                }.labelsHidden().frame(maxWidth: 200)
                TextField("搜索节点名称、地址", text: $model.search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                Button { importing = true } label: { Label("导入节点", systemImage: "plus") }.disabled(model.busy)
            }.padding(16)
            if model.filteredProfiles.isEmpty {
                ContentUnavailableView {
                    Label(model.profiles.isEmpty ? "还没有节点" : "没有匹配的节点", systemImage: "network")
                } description: { Text(model.profiles.isEmpty ? "导入节点分享链接，或添加订阅后更新节点。" : "试试其他关键词或分组。") }
                actions: { if model.profiles.isEmpty { Button("导入节点") { importing = true }; Button("添加订阅") { addingSubscription = true } } }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.filteredProfiles, selection: $selectedProfile) {
                    TableColumn("节点") { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.isCurrent ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.isCurrent ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.remarks.isEmpty ? item.address : item.remarks).fontWeight(item.isCurrent ? .semibold : .regular)
                                Text(item.subscriptionName ?? "手动导入").font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 6)
                        }
                    }.width(min: 180, ideal: 280)
                    TableColumn("协议") { Text($0.protocol.uppercased()).font(.caption.monospaced()).foregroundStyle(.secondary) }.width(85)
                    TableColumn("服务器") { Text("\($0.address):\($0.port)").foregroundStyle(.secondary).lineLimit(1) }
                    TableColumn("延迟") { Text($0.delay > 0 ? "\($0.delay) ms" : "—").monospacedDigit() }.width(75)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let item = model.profiles.first(where: { $0.id == id }) {
                        Button("使用此节点") { model.select(item) }.disabled(model.busy)
                        Button("测试延迟") { model.run { try await $0.perform("/api/profiles/\(item.id)/latency") } }.disabled(model.busy || !item.canTest)
                        Divider()
                        Button("删除节点", role: .destructive) { deletingProfile = item }.disabled(model.busy)
                    }
                } primaryAction: { ids in
                    if let id = ids.first, let item = model.profiles.first(where: { $0.id == id }) { model.select(item) }
                }
            }
            Divider()
            HStack {
                Text("\(model.filteredProfiles.count) 个节点").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let item = model.profiles.first(where: { $0.id == selectedProfile }) {
                    Text(item.coreType).font(.caption).foregroundStyle(.secondary)
                    Button("使用此节点") { model.select(item) }.disabled(model.busy)
                }
            }.padding(12)
        }
    }
    private var subscriptionPage: some View {
        VStack(spacing: 0) {
            HStack {
                Text("订阅管理").font(.headline)
                Spacer()
                Button(model.operations.contains(where: { $0.hasPrefix("subscription") }) ? "正在更新…" : "更新全部") { model.updateSubscription() }.disabled(model.subscriptions.isEmpty || model.busy || model.operations.contains(where: { $0.hasPrefix("subscription") }))
                Button { addingSubscription = true } label: { Label("添加订阅", systemImage: "plus") }.disabled(model.busy)
            }.padding(20)
            if model.subscriptions.isEmpty {
                ContentUnavailableView("还没有订阅", systemImage: "arrow.triangle.2.circlepath", description: Text("添加订阅地址，然后更新获取节点。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.subscriptions) { item in
                    HStack(spacing: 14) {
                        Image(systemName: "link.circle.fill").font(.largeTitle).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Text(item.remarks).font(.headline); if !item.enabled { Text("已停用").font(.caption).foregroundStyle(.secondary) } }
                            // Subscription URLs can contain access tokens. Show only their host here.
                            Text(URL(string: item.url)?.host ?? "订阅地址").font(.caption).foregroundStyle(.secondary)
                            Text("\(model.profiles.filter { $0.subscriptionId == item.id }.count) 个节点").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("更新") { model.updateSubscription(item.id) }.disabled(model.busy)
                        Button("编辑") { editingSubscription = item }.disabled(model.busy)
                        Button { deletingSubscription = item } label: { Image(systemName: "trash") }.disabled(model.busy).help("删除订阅")
                    }.padding(.vertical, 12)
                }.listStyle(.inset)
            }
        }
    }
    private var logPage: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(Array(model.logs.enumerated()), id: \.offset) { _, log in
                    HStack(alignment: .top, spacing: 10) {
                        Text(String(log.timestamp.prefix(19)).replacingOccurrences(of: "T", with: " ")).foregroundStyle(.secondary).frame(width: 155, alignment: .leading)
                        Text(log.source).foregroundStyle(.tint).frame(width: 75, alignment: .leading)
                        Text(log.message).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    }.font(.system(size: 11, design: .monospaced))
                }
                if model.logs.isEmpty { Text("暂无日志").foregroundStyle(.secondary) }
            }.padding(20)
        }
    }
    private var settingsPage: some View {
        Form {
            Section("代理服务") {
                Picker("路由规则", selection: Binding(get: { model.routes.first(where: \.isActive)?.id ?? "" },
                    set: { id in model.run { try await $0.perform("/api/settings/routing-profiles/\(id)/activate") } })) {
                    ForEach(model.routes) { Text($0.remarks).tag($0.id) }
                }.disabled(model.busy)
                LabeledContent("代理端口", value: model.status?.configuredProxyPort.map(String.init) ?? "—")
                LabeledContent("Xray 内核", value: model.status?.xrayAvailable == true ? "已安装" : "未安装")
                Button("安装或更新 Xray") { model.installXray() }.disabled(model.busy)
                Text("普通代理与系统代理无需 Developer ID 证书。修改系统代理时，macOS 可能请求管理员授权。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("本地数据") {
                Text(model.dataDirectory.path).font(.caption).textSelection(.enabled)
                Button("在访达中打开") { NSWorkspace.shared.open(model.dataDirectory) }
            }
            Section("TUN") {
                Text("特权 helper 已预留，当前版本使用普通代理。TUN 将在签名与系统授权验证完成后开放。")
                    .foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

private struct ImportSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var content = ""
    @State private var group = ""
    let save: (String, String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("导入节点").font(.title2.weight(.semibold))
            Text("粘贴分享链接或兼容的配置内容，可一次导入多个节点。").foregroundStyle(.secondary)
            Picker("导入到", selection: $group) { Text("未分组").tag(""); ForEach(model.subscriptions) { Text($0.remarks).tag($0.id) } }
            TextEditor(text: $content).font(.system(.body, design: .monospaced)).border(.separator).frame(height: 220)
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("导入") { save(content, group); dismiss() }.keyboardShortcut(.defaultAction).disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 560)
    }
}
private struct SubscriptionSheet: View {
    @Environment(\.dismiss) var dismiss
    let existing: Subscription?
    let save: (String, String, Bool) -> Void
    @State private var name = ""
    @State private var url = ""
    @State private var enabled = true
    private var valid: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let value = URL(string: url),
              ["http", "https"].contains(value.scheme?.lowercased()), value.host != nil else { return false }
        return true
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(existing == nil ? "添加订阅" : "编辑订阅").font(.title2.weight(.semibold))
            Form {
                TextField("名称", text: $name)
                TextField("订阅地址", text: $url, prompt: Text("https://…"))
                Toggle("启用订阅", isOn: $enabled)
            }.textFieldStyle(.roundedBorder)
            HStack { Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") { save(name.trimmingCharacters(in: .whitespacesAndNewlines), url.trimmingCharacters(in: .whitespacesAndNewlines), enabled); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(!valid) }
        }.padding(24).frame(width: 520)
            .onAppear { name = existing?.remarks ?? ""; url = existing?.url ?? ""; enabled = existing?.enabled ?? true }
    }
}
