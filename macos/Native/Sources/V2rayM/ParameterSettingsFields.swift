import SwiftUI
import V2rayMKit

struct ParameterSettingsFields: SettingsFields {
    @EnvironmentObject var model: AppModel
    @Binding var settings: SettingsValue
    @Binding var tunSettings: SettingsValue
    @Binding var dirty: Bool
    @State var parameterGroup = "监听与嗅探"
    private let groups = ["监听与嗅探", "Xray 参数", "应用与测速", "原生 TUN"]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RealitySegments(title: "参数分类", selection: $parameterGroup, options: groups)
            if parameterGroup == groups[0] {
                SettingsFormSection(title: "监听与嗅探", subtitle: "管理本地连接入口和流量识别。") {
                    let inbound = value($settings, "inbound")
                    let maximum = XrayInbound.maximumBasePort(secondLocal: inbound.wrappedValue["secondLocalPortEnabled"].flag,
                        separateLAN: inbound.wrappedValue["allowLANConn"].flag && inbound.wrappedValue["newPort4LAN"].flag)
                    number("本地代理端口", inbound, "localPort", range: 1024...maximum).disabled(model.proxyRunning)
                    Text("关闭代理后可修改监听端口。").font(AppFont.caption).foregroundStyle(DashboardTheme.muted)
                        .opacity(model.proxyRunning ? 1 : 0).accessibilityHidden(!model.proxyRunning)
                    toggle("启用 UDP", inbound, "udpEnabled")
                    toggle("启用附加监听端口", inbound, "secondLocalPortEnabled")
                    toggle("允许局域网连接", inbound, "allowLANConn")
                    toggle("局域网使用独立端口", inbound, "newPort4LAN").disabled(!inbound.wrappedValue["allowLANConn"].flag)
                    let lanAuth = inbound.wrappedValue["allowLANConn"].flag && inbound.wrappedValue["newPort4LAN"].flag
                    field("局域网用户名", inbound, "user").disabled(!lanAuth)
                    SettingsFieldRow(title: "局域网密码") { SecureField("", text: text(inbound, "pass")).textFieldStyle(RealityTextFieldStyle()).accessibilityLabel("局域网密码") }.disabled(!lanAuth)
                    Text("用户名与密码仅用于独立局域网端口，需同时填写。").font(AppFont.caption).foregroundStyle(DashboardTheme.muted)
                    Divider()
                    toggle("启用流量嗅探", inbound, "sniffingEnabled")
                    toggle("本地代理嗅探仅用于路由", inbound, "routeOnly").disabled(!inbound.wrappedValue["sniffingEnabled"].flag)
                    HStack {
                        Text("嗅探协议").frame(width: 180, alignment: .leading)
                        ForEach(["http", "tls", "quic"], id: \.self) { protocolName in
                            Toggle(protocolName.uppercased(), isOn: Binding(get: { inbound.wrappedValue["destOverride"].items.contains(.string(protocolName)) }, set: { on in
                                var names = inbound.wrappedValue["destOverride"].items.filter { $0 != .string(protocolName) }
                                if on { names.append(.string(protocolName)) }; inbound.wrappedValue["destOverride"] = .array(names)
                            })).toggleStyle(RealityToggleStyle())
                        }
                    }
                    Text("原生 TUN 共用嗅探协议，但固定仅用于路由；虚拟网卡、路由和 DNS 恢复由后台管理。").font(AppFont.caption).foregroundStyle(DashboardTheme.muted)
                }
            } else if parameterGroup == groups[1] {
                SettingsFormSection(title: "Xray 参数", subtitle: "日志、默认出口行为与连接复用。") {
                    let core = value($settings, "core")
                    choice("全局默认域名策略", $settings, "domainStrategy", ["AsIs", "IPIfNonMatch", "IPOnDemand"])
                    Text("路由方案未指定域名策略时使用此值；方案指定的策略优先生效。").font(AppFont.caption).foregroundStyle(DashboardTheme.muted)
                    toggle("记录内核日志", core, "logEnabled")
                    choice("日志等级", core, "loglevel", ["debug", "info", "warning", "error", "none"]).disabled(!core.wrappedValue["logEnabled"].flag)
                    field("默认 TLS 指纹", core, "defFingerprint")
                    field("默认用户代理标识", core, "defUserAgent")
                    field("出口源地址", core, "sendThrough")
                    field("出口网卡（空为自动）", core, "bindInterface")
                    number("连接复用并发数", core, "mux4RayConcurrency", range: 0...1024)
                    number("XUDP 并发数", core, "mux4RayXudpConcurrency", range: 0...1024)
                    choice("UDP 443 复用策略", core, "mux4RayXudpProxyUDP443", ["reject", "skip"])
                    toggle("启用 TLS 分片", core, "enableFragment")
                    toggle("对最终出口分片", core, "enableFinalFragment")
                    let fragmentEnabled = core.wrappedValue["enableFragment"].flag || core.wrappedValue["enableFinalFragment"].flag
                    field("分片数据包", core, "fragmentPackets").disabled(!fragmentEnabled)
                    multiline("分片长度（每行一个范围）", core, "fragmentLengths", array: true).disabled(!fragmentEnabled)
                    multiline("分片间隔（每行一个范围）", core, "fragmentDelays", array: true).disabled(!fragmentEnabled)
                    field("最大分片次数", core, "fragmentMaxSplit").disabled(!fragmentEnabled)
                }
            } else if parameterGroup == groups[2] {
                SettingsFormSection(title: "应用与测速", subtitle: "流量统计、数据更新与测速偏好。") {
                    let app = value($settings, "application")
                    let speed = value($settings, "speedTest")
                    toggle("保存节点累计流量", app, "enableStatistics")
                    toggle("采集实时流量", app, "displayRealTimeSpeed")
                    Text("任一开启即采集流量；累计统计与实时显示用途不同。").font(AppFont.caption).foregroundStyle(DashboardTheme.muted)
                    number("规则数据更新间隔（小时）", app, "geoAutoUpdateInterval", range: 0...720)
                    choice("根证书来源", app, "rootCertProvider", settings["options"]["rootCertProviders"].items.map(\.text))
                    field("规则数据来源", app, "geoSourceUrl")
                    field("路由规则模板来源", app, "routeRulesTemplateSourceUrl")
                    number("测速超时（秒）", speed, "speedTestTimeout", range: 1...300)
                    number("测速并发数", speed, "mixedConcurrencyCount", range: 1...100)
                    field("测速下载地址", speed, "speedTestUrl")
                    field("延迟测试地址", speed, "speedPingTestUrl")
                }
            } else {
                SettingsFormSection(title: "原生 TUN", subtitle: "仅使用 Xray 原生虚拟网卡。") {
                    SettingsFieldRow(title: "MTU 预设") {
                        ForEach([1280, 1408, 1500, 4064, 9000, 65535], id: \.self) { mtu in
                            Button(String(mtu)) { tunSettings["mtu"] = .number(Double(mtu)); dirty = true }
                                .foregroundStyle(tunSettings["mtu"].text == String(mtu) ? DashboardTheme.accent : DashboardTheme.text)
                                .accessibilityAddTraits(tunSettings["mtu"].text == String(mtu) ? .isSelected : [])
                        }
                        Spacer(minLength: 0)
                    }
                    SettingsFieldRow(title: "自定义 MTU") {
                        TextField("1280–65535", value: Binding<Int>(get: { Int(tunSettings["mtu"].text) ?? 1500 },
                            set: { tunSettings["mtu"] = .number(Double($0)); dirty = true }), format: .number.grouping(.never))
                            .textFieldStyle(RealityTextFieldStyle()).frame(width: 110).accessibilityLabel("自定义 MTU")
                        Text("有效范围 1280–65535").font(AppFont.caption).foregroundStyle(DashboardTheme.muted)
                        Spacer(minLength: 0)
                    }
                    toggle("为虚拟网卡配置 IPv6", $tunSettings, "enableIPv6Address")
                    multiline("排除接管的网段（CIDR，每行一个）", $tunSettings, "routeExcludeAddress", array: true)
                    Text("虚拟网卡名称和 DNS 网关自动分配。排除的网段通过原有网络连接访问；关闭 TUN 后自动恢复网络。").font(AppFont.caption).foregroundStyle(DashboardTheme.muted)
                }
            }
        }
    }
}
