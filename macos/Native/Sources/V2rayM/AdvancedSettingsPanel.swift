import SwiftUI
import V2rayMKit

enum SettingsPane: String, CaseIterable, Identifiable {
    case parameters = "参数设置", routing = "路由设置", dns = "DNS 设置", backup = "备份与恢复"
    var id: String { rawValue }
    var symbol: ControlAsset {
        switch self { case .parameters: return .sliders; case .routing: return .branch; case .dns: return .network; case .backup: return .folder }
    }
    var detail: String {
        switch self { case .parameters: return "监听、嗅探、Xray 与原生 TUN"; case .routing: return "方案、匹配顺序与分流规则"; case .dns: return "常规解析与自定义 DNS"; case .backup: return "节点、设置与订阅" }
    }
}

struct AdvancedSettingsPanel: View {
    @EnvironmentObject var model: AppModel
    let select: (SettingsPane) -> Void
    var body: some View {
        HStack(spacing: PageLayout.gap) {
            ForEach([SettingsPane.parameters, .routing, .dns]) { item in
                Button { select(item) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        RealityGlyph(asset: item.symbol, size: 20, color: DashboardTheme.accent)
                            .frame(width: 34, height: 34)

                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.rawValue).font(AppFont.body)
                            Text(item.detail).font(AppFont.caption).foregroundStyle(DashboardTheme.muted)
                                .lineLimit(2).frame(height: 30, alignment: .topLeading)
                        }
                        Spacer(minLength: 0)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .realityCard(radius: 7, depth: 4, level: 16, edge: DashboardTheme.cardEdge)
                }.buttonStyle(HoverButtonStyle(plain: true))
                    .disabled(!model.ready || model.busy || model.moduleUpdateActive)
            }
        }
    }
}

struct SettingsEditor: View {
    @State private var webDAV = SettingsValue.object([:])
    @State private var parameterDraft = ParameterSettingsDraft()
    @State private var dnsDraft = DNSSettingsDraft()
    @State private var routingDraft = RoutingSettingsDraft()
    @State private var selectActiveAfterPreset = false
    let pane: SettingsPane
    @EnvironmentObject var model: AppModel
    var homeRequest = 0
    var goHome: () -> Void = {}
    let close: () -> Void
    @State private var loaded = false
    @State private var working = false
    @State private var result = ""
    @State private var failed = false
    @State private var deleteConfirmation = false
    @State private var dirty = false
    @State private var dismissConfirmation = false
    @State private var returningHome = false

    private func requestReturn(home: Bool) {
        guard !working, !deleteConfirmation, !dismissConfirmation else { return }
        returningHome = home
        if dirty { dismissConfirmation = true } else { finishReturn() }
    }
    private func finishReturn() {
        if returningHome { goHome() } else { close() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { requestReturn(home: false) } label: {
                    RealityLabel(title: "返回设置", asset: .back)
                }.disabled(working).help("返回设置总览")
                Divider().frame(height: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(pane.rawValue).font(AppFont.title)
                    Text(pane.detail).font(AppFont.caption).foregroundStyle(DashboardTheme.muted)
                }
                Spacer()
                Text(dirty ? "未保存" : "").font(AppFont.caption).foregroundStyle(DashboardTheme.warning)
                    .frame(width: 56)
            }
            Divider()
            if loaded {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        switch pane {
                        case .backup:
                            BackupSettingsFields(settings: $webDAV, dirty: $dirty) { message, work in
                                action(success: message, work)
                            }

                        case .parameters: ParameterSettingsFields(settings: $parameterDraft.settings, tunSettings: $parameterDraft.tunSettings, dirty: $dirty)
                        case .routing:
                            RoutingSettingsFields(routes: routingDraft.routes, profiles: model.profiles, route: $routingDraft.route, rules: $routingDraft.rules,
                                routeID: $routingDraft.routeID, ruleIndex: $routingDraft.ruleIndex, dirty: $dirty,
                                select: { item in action(success: "已切换方案") { try await loadRoute(item) } },
                                create: newRoute, delete: { deleteConfirmation = true }, activate: {
                                    action {
                                        try await model.settingsWrite { try await $0.activateRoute(routingDraft.routeID) }
                                        try await reloadRoutes()
                                    }
                                }, importRoutes: {
                                    action(success: "路由方案已导入") {
                                        try await model.settingsWrite { try await $0.importRoutes() }
                                        try await reloadRoutes()
                                    }
                                }, applyPreset: { region in
                                    action(success: "地区预设已应用") {
                                        try await model.settingsWrite { try await $0.applyRegion(region) }
                                        loaded = false
                                        selectActiveAfterPreset = true
                                        try await reloadRoutes()
                                        loaded = true
                                    }
                                })
                        case .dns:
                            DNSSettingsFields(simpleDNS: $dnsDraft.simpleDNS, dns: $dnsDraft.dns, dirty: $dirty, remotePresets: dnsDraft.remotePresets,
                                saveSimple: { action {
                                    try await model.settingsWrite { try await $0.saveSettings(.simpleDNS, dnsDraft.simpleDNS) }
                                    dnsDraft.savedSimpleDNS = dnsDraft.simpleDNS
                                } }, saveCustom: { action {
                                    try await model.settingsWrite { try await $0.saveConfigurationProfile(.dns, dnsDraft.dns) }
                                    dnsDraft.savedCustomDNS = dnsDraft.dns
                                } })
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 2).background(SettingsWheelScroll())
                }.scrollIndicators(.never).realityClipped().disabled(working)
            } else {
                Spacer()
                if failed { Button("重新加载") { Task { await load() } }.frame(maxWidth: .infinity) }
                else { RealityBusyIndicator().frame(maxWidth: .infinity) }
                Spacer()
            }
            Divider()
            HStack {
                Text(!model.ready ? "后台服务未就绪，草稿已保留" : result.isEmpty ? (working ? "正在处理…" : "修改后保存，设置将自动应用") : result).font(AppFont.caption).foregroundStyle(failed ? DashboardTheme.warning : DashboardTheme.muted)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                InlineActivityIndicator(active: working)
                if !model.ready {
                    Button("重新连接服务") { Task { await model.connect() } }
                        .disabled(working || model.connecting)
                }
                if pane == .backup {
                    Button("保存 WebDAV 设置") {
                        action {
                            try await model.settingsWrite { try await $0.saveSettings(.webDAV, webDAV) }
                            webDAV = try await model.settingsRead { try await $0.settingsSection(.webDAV) }
                        }
                    }.disabled(!loaded || working || !dirty || !model.ready)
                }
                if pane == .parameters { Button("保存参数") { saveParameters() }.disabled(!loaded || working || !dirty || !model.ready) }
                if pane == .routing { Button("保存方案与规则") { saveRoute() }.disabled(!loaded || working || !dirty || !model.ready) }
            }.frame(height: 32)
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity).font(AppFont.body).buttonStyle(HoverButtonStyle())
            .task { await load() }
            .onChange(of: homeRequest) { requestReturn(home: true) }
            .alert("放弃未保存的修改？", isPresented: $dismissConfirmation) {
                Button("继续编辑", role: .cancel) {}
                Button("放弃修改", role: .destructive, action: finishReturn)
            }
            .alert("删除这个路由方案？", isPresented: $deleteConfirmation) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) { action {
                    try await model.settingsWrite { try await $0.deleteRoute(routingDraft.routeID) }
                    // The write was acknowledged. Only expose another document after its rules load.
                    loaded = false
                    try await reloadRoutes()
                    loaded = true
                } }
            }
    }
    private func action(success: String = "已保存并应用", _ work: @escaping () async throws -> Void) {
        working = true; result = ""; failed = false
        Task {
            defer { working = false }
            do { try await work(); if result.isEmpty { result = success }; dirty = pane == .dns && (dnsDraft.simpleDNS != dnsDraft.savedSimpleDNS || dnsDraft.dns != dnsDraft.savedCustomDNS) }
            catch { result = error.localizedDescription; failed = true }
        }
    }
    private func load() async {
        working = true; failed = false; result = ""
        defer { working = false }
        do {
            if pane == .backup { webDAV = try await model.settingsRead { try await $0.settingsSection(.webDAV) } }
            if pane == .parameters {
                parameterDraft.settings = try await model.settingsRead { try await $0.settings() }
                parameterDraft.settings["application"] = parameterDraft.settings["app"]
                parameterDraft.tunSettings = try await model.settingsRead { try await $0.settingsSection(.nativeTun) }
            }
            if pane == .routing { try await reloadRoutes() }
            if pane == .dns {
                let options = try await model.settingsRead { try await $0.editorResource(.dnsOptions) }
                dnsDraft.remotePresets = options["remoteDnsAddresses"].items.map(\.text)
                dnsDraft.simpleDNS = try await model.settingsRead { try await $0.settingsSection(.simpleDNS) }
                let profiles = try await model.settingsRead { try await $0.configurationProfiles(.dns) }
                guard let xray = profiles.items.first(where: { $0["coreType"].text.lowercased() == "xray" }) else { throw ClientFailure("dns_profile_not_found") }
                dnsDraft.dns = xray; dnsDraft.savedSimpleDNS = dnsDraft.simpleDNS; dnsDraft.savedCustomDNS = dnsDraft.dns
            }
            loaded = true
        } catch { result = error.localizedDescription; failed = true }
    }
    private func reloadRoutes() async throws {
        let routes = try await model.settingsRead { try await $0.routeDocuments() }.items
        routingDraft = try await routingDraft.refreshing(routes: routes, preferActive: selectActiveAfterPreset) { id in
            try await model.settingsRead { try await $0.routingRules(id: id) }.items
        }
        selectActiveAfterPreset = false
        dirty = routes.isEmpty
    }
    private func loadRoute(_ selected: SettingsValue) async throws {
        routingDraft = try await routingDraft.selecting(selected) { id in
            try await model.settingsRead { try await $0.routingRules(id: id) }.items
        }
        dirty = false
    }
    private func newRoute() {
        routingDraft.routeID = ""; routingDraft.route = RoutingDraft.newProfile()
        routingDraft.rules = []; routingDraft.ruleIndex = 0; dirty = true
    }
    private func saveParameters() {
        action {
            // Keep the full snapshot so hidden upstream options survive edits.
            try await model.settingsWrite { try await $0.saveSettings(.apply, parameterDraft.submission) }
            parameterDraft.settings = try await model.settingsRead { try await $0.settings() }
            parameterDraft.settings["application"] = parameterDraft.settings["app"]
            parameterDraft.tunSettings = try await model.settingsRead { try await $0.settingsSection(.nativeTun) }
        }
    }
    private func saveRoute() {
        action {
            guard !routingDraft.route["remarks"].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientFailure("routing_name_required") }
            let draft = routingDraft.submission()
            let response = try await model.settingsWrite { try await $0.saveRoute(id: routingDraft.savedID, draft) }
            routingDraft.acceptSaved(response)
            dirty = false
            do { try await reloadRoutes() }
            catch {
                result = "已保存，刷新失败；再次保存会更新同一方案。"
                return
            }
        }
    }
}
