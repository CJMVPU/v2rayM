import SwiftUI
import V2rayMKit

struct ImportPane: View {
    @EnvironmentObject private var model: AppModel
    let homeRequest: Int
    let goHome: () -> Void
    let close: () -> Void
    let save: (String) async throws -> Void
    @StateObject private var draft = ImportDraft()
    private func requestClose(home: Bool) {
        if draft.requestClose(home: home) { finishReturn() }
    }
    private func finishReturn() { (draft.returningHome ? goHome : close)() }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button { requestClose(home: false) } label: { RealityLabel(title: "返回", asset: .back) }.disabled(draft.saving)
                Text("导入节点").font(AppFont.title)
                Spacer()
            }
            Text("粘贴分享链接或兼容的配置内容，可一次导入多个节点。").foregroundStyle(DashboardTheme.muted)
            TextEditor(text: $draft.content).font(AppFont.body).scrollIndicators(.never).scrollContentBackground(.hidden)
                .padding(10).frame(maxHeight: .infinity)
                .modifier(RealityEditorSurface())
                .accessibilityLabel("节点分享链接或配置").disabled(draft.saving)
            HStack {
                Text(draft.error ?? (draft.saving ? "正在导入…" : ""))
                    .font(AppFont.caption).foregroundStyle(DashboardTheme.warning).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                InlineActivityIndicator(active: draft.saving)
                Button("取消") { requestClose(home: false) }.keyboardShortcut(.cancelAction).disabled(draft.saving)
                Button("导入") { Task { if await draft.submit(save) { close() } } }.keyboardShortcut(.defaultAction)
                    .disabled(draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || draft.saving || !model.ready || model.busy || model.moduleUpdateActive)
            }.frame(height: 32)
        }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity).font(AppFont.body)
            .onChange(of: homeRequest) { requestClose(home: true) }
            .confirmationDialog("放弃尚未导入的内容？", isPresented: $draft.discard) {
                Button("放弃内容", role: .destructive, action: finishReturn)
                Button("继续编辑", role: .cancel) {}
            }
    }
}

@MainActor final class ImportDraft: ObservableObject {
    @Published var content = ""
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    @Published var discard = false
    private(set) var returningHome = false

    func requestClose(home: Bool) -> Bool {
        guard !saving else { return false }
        returningHome = home
        discard = !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return !discard
    }
    func submit(_ save: (String) async throws -> Void) async -> Bool {
        guard !saving else { return false }
        saving = true; error = nil
        defer { saving = false }
        do { try await save(content); return true }
        catch { self.error = error.localizedDescription; return false }
    }
}
