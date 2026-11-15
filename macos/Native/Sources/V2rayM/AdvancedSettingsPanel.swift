import SwiftUI
import V2rayMKit

enum SettingsPane: String, CaseIterable, Identifiable {
    case parameters = "参数设置", routing = "路由设置", dns = "DNS 设置"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .parameters: return "slider.horizontal.3"; case .routing: return "arrow.triangle.branch"; case .dns: return "network" }
    }
    var detail: String {
        switch self { case .parameters: return "监听、嗅探、Xray 与原生 TUN"; case .routing: return "方案、匹配顺序与分流规则"; case .dns: return "常规解析与自定义 DNS" }
    }
}

struct AdvancedSettingsPanel: View {
    @EnvironmentObject var model: AppModel
    let select: (SettingsPane) -> Void
    var body: some View {
        HStack(spacing: 10) {
            ForEach(SettingsPane.allCases) { item in
                Button { select(item) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(DashboardTheme.cyan)
                            .frame(width: 34, height: 34)
                            .background(DashboardTheme.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.rawValue).font(AppFont.body)
                            Text(item.detail).font(AppFont.caption).foregroundStyle(.secondary)
                                .lineLimit(2).frame(height: 30, alignment: .topLeading)
                        }
                        Spacer(minLength: 0)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(DashboardTheme.cyan.opacity(0.18)))
                }.buttonStyle(HoverButtonStyle(plain: true))
                    .disabled(!model.ready || model.busy || model.moduleUpdateActive)
            }
        }
    }
}

struct SettingsEditor: View {
    @State private var parameterDraft = ParameterSettingsDraft()
    @State private var dnsDraft = DNSSettingsDraft()
    @State private var routingDraft = RoutingSettingsDraft()
    let pane: SettingsPane
    @EnvironmentObject var model: AppModel
    let close: () -> Void
    @State private var loaded = false
    @State private var working = false
    @State private var result = ""
    @State private var failed = false
    @State private var deleteConfirmation = false
    @State private var dirty = false
    @State private var dismissConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { if dirty { dismissConfirmation = true } else { close() } } label: {
                    Label("返回设置", systemImage: "chevron.left")
                }.disabled(working).help("返回设置总览")
                Divider().frame(height: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(pane.rawValue).font(AppFont.title)
                    Text(pane.detail).font(AppFont.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(dirty ? "未保存" : "").font(AppFont.caption).foregroundStyle(.orange)
                    .frame(width: 56)
            }
            Divider()
            if loaded {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        switch pane {
                        case .parameters: ParameterSettingsFields(settings: $parameterDraft.settings, tunSettings: $parameterDraft.tunSettings, dirty: $dirty)
                        case .routing:
                            RoutingSettingsFields(routes: routingDraft.routes, route: $routingDraft.route, rules: $routingDraft.rules,
                                routeID: $routingDraft.routeID, ruleIndex: $routingDraft.ruleIndex, dirty: $dirty,
                                select: { item in action(success: "已切换方案") { try await loadRoute(item) } },
                                create: newRoute, delete: { deleteConfirmation = true }, activate: {
                                    action {
                                        try await model.settingsWrite("/api/settings/routing-profiles/\(routingDraft.routeID)/activate", method: "POST")
                                        try await reloadRoutes()
                                    }
                                })
                        case .dns:
                            DNSSettingsFields(simpleDNS: $dnsDraft.simpleDNS, dns: $dnsDraft.dns, dirty: $dirty,
                                saveSimple: { action {
                                    try await model.settingsWrite("/api/settings/dns/simple", body: dnsDraft.simpleDNS)
                                    dnsDraft.savedSimpleDNS = dnsDraft.simpleDNS
                                } }, saveCustom: { action {
                                    try await model.settingsWrite("/api/settings/dns/profiles/Xray", body: dnsDraft.dns)
                                    dnsDraft.savedCustomDNS = dnsDraft.dns
                                } })
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 2)
                }.scrollIndicators(.never).disabled(working)
            } else {
                Spacer()
                if failed { Button("重新加载") { Task { await load() } }.frame(maxWidth: .infinity) }
                else { ProgressView().frame(maxWidth: .infinity) }
                Spacer()
            }
            Divider()
            HStack {
                Text(!model.ready ? "后台服务未就绪，草稿已保留" : result.isEmpty ? (working ? "正在处理…" : "修改后保存，设置将自动应用") : result).font(AppFont.caption).foregroundStyle(failed ? Color.orange : Color.secondary)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if working { ProgressView().controlSize(.small) }
                if !model.ready {
                    Button("重新连接服务") { Task { await model.connect() } }.disabled(working || model.connecting)
                }
                if pane == .parameters { Button("保存参数") { saveParameters() }.disabled(!loaded || working || !dirty || !model.ready) }
                if pane == .routing { Button("保存方案与规则") { saveRoute() }.disabled(!loaded || working || !dirty || !model.ready) }
            }.frame(height: 32)
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity).font(AppFont.body).buttonStyle(HoverButtonStyle())
            .background(HiddenScrollbars())
            .task { await load() }
            .alert("放弃未保存的修改？", isPresented: $dismissConfirmation) {
                Button("继续编辑", role: .cancel) {}
                Button("放弃修改", role: .destructive) { close() }
            }
            .alert("删除这个路由方案？", isPresented: $deleteConfirmation) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) { action {
                    try await model.settingsWrite("/api/settings/routing-profiles/\(routingDraft.routeID)", method: "DELETE")
                    try await reloadRoutes()
                } }
            }
    }
    private func action(success: String = "已保存并应用", _ work: @escaping () async throws -> Void) {
        working = true; result = ""; failed = false
        Task {
            defer { working = false }
            do { try await work(); result = success; dirty = pane == .dns && (dnsDraft.simpleDNS != dnsDraft.savedSimpleDNS || dnsDraft.dns != dnsDraft.savedCustomDNS) }
            catch { result = error.localizedDescription; failed = true }
        }
    }
    private func load() async {
        working = true; failed = false; result = ""
        defer { working = false }
        do {
            if pane == .parameters {
                parameterDraft.settings = try await model.settingsRead("/api/settings")
                parameterDraft.settings["application"] = parameterDraft.settings["app"]
                parameterDraft.tunSettings = try await model.settingsRead("/api/macos/tun/settings")
            }
            if pane == .routing { try await reloadRoutes() }
            if pane == .dns {
                dnsDraft.simpleDNS = try await model.settingsRead("/api/settings/dns/simple")
                let profiles = try await model.settingsRead("/api/settings/dns/profiles")
                guard let xray = profiles.items.first(where: { $0["coreType"].text.lowercased() == "xray" }) else { throw ClientFailure("dns_profile_not_found") }
                dnsDraft.dns = xray; dnsDraft.savedSimpleDNS = dnsDraft.simpleDNS; dnsDraft.savedCustomDNS = dnsDraft.dns
            }
            loaded = true
        } catch { result = error.localizedDescription; failed = true }
    }
    private func reloadRoutes() async throws {
        routingDraft.routes = try await model.settingsRead("/api/settings/routing-profiles").items
        let selected = routingDraft.routes.first(where: { $0["id"].text == routingDraft.routeID }) ?? routingDraft.routes.first(where: { $0["isActive"].flag }) ?? routingDraft.routes.first
        if let selected { try await loadRoute(selected) } else { newRoute() }
    }
    private func loadRoute(_ selected: SettingsValue) async throws {
        routingDraft = try await routingDraft.selecting(selected) { id in
            try await model.settingsRead("/api/settings/routing-profiles/\(id)/rules").items
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
            var input = parameterDraft.settings
            input["nativeTun"] = parameterDraft.tunSettings
            try await model.settingsWrite("/api/settings/apply", body: input)
            parameterDraft.settings = try await model.settingsRead("/api/settings")
            parameterDraft.settings["application"] = parameterDraft.settings["app"]
            parameterDraft.tunSettings = try await model.settingsRead("/api/macos/tun/settings")
        }
    }
    private func saveRoute() {
        action {
            guard !routingDraft.route["remarks"].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientFailure("routing_name_required") }
            var draft = routingDraft.route
            draft["ruleSet"] = .string(try SettingsValue.array(routingDraft.rules).json())
            let creating = routingDraft.routeID.isEmpty
            let knownIDs = Set(routingDraft.routes.map { $0["id"].text })
            try await model.settingsWrite("/api/settings/routing-profiles" + (creating ? "" : "/\(routingDraft.routeID)"), method: creating ? "POST" : "PUT", body: draft)
            if creating {
                routingDraft.routes = try await model.settingsRead("/api/settings/routing-profiles").items
                if let created = routingDraft.routes.first(where: { !knownIDs.contains($0["id"].text) && $0["remarks"] == draft["remarks"] }) { routingDraft.routeID = created["id"].text }
            }
            try await reloadRoutes()
        }
    }
}
