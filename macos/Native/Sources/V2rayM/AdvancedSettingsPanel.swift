import SwiftUI
import V2rayMKit

private enum SettingsPane: String, CaseIterable, Identifiable {
    case parameters = "参数设置", routing = "路由设置", dns = "DNS 设置"
    var id: String { rawValue }
}

struct AdvancedSettingsPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var pane: SettingsPane?
    var body: some View {
        HStack(spacing: 16) {
            ForEach(SettingsPane.allCases) { item in
                Button(item.rawValue) { pane = item }.disabled(!model.ready || model.busy || model.moduleUpdateActive)
            }
            Spacer()
            Text("Xray · 原生 TUN").font(AppFont.caption).foregroundStyle(.secondary)
        }.sheet(item: $pane) { pane in SettingsEditor(pane: pane).environmentObject(model) }
    }
}

private struct SettingsEditor: View {
    let pane: SettingsPane
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var settings = SettingsValue.object([:])
    @State private var tunSettings = SettingsValue.object([:])
    @State private var savedSimpleDNS = SettingsValue.object([:])
    @State private var savedCustomDNS = SettingsValue.object([:])
    @State private var simpleDNS = SettingsValue.object([:])
    @State private var dns = SettingsValue.object([:])
    @State private var routes: [SettingsValue] = []
    @State private var route = SettingsValue.object([:])
    @State private var rules: [SettingsValue] = []
    @State private var routeID = ""
    @State private var ruleIndex = 0
    @State private var loaded = false
    @State private var working = false
    @State private var result = ""
    @State private var failed = false
    @State private var deleteConfirmation = false
    @State private var dirty = false
    @State private var dismissConfirmation = false
    @State private var parameterGroup = "监听与嗅探"
    private let groups = ["监听与嗅探", "Xray 参数", "应用与测速", "原生 TUN"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(pane.rawValue).font(AppFont.title)
                Spacer()
                Button("关闭") { if dirty { dismissConfirmation = true } else { dismiss() } }.disabled(working)
            }
            Divider()
            if loaded {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        switch pane {
                        case .parameters: parameters
                        case .routing: routing
                        case .dns: dnsSettings
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
                Text(result).font(AppFont.caption).foregroundStyle(failed ? Color.orange : Color.secondary)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if working { ProgressView().controlSize(.small) }
                if pane == .parameters { Button("保存参数") { saveParameters() }.disabled(!loaded || working) }
                if pane == .routing { Button("保存方案与规则") { saveRoute() }.disabled(!loaded || working) }
            }.frame(height: 32)
        }.padding(16).frame(width: 796, height: 510).font(AppFont.body).buttonStyle(HoverButtonStyle())
            .background(HiddenScrollbars())
            .interactiveDismissDisabled(dirty || working)
            .task { await load() }
            .alert("放弃未保存的修改？", isPresented: $dismissConfirmation) {
                Button("继续编辑", role: .cancel) {}
                Button("放弃修改", role: .destructive) { dismiss() }
            }
            .alert("删除这个路由方案？", isPresented: $deleteConfirmation) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) { action {
                    try await model.settingsWrite("/api/settings/routing-profiles/\(routeID)", method: "DELETE")
                    try await reloadRoutes()
                } }
            }
    }
    private func action(_ work: @escaping () async throws -> Void) {
        working = true; result = ""; failed = false
        Task {
            defer { working = false }
            do { try await work(); result = "已保存并应用"; dirty = pane == .dns && (simpleDNS != savedSimpleDNS || dns != savedCustomDNS) }
            catch { result = error.localizedDescription; failed = true }
        }
    }
    private func load() async {
        working = true
        defer { working = false }
        do {
            settings = try await model.settingsRead("/api/settings")
            settings["application"] = settings["app"]
            if pane == .parameters { tunSettings = try await model.settingsRead("/api/macos/tun/settings") }
            if pane == .routing { try await reloadRoutes() }
            if pane == .dns {
                simpleDNS = try await model.settingsRead("/api/settings/dns/simple")
                let profiles = try await model.settingsRead("/api/settings/dns/profiles")
                guard let xray = profiles.items.first(where: { $0["coreType"].text.lowercased() == "xray" }) else { throw ClientFailure("dns_profile_not_found") }
                dns = xray; savedSimpleDNS = simpleDNS; savedCustomDNS = dns
            }
            loaded = true
        } catch { result = error.localizedDescription; failed = true }
    }
    private func reloadRoutes() async throws {
        routes = try await model.settingsRead("/api/settings/routing-profiles").items
        let selected = routes.first(where: { $0["id"].text == routeID }) ?? routes.first(where: { $0["isActive"].flag }) ?? routes.first
        if let selected { try await loadRoute(selected) } else { newRoute() }
    }
    private func loadRoute(_ selected: SettingsValue) async throws {
        route = selected; routeID = selected["id"].text
        rules = try await model.settingsRead("/api/settings/routing-profiles/\(routeID)/rules").items
        ruleIndex = 0; dirty = false
    }
    private func newRoute() {
        routeID = ""; route = RoutingDraft.newProfile()
        rules = []; ruleIndex = 0; dirty = true
    }
    private func saveParameters() {
        action {
            // Keep the full snapshot so hidden upstream options survive edits.
            var input = settings
            input["nativeTun"] = tunSettings
            try await model.settingsWrite("/api/settings/apply", body: input)
            settings = try await model.settingsRead("/api/settings")
            settings["application"] = settings["app"]
            tunSettings = try await model.settingsRead("/api/macos/tun/settings")
        }
    }
    private func saveRoute() {
        action {
            guard !route["remarks"].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientFailure("routing_name_required") }
            var draft = route
            draft["ruleSet"] = .string(try SettingsValue.array(rules).json())
            let creating = routeID.isEmpty
            let knownIDs = Set(routes.map { $0["id"].text })
            try await model.settingsWrite("/api/settings/routing-profiles" + (creating ? "" : "/\(routeID)"), method: creating ? "POST" : "PUT", body: draft)
            if creating {
                routes = try await model.settingsRead("/api/settings/routing-profiles").items
                if let created = routes.first(where: { !knownIDs.contains($0["id"].text) && $0["remarks"] == draft["remarks"] }) { routeID = created["id"].text }
            }
            try await reloadRoutes()
        }
    }
    private func value(_ root: Binding<SettingsValue>, _ key: String) -> Binding<SettingsValue> {
        Binding(get: { root.wrappedValue[key] }, set: { root.wrappedValue[key] = $0; dirty = true })
    }
    private func text(_ root: Binding<SettingsValue>, _ key: String) -> Binding<String> {
        let binding = value(root, key)
        return Binding(get: { binding.wrappedValue.text }, set: { binding.wrappedValue = .string($0) })
    }
    private func toggle(_ title: String, _ root: Binding<SettingsValue>, _ key: String) -> some View {
        let binding = value(root, key)
        return Toggle(title, isOn: Binding(get: { binding.wrappedValue.flag }, set: { binding.wrappedValue = .bool($0) }))
    }
    private func field(_ title: String, _ root: Binding<SettingsValue>, _ key: String) -> some View {
        HStack { Text(title).frame(width: 180, alignment: .leading); TextField("", text: text(root, key)).textFieldStyle(.roundedBorder) }
    }
    private func number(_ title: String, _ root: Binding<SettingsValue>, _ key: String, range: ClosedRange<Int>) -> some View {
        let binding = value(root, key)
        return HStack {
            Text(title).frame(width: 180, alignment: .leading)
            TextField("", value: Binding<Int>(get: { Int(binding.wrappedValue.text) ?? 0 }, set: { binding.wrappedValue = .number(Double(min(range.upperBound, max(range.lowerBound, $0)))) }), format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder).frame(width: 100)
            Spacer()
        }
    }
    private func choice(_ title: String, _ root: Binding<SettingsValue>, _ key: String, _ options: [String]) -> some View {
        HStack {
            Text(title).frame(width: 180, alignment: .leading)
            Picker(title, selection: text(root, key)) {
                ForEach(Array(Set(options + [root.wrappedValue[key].text])).sorted(), id: \.self) { option in Text(option.isEmpty ? "默认" : option).tag(option) }
            }.labelsHidden().frame(maxWidth: .infinity)
        }
    }
    private func multiline(_ title: String, _ root: Binding<SettingsValue>, _ key: String, array: Bool = false) -> some View {
        let binding = value(root, key)
        let content = Binding<String>(get: { array ? binding.wrappedValue.items.map(\.text).joined(separator: "\n") : binding.wrappedValue.text }, set: {
            binding.wrappedValue = array ? .array($0.components(separatedBy: .newlines).filter { !$0.isEmpty }.map(SettingsValue.string)) : .string($0)
        })
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            TextEditor(text: content).font(AppFont.caption).scrollIndicators(.never).frame(height: 80).border(Color.secondary.opacity(0.3))
        }
    }
    private var parameters: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("参数分类", selection: $parameterGroup) { ForEach(groups, id: \.self) { Text($0) } }.pickerStyle(.segmented)
            if parameterGroup == groups[0] {
                let inbound = value($settings, "inbound")
                number("本地代理端口", inbound, "localPort", range: 1024...65533).disabled(model.proxyRunning)
                if model.proxyRunning { Text("关闭代理后可修改监听端口。").font(AppFont.caption).foregroundStyle(.secondary) }
                toggle("启用 UDP", inbound, "udpEnabled")
                toggle("启用附加监听端口", inbound, "secondLocalPortEnabled")
                toggle("允许局域网连接", inbound, "allowLANConn")
                toggle("局域网使用独立端口", inbound, "newPort4LAN").disabled(!inbound.wrappedValue["allowLANConn"].flag)
                let lanAuth = inbound.wrappedValue["allowLANConn"].flag && inbound.wrappedValue["newPort4LAN"].flag
                field("局域网用户名", inbound, "user").disabled(!lanAuth)
                HStack { Text("局域网密码").frame(width: 180, alignment: .leading); SecureField("", text: text(inbound, "pass")).textFieldStyle(.roundedBorder) }.disabled(!lanAuth)
                Text("用户名与密码仅用于独立局域网端口，需同时填写。").font(AppFont.caption).foregroundStyle(.secondary)
                Divider()
                toggle("启用流量嗅探", inbound, "sniffingEnabled")
                toggle("本地代理嗅探仅用于路由", inbound, "routeOnly").disabled(!inbound.wrappedValue["sniffingEnabled"].flag)
                HStack {
                    Text("嗅探协议").frame(width: 180, alignment: .leading)
                    ForEach(["http", "tls", "quic"], id: \.self) { protocolName in
                        Toggle(protocolName, isOn: Binding(get: { inbound.wrappedValue["destOverride"].items.contains(.string(protocolName)) }, set: { on in
                            var names = inbound.wrappedValue["destOverride"].items.filter { $0 != .string(protocolName) }
                            if on { names.append(.string(protocolName)) }; inbound.wrappedValue["destOverride"] = .array(names)
                        }))
                    }
                }
                Text("原生 TUN 共用嗅探协议，但固定仅用于路由；虚拟网卡、路由和 DNS 恢复由后台管理。").font(AppFont.caption).foregroundStyle(.secondary)
            } else if parameterGroup == groups[1] {
                let core = value($settings, "core")
                choice("全局默认域名策略", $settings, "domainStrategy", ["AsIs", "IPIfNonMatch", "IPOnDemand"])
                Text("路由方案未指定域名策略时使用此值；方案指定的策略优先生效。").font(AppFont.caption).foregroundStyle(.secondary)
                toggle("记录内核日志", core, "logEnabled")
                choice("日志等级", core, "loglevel", ["debug", "info", "warning", "error", "none"]).disabled(!core.wrappedValue["logEnabled"].flag)
                field("默认 TLS 指纹", core, "defFingerprint")
                field("默认 User-Agent", core, "defUserAgent")
                field("出口源地址", core, "sendThrough")
                field("出口网卡（空为自动）", core, "bindInterface")
                number("Mux 并发数", core, "mux4RayConcurrency", range: 0...1024)
                number("XUDP 并发数", core, "mux4RayXudpConcurrency", range: 0...1024)
                choice("XUDP UDP/443", core, "mux4RayXudpProxyUDP443", ["reject", "skip"])
                toggle("启用 TLS 分片", core, "enableFragment")
                toggle("对最终出口分片", core, "enableFinalFragment")
                let fragmentEnabled = core.wrappedValue["enableFragment"].flag || core.wrappedValue["enableFinalFragment"].flag
                field("分片数据包", core, "fragmentPackets").disabled(!fragmentEnabled)
                multiline("分片长度（每行一个范围）", core, "fragmentLengths", array: true).disabled(!fragmentEnabled)
                multiline("分片间隔（每行一个范围）", core, "fragmentDelays", array: true).disabled(!fragmentEnabled)
                field("最大分片次数", core, "fragmentMaxSplit").disabled(!fragmentEnabled)
            } else if parameterGroup == groups[2] {
                let app = value($settings, "application")
                let speed = value($settings, "speedTest")
                toggle("保存节点累计流量", app, "enableStatistics")
                toggle("采集实时流量", app, "displayRealTimeSpeed")
                Text("任一开启即采集流量；累计统计与实时显示用途不同。").font(AppFont.caption).foregroundStyle(.secondary)
                number("Geo 自动更新（小时）", app, "geoAutoUpdateInterval", range: 0...720)
                choice("根证书来源", app, "rootCertProvider", settings["options"]["rootCertProviders"].items.map(\.text))
                field("Geo 文件来源", app, "geoSourceUrl")
                field("路由规则模板来源", app, "routeRulesTemplateSourceUrl")
                number("测速超时（秒）", speed, "speedTestTimeout", range: 1...300)
                number("测速并发数", speed, "mixedConcurrencyCount", range: 1...100)
                field("测速下载地址", speed, "speedTestUrl")
                field("延迟测试地址", speed, "speedPingTestUrl")
            } else {
                HStack(spacing: 8) {
                    Text("MTU").frame(width: 48, alignment: .leading)
                    let presets = [1280, 1408, 1500, 4064, 9000, 65535]
                    ForEach(presets, id: \.self) { mtu in
                        Button(String(mtu)) { tunSettings["mtu"] = .number(Double(mtu)); dirty = true }
                            .foregroundStyle(tunSettings["mtu"].text == String(mtu) ? Color.accentColor : Color.primary)
                            .buttonStyle(HoverButtonStyle())
                            .accessibilityAddTraits(tunSettings["mtu"].text == String(mtu) ? .isSelected : [])
                    }
                    Text("自定义").foregroundStyle(.secondary)
                    TextField("1280–65535", value: Binding<Int>(get: { Int(tunSettings["mtu"].text) ?? 1500 },
                        set: { tunSettings["mtu"] = .number(Double($0)); dirty = true }), format: .number.grouping(.never))
                        .textFieldStyle(.roundedBorder).frame(width: 80)
                    Spacer(minLength: 0)
                }
                toggle("为虚拟网卡配置 IPv6", $tunSettings, "enableIPv6Address")
                multiline("排除接管的网段（CIDR，每行一个）", $tunSettings, "routeExcludeAddress", array: true)
                Text("虚拟网卡名称和 DNS 网关自动分配。排除的网段通过原有网络连接访问；关闭 TUN 后自动恢复网络。").font(AppFont.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var routing: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("方案", selection: Binding(get: { routeID }, set: { id in
                    guard let item = routes.first(where: { $0["id"].text == id }) else { return }
                    action { try await loadRoute(item); result = "" }
                })) {
                    if routeID.isEmpty { Text("新方案").tag("") }
                    ForEach(routes.indices, id: \.self) { i in Text(routes[i]["remarks"].text).tag(routes[i]["id"].text) }
                }.disabled(dirty)
                Button("新增") { newRoute() }.disabled(dirty)
                Button("复制") { routeID = ""; route["remarks"] = .string(route["remarks"].text + " 副本"); dirty = true }.disabled(dirty)
                Button("删除") { deleteConfirmation = true }.disabled(routeID.isEmpty || dirty)
                Button(route["isActive"].flag ? "当前方案" : "设为当前") { action {
                    try await model.settingsWrite("/api/settings/routing-profiles/\(routeID)/activate", method: "POST")
                    try await reloadRoutes()
                } }.disabled(routeID.isEmpty || dirty || route["isActive"].flag)
            }
            field("方案名称", $route, "remarks")
            choice("方案域名策略（默认继承）", $route, "domainStrategy", ["", "AsIs", "IPIfNonMatch", "IPOnDemand"])
            HStack {
                Text("规则按从上到下顺序匹配").font(AppFont.caption).foregroundStyle(.secondary)
                Spacer()
                Button("添加规则") {
                    rules.append(.object(["id": .string(UUID().uuidString), "remarks": .string("新规则"), "enabled": .bool(true), "outboundTag": .string("proxy"), "type": .string("field")]))
                    ruleIndex = rules.count - 1; dirty = true
                }
            }
            if rules.indices.contains(ruleIndex) {
                Picker("编辑规则", selection: $ruleIndex) {
                    ForEach(rules.indices, id: \.self) { i in Text("\(i + 1). " + (rules[i]["remarks"].text.isEmpty ? rules[i]["outboundTag"].text : rules[i]["remarks"].text)).tag(i) }
                }
                let rule = Binding<SettingsValue>(get: { rules.indices.contains(ruleIndex) ? rules[ruleIndex] : .null }, set: { if rules.indices.contains(ruleIndex) { rules[ruleIndex] = $0; dirty = true } })
                HStack {
                    toggle("启用", rule, "enabled"); Spacer()
                    Button("上移") { rules.swapAt(ruleIndex, ruleIndex - 1); ruleIndex -= 1; dirty = true }.disabled(ruleIndex == 0)
                    Button("下移") { rules.swapAt(ruleIndex, ruleIndex + 1); ruleIndex += 1; dirty = true }.disabled(ruleIndex == rules.count - 1)
                    Button("删除规则") { rules.remove(at: ruleIndex); ruleIndex = max(0, min(ruleIndex, rules.count - 1)); dirty = true }
                }
                field("备注", rule, "remarks")
                choice("出口", rule, "outboundTag", ["proxy", "direct", "block"])
                multiline("域名（每行一个，支持 domain:、full:、geosite:）", rule, "domain", array: true)
                multiline("IP / CIDR / geoip（每行一个）", rule, "ip", array: true)
                field("目标端口（例如 80,443）", rule, "port")
                choice("网络", rule, "network", ["", "tcp", "udp", "tcp,udp"])
                multiline("协议（http、tls、quic，每行一个）", rule, "protocol", array: true)
                multiline("入站标签（留空匹配全部；原生 TUN 为 tun）", rule, "inboundTag", array: true)
            }
        }
    }
    private var dnsSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("常规 DNS 参数").font(AppFont.title)
            Text("关闭自定义 DNS 后生效；保存常规参数不会切换当前 DNS 模式。").font(AppFont.caption).foregroundStyle(.secondary)
            if dns["enabled"].flag { Text("当前启用了自定义 DNS；关闭下方自定义 DNS 后，常规参数才会生效。").foregroundStyle(.orange).font(AppFont.caption) }
            field("直连 DNS", $simpleDNS, "directDNS")
            field("远程 DNS", $simpleDNS, "remoteDNS")
            field("引导 DNS（纯 IP）", $simpleDNS, "bootstrapDNS")
            ForEach([("直连解析策略", "strategy4Freedom"), ("代理解析策略", "strategy4Proxy"), ("代理拨号解析策略", "strategy4ProxyDial")], id: \.1) { label, key in
                choice(label, $simpleDNS, key, ["", "AsIs", "UseIP", "UseIPv4v6", "UseIPv6v4", "UseIPv4", "UseIPv6"])
            }
            toggle("读取系统 hosts", $simpleDNS, "useSystemHosts")
            toggle("添加常用 hosts", $simpleDNS, "addCommonHosts")
            toggle("阻止 AAAA 查询", $simpleDNS, "blockAAAAQuery")
            toggle("启用 FakeDNS", $simpleDNS, "fakeIP")
            toggle("全局 FakeDNS", $simpleDNS, "globalFakeIp").disabled(!simpleDNS["fakeIP"].flag)
            field("FakeDNS 地址范围", $simpleDNS, "fakeIPRange").disabled(!simpleDNS["fakeIP"].flag)
            toggle("并行查询", $simpleDNS, "parallelQuery")
            toggle("允许使用过期缓存", $simpleDNS, "serveStale")
            field("直连 DNS 预期 IP", $simpleDNS, "directExpectedIPs")
            multiline("自定义 hosts（沿用 v2rayN 格式）", $simpleDNS, "hosts")
            Button("保存常规 DNS") { action { try await model.settingsWrite("/api/settings/dns/simple", body: simpleDNS); savedSimpleDNS = simpleDNS } }
            Divider()
            Text("Xray 自定义 DNS").font(AppFont.title)
            toggle("启用自定义 DNS", $dns, "enabled")
            toggle("使用系统 hosts", $dns, "useSystemHosts")
            choice("直连域名解析策略", $dns, "domainStrategy4Freedom", ["", "AsIs", "UseIP", "UseIPv4v6", "UseIPv6v4", "UseIPv4", "UseIPv6"])
            field("域名 DNS 地址", $dns, "domainDNSAddress")
            multiline("系统代理 DNS（Xray DNS JSON 或 DNS 地址）", $dns, "normalDNS")
            multiline("原生 TUN DNS（Xray DNS JSON 或 DNS 地址）", $dns, "tunDNS")
            Text("TUN 开启时系统 DNS 临时指向虚拟网卡，由 Xray 按以上规则解析；关闭后恢复。这里无需填写虚拟网卡网关。").font(AppFont.caption).foregroundStyle(.secondary)
            Button("保存自定义 DNS") { action { try await model.settingsWrite("/api/settings/dns/profiles/Xray", body: dns); savedCustomDNS = dns } }
        }
    }
}
