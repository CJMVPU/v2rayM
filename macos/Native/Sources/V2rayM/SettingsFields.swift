import SwiftUI
import V2rayMKit

protocol SettingsFields: View { var dirty: Bool { get nonmutating set } }
extension SettingsFields {
    func value(_ root: Binding<SettingsValue>, _ key: String) -> Binding<SettingsValue> {
        Binding(get: { root.wrappedValue[key] }, set: { root.wrappedValue[key] = $0; dirty = true })
    }
    func text(_ root: Binding<SettingsValue>, _ key: String) -> Binding<String> {
        let binding = value(root, key)
        return Binding(get: { binding.wrappedValue.text }, set: { binding.wrappedValue = .string($0) })
    }
    func toggle(_ title: String, _ root: Binding<SettingsValue>, _ key: String) -> some View {
        let binding = value(root, key)
        return HStack {
            Text(title)
            Spacer(minLength: 12)
            Toggle(title, isOn: Binding(get: { binding.wrappedValue.flag }, set: { binding.wrappedValue = .bool($0) }))
                .labelsHidden().toggleStyle(RealityToggleStyle(showsLabel: false)).controlSize(.small)
        }.frame(minHeight: 24)
    }
    func field(_ title: String, _ root: Binding<SettingsValue>, _ key: String) -> some View {
        SettingsFieldRow(title: title) { TextField("", text: text(root, key)).textFieldStyle(RealityTextFieldStyle()).accessibilityLabel(title) }
    }
    func number(_ title: String, _ root: Binding<SettingsValue>, _ key: String, range: ClosedRange<Int>) -> some View {
        let binding = value(root, key)
        return SettingsFieldRow(title: title) {
            TextField("", value: Binding<Int>(get: { Int(binding.wrappedValue.text) ?? 0 }, set: { binding.wrappedValue = .number(Double(min(range.upperBound, max(range.lowerBound, $0)))) }), format: .number.grouping(.never))
                .textFieldStyle(RealityTextFieldStyle()).frame(width: 110).accessibilityLabel(title)
            Spacer()
        }
    }
    func choice(_ title: String, _ root: Binding<SettingsValue>, _ key: String, _ options: [String]) -> some View {
        SettingsFieldRow(title: title) {
            Picker(title, selection: text(root, key)) {
                ForEach(settingsOptions(options, current: root.wrappedValue[key].text), id: \.self) { option in
                    Text(settingsOptionLabel(option)).tag(option)
                }
            }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading).accessibilityLabel(title)
        }
    }
    func multiline(_ title: String, _ root: Binding<SettingsValue>, _ key: String, array: Bool = false) -> some View {
        let binding = value(root, key)
        let content = Binding<String>(get: { array ? binding.wrappedValue.items.map(\.text).joined(separator: "\n") : binding.wrappedValue.text }, set: {
            binding.wrappedValue = array ? .array($0.components(separatedBy: .newlines).filter { !$0.isEmpty }.map(SettingsValue.string)) : .string($0)
        })
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            TextEditor(text: content).font(AppFont.caption).scrollIndicators(.never)
                .scrollContentBackground(.hidden).padding(6).frame(height: 96)
                .realitySurface(.init(shape: .panel(6), color: NSColor(calibratedWhite: 0.13, alpha: 1), depth: 2, level: 18))
                .accessibilityLabel(title)
        }
    }
}

// Translate presentation only. Persisted Xray values and unknown upstream options
// retain their original spelling and remain selectable.
private func settingsOptions(_ options: [String], current: String) -> [String] {
    var seen = Set<String>()
    return (options + [current]).filter { seen.insert($0).inserted }
}

func settingsOptionLabel(_ option: String) -> String {
    ["": "默认", "AsIs": "保持域名", "IPIfNonMatch": "未匹配时解析 IP", "IPOnDemand": "按需解析 IP",
     "UseIP": "使用 IP", "UseIPv4v6": "优先 IPv4", "UseIPv6v4": "优先 IPv6",
     "UseIPv4": "仅 IPv4", "UseIPv6": "仅 IPv6", "debug": "调试", "info": "信息",
     "warning": "警告", "error": "错误", "none": "关闭", "reject": "拒绝", "skip": "跳过复用",
     "proxy": "代理", "direct": "直连", "block": "阻断", "tcp": "TCP", "udp": "UDP",
     "tcp,udp": "TCP 与 UDP", "system": "系统证书", "chrome": "Chrome 证书", "mozilla": "Mozilla 证书"][option] ?? option
}

func settingsRouteLabel(_ name: String) -> String {
    ["Whitelist": "白名单", "Blacklist": "黑名单", "Global": "全局代理"][name] ?? name
}
