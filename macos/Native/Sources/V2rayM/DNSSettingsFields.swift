import SwiftUI
import V2rayMKit

struct DNSSettingsFields: SettingsFields {
    @Binding var simpleDNS: SettingsValue
    @Binding var dns: SettingsValue
    @Binding var dirty: Bool
    let saveSimple: () -> Void
    let saveCustom: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsFormSection(title: "常规 DNS", subtitle: "关闭自定义 DNS 后生效；保存常规参数不会切换当前 DNS 模式。") {
                if dns["enabled"].flag { Text("当前启用了自定义 DNS；关闭下方自定义 DNS 后，常规参数才会生效。").foregroundStyle(.orange).font(AppFont.caption) }
                field("直连 DNS", $simpleDNS, "directDNS")
                field("远程 DNS", $simpleDNS, "remoteDNS")
                field("引导 DNS（纯 IP）", $simpleDNS, "bootstrapDNS")
                ForEach([("直连解析策略", "strategy4Freedom"), ("代理解析策略", "strategy4Proxy"), ("代理拨号解析策略", "strategy4ProxyDial")], id: \.1) { label, key in
                    choice(label, $simpleDNS, key, ["", "AsIs", "UseIP", "UseIPv4v6", "UseIPv6v4", "UseIPv4", "UseIPv6"])
                }
                toggle("读取系统域名映射", $simpleDNS, "useSystemHosts")
                toggle("添加常用域名映射", $simpleDNS, "addCommonHosts")
                toggle("阻止 AAAA 查询", $simpleDNS, "blockAAAAQuery")
                toggle("启用虚拟 DNS（FakeDNS）", $simpleDNS, "fakeIP")
                toggle("全局使用虚拟 DNS", $simpleDNS, "globalFakeIp").disabled(!simpleDNS["fakeIP"].flag)
                field("虚拟 DNS 地址范围", $simpleDNS, "fakeIPRange").disabled(!simpleDNS["fakeIP"].flag)
                toggle("并行查询", $simpleDNS, "parallelQuery")
                toggle("允许使用过期缓存", $simpleDNS, "serveStale")
                field("直连 DNS 预期 IP", $simpleDNS, "directExpectedIPs")
                multiline("自定义域名映射（hosts 格式）", $simpleDNS, "hosts")
                HStack { Spacer(); Button("保存常规 DNS") { saveSimple() } }
            }
            SettingsFormSection(title: "自定义 DNS", subtitle: "分别管理系统代理和原生 TUN 的解析规则。") {
                toggle("启用自定义 DNS", $dns, "enabled")
                toggle("读取系统域名映射", $dns, "useSystemHosts")
                choice("直连域名解析策略", $dns, "domainStrategy4Freedom", ["", "AsIs", "UseIP", "UseIPv4v6", "UseIPv6v4", "UseIPv4", "UseIPv6"])
                field("域名 DNS 地址", $dns, "domainDNSAddress")
                multiline("系统代理 DNS（Xray DNS JSON 或 DNS 地址）", $dns, "normalDNS")
                multiline("原生 TUN DNS（Xray DNS JSON 或 DNS 地址）", $dns, "tunDNS")
                Text("TUN 开启时系统 DNS 临时指向虚拟网卡，由 Xray 按以上规则解析；关闭后恢复。这里无需填写虚拟网卡网关。").font(AppFont.caption).foregroundStyle(.secondary)
                HStack { Spacer(); Button("保存自定义 DNS") { saveCustom() } }
            }
        }
    }
}
