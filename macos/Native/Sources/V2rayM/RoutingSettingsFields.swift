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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("方案", selection: Binding(get: { routeID }, set: { id in
                    guard let item = routes.first(where: { $0["id"].text == id }) else { return }
                    select(item)
                })) {
                    if routeID.isEmpty { Text("新方案").tag("") }
                    ForEach(routes.indices, id: \.self) { i in Text(routes[i]["remarks"].text).tag(routes[i]["id"].text) }
                }.disabled(dirty)
                Button("新增") { create() }.disabled(dirty)
                Button("复制") { routeID = ""; route["remarks"] = .string(route["remarks"].text + " 副本"); dirty = true }.disabled(dirty)
                Button("删除") { delete() }.disabled(routeID.isEmpty || dirty)
                Button(route["isActive"].flag ? "当前方案" : "设为当前") { activate() }.disabled(routeID.isEmpty || dirty || route["isActive"].flag)
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
}
