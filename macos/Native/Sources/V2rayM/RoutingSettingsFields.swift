import SwiftUI
import V2rayMKit

struct RoutingSettingsFields: SettingsFields {
    let routes: [SettingsValue]
    @Binding var route: SettingsValue
    @Binding var rules: [SettingsValue]
    @Binding var routeID: String
    @Binding var ruleIndex: Int
    @Binding var dirty: Bool
    let select: (SettingsValue) -> Void
    let create: () -> Void
    let delete: () -> Void
    let activate: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsFormSection(title: "路由方案", subtitle: "保存修改后可切换或启用方案。") {
                SettingsFieldRow(title: "当前编辑方案") {
                    RealityChoice(title: "方案", selection: Binding(get: { routeID }, set: { id in
                        guard let item = routes.first(where: { $0["id"].text == id }) else { return }
                        select(item)
                    }), values: (routeID.isEmpty ? [""] : []) + routes.map { $0["id"].text }) { id in
                        routes.first { $0["id"].text == id }.map { settingsRouteLabel($0["remarks"].text) } ?? "新方案"
                    }.disabled(dirty)
                }
                HStack {
                    Spacer()
                    Button("新增") { create() }.disabled(dirty)
                    Button("复制") { routeID = ""; route["remarks"] = .string(route["remarks"].text + " 副本"); dirty = true }.disabled(dirty)
                    Button("删除") { delete() }.disabled(routeID.isEmpty || dirty)
                    Button(route["isActive"].flag ? "当前方案" : "设为当前") { activate() }.disabled(routeID.isEmpty || dirty || route["isActive"].flag)
                }
                field("方案名称", $route, "remarks")
                choice("方案域名策略（默认继承）", $route, "domainStrategy", ["", "AsIs", "IPIfNonMatch", "IPOnDemand"])
            }
            SettingsFormSection(title: "匹配规则", subtitle: "规则按从上到下的顺序匹配，调整顺序后需要保存。") {
                HStack {
                    Text("\(rules.count) 条规则").font(AppFont.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("添加规则") {
                        rules.append(.object(["id": .string(UUID().uuidString), "remarks": .string("新规则"), "enabled": .bool(true), "outboundTag": .string("proxy"), "type": .string("field")]))
                        ruleIndex = rules.count - 1; dirty = true
                    }
                }
                if rules.indices.contains(ruleIndex) {
                    SettingsFieldRow(title: "当前编辑规则") {
                        RealityChoice(title: "编辑规则", selection: $ruleIndex, values: Array(rules.indices)) { i in
                            guard rules.indices.contains(i) else { return "—" }
                            return "\(i+1). " + (rules[i]["remarks"].text.isEmpty ? settingsOptionLabel(rules[i]["outboundTag"].text) : rules[i]["remarks"].text)
                        }
                    }
                    let rule = Binding<SettingsValue>(get: { rules.indices.contains(ruleIndex) ? rules[ruleIndex] : .null }, set: { if rules.indices.contains(ruleIndex) { rules[ruleIndex] = $0; dirty = true } })
                    HStack {
                        Spacer()
                        Button("上移") { rules.swapAt(ruleIndex, ruleIndex - 1); ruleIndex -= 1; dirty = true }.disabled(ruleIndex == 0)
                        Button("下移") { rules.swapAt(ruleIndex, ruleIndex + 1); ruleIndex += 1; dirty = true }.disabled(ruleIndex == rules.count - 1)
                        Button("删除规则") { rules.remove(at: ruleIndex); ruleIndex = max(0, min(ruleIndex, rules.count - 1)); dirty = true }
                    }
                    toggle("启用规则", rule, "enabled")
                    field("备注", rule, "remarks")
                    choice("出口", rule, "outboundTag", ["proxy", "direct", "block"])
                    multiline("域名（每行一个，支持 domain:、full:、geosite:）", rule, "domain", array: true)
                    multiline("IP 与网段（每行一项，支持 geoip:）", rule, "ip", array: true)
                    field("目标端口（例如 80,443）", rule, "port")
                    choice("网络", rule, "network", ["", "tcp", "udp", "tcp,udp"])
                    multiline("协议（http、tls、quic，每行一个）", rule, "protocol", array: true)
                    multiline("入站标签（tun：原生 TUN；dns-module：DNS；留空匹配全部）", rule, "inboundTag", array: true)
                } else {
                    Text("还没有规则，点击“添加规则”开始配置。").font(AppFont.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
                }
            }
        }
    }
}
