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
        return Toggle(title, isOn: Binding(get: { binding.wrappedValue.flag }, set: { binding.wrappedValue = .bool($0) }))
    }
    func field(_ title: String, _ root: Binding<SettingsValue>, _ key: String) -> some View {
        HStack { Text(title).frame(width: 180, alignment: .leading); TextField("", text: text(root, key)).textFieldStyle(.roundedBorder) }
    }
    func number(_ title: String, _ root: Binding<SettingsValue>, _ key: String, range: ClosedRange<Int>) -> some View {
        let binding = value(root, key)
        return HStack {
            Text(title).frame(width: 180, alignment: .leading)
            TextField("", value: Binding<Int>(get: { Int(binding.wrappedValue.text) ?? 0 }, set: { binding.wrappedValue = .number(Double(min(range.upperBound, max(range.lowerBound, $0)))) }), format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder).frame(width: 100)
            Spacer()
        }
    }
    func choice(_ title: String, _ root: Binding<SettingsValue>, _ key: String, _ options: [String]) -> some View {
        HStack {
            Text(title).frame(width: 180, alignment: .leading)
            Picker(title, selection: text(root, key)) {
                ForEach(Array(Set(options + [root.wrappedValue[key].text])).sorted(), id: \.self) { option in Text(option.isEmpty ? "默认" : option).tag(option) }
            }.labelsHidden().frame(maxWidth: .infinity)
        }
    }
    func multiline(_ title: String, _ root: Binding<SettingsValue>, _ key: String, array: Bool = false) -> some View {
        let binding = value(root, key)
        let content = Binding<String>(get: { array ? binding.wrappedValue.items.map(\.text).joined(separator: "\n") : binding.wrappedValue.text }, set: {
            binding.wrappedValue = array ? .array($0.components(separatedBy: .newlines).filter { !$0.isEmpty }.map(SettingsValue.string)) : .string($0)
        })
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            TextEditor(text: content).font(AppFont.caption).scrollIndicators(.never).frame(height: 80).border(Color.secondary.opacity(0.3))
        }
    }
}
