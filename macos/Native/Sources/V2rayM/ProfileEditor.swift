import SwiftUI
import V2rayMKit

struct ProfileEditor: View {
    let profile: Profile
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var value = SettingsValue.object([:])
    @State private var original = SettingsValue.object([:])
    @State private var loaded = false
    @State private var saving = false
    @State private var result = ""
    @State private var failed = false
    @State private var discard = false
    @State private var section = "基本信息"
    private var dirty: Bool { loaded && value != original }
    private var path: String { "/api/profiles/\(profile.id)" }
    private var simple: Bool { !["custom", "outbound", "policygroup", "proxychain"].contains(value["configType"].text.lowercased()) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("配置节点").font(AppFont.title)
                Spacer()
                Button("关闭") { if dirty { discard = true } else { dismiss() } }.disabled(saving)
            }
            Divider()
            if loaded {
                if simple {
                    Picker("配置分类", selection: $section) {
                        ForEach(["基本信息", "传输与 TLS", "扩展配置"], id: \.self) { Text($0) }
                    }.pickerStyle(.segmented)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !simple {
                            Text("此节点使用完整配置或节点组。当前可修改名称；协议内容请通过重新导入更新。")
                            field("节点名称", "remarks")
                        } else if section == "基本信息" {
                            field("节点名称", "remarks")
                            LabeledContent("协议", value: profile.protocol.uppercased())
                            field("服务器", "address")
                            field("端口", "port")
                            field("用户名称", "username")
                            HStack { Text("密码 / UUID").frame(width: 110, alignment: .leading)
                                SecureField("密码 / UUID", text: binding("password")) }
                        } else if section == "传输与 TLS" {
                            field("传输方式", "network")
                            extraField("Host", key: "Host")
                            extraField("路径", key: "Path")
                            if value["network"].text == "xhttp" { extraField("XHTTP 模式", key: "XhttpMode") }
                            if value["network"].text == "grpc" {
                                extraField("服务名称", key: "GrpcServiceName")
                                extraField("Authority", key: "GrpcAuthority")
                            }
                            Text("传输方式例如 raw、xhttp、ws、grpc；更多参数在扩展配置中修改。")
                                .font(AppFont.caption).foregroundStyle(.secondary)
                            field("安全类型", "streamSecurity")
                            field("SNI", "sni")
                            field("ALPN", "alpn")
                            field("指纹", "fingerprint")
                            field("Reality 公钥", "publicKey")
                            field("Short ID", "shortId")
                            Toggle("允许不安全证书", isOn: Binding(get: { value["allowInsecure"].text == "true" }, set: { value["allowInsecure"] = .string($0 ? "true" : "false") }))
                        } else {
                            Text("协议扩展（JSON）").foregroundStyle(.secondary)
                            TextEditor(text: binding("protoExtra")).frame(height: 115)
                            Text("传输扩展（JSON，包括 XHTTP 模式、路径、Host 和 extra）").foregroundStyle(.secondary)
                            TextEditor(text: binding("transportExtra")).frame(height: 145)
                        }
                    }.textFieldStyle(.roundedBorder).padding(2)
                }.scrollIndicators(.hidden).disabled(saving)
            } else {
                Spacer()
                if failed { Button("重新加载") { Task { await load() } } }
                else { ProgressView() }
            }
            Spacer(minLength: 0)
            Divider()
            HStack {
                Text(result).font(AppFont.caption).foregroundStyle(failed ? Color.orange : Color.secondary)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if saving { ProgressView().controlSize(.small) }
                Button("保存节点") { Task { await save() } }
                    .disabled(!loaded || saving || model.busy || model.moduleUpdateActive || !dirty)
            }.frame(height: 32)
        }.padding(16).frame(width: 740, height: 500).font(AppFont.body)
            .buttonStyle(HoverButtonStyle())
            .interactiveDismissDisabled(dirty || saving)
            .task { await load() }
            .confirmationDialog("放弃未保存的修改？", isPresented: $discard) {
                Button("放弃修改", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) {}
            }
    }
    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { value[key].text }, set: { value[key] = .string($0) })
    }
    private func extraField(_ label: String, key: String) -> some View {
        HStack {
            Text(label).frame(width: 110, alignment: .leading)
            TextField(label, text: Binding(get: {
                let extra = try? SettingsValue.parse(value["transportExtra"].text)
                return extra?[key].text ?? ""
            }, set: { text in
                do {
                    var extra = value["transportExtra"].text.isEmpty ? SettingsValue.object([:]) : try SettingsValue.parse(value["transportExtra"].text)
                    guard case .object = extra else { throw ProfileEditError.invalidExtra }
                    extra[key] = .string(text)
                    value["transportExtra"] = .string(try extra.json())
                } catch { result = "请先在扩展配置中修正传输 JSON。"; failed = true }
            }))
        }
    }
    private func field(_ label: String, _ key: String) -> some View {
        HStack { Text(label).frame(width: 110, alignment: .leading); TextField(label, text: binding(key)) }
    }
    @MainActor private func load() async {
        failed = false; result = ""
        do { value = try await model.settingsRead(path); original = value; loaded = true }
        catch { failed = true; result = error.localizedDescription }
    }
    @MainActor private func save() async {
        saving = true; failed = false
        defer { saving = false }
        do {
            let input = simple ? try ProfileDocument(value).validated() : value
            try await model.settingsWrite(path, body: input)
            value = try await model.settingsRead(path); original = value
            result = "节点已保存；正在使用此节点时会自动应用。"
        } catch { failed = true; result = error.localizedDescription }
    }
}
