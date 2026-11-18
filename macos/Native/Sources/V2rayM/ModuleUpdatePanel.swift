import SwiftUI
import V2rayMKit

struct ModuleUpdatePanel: View {
    @EnvironmentObject var model: AppModel
    var body: some View { ModuleUpdateContent(observation: model.moduleObservation) }
}

@MainActor final class ModuleObservation: ObservableObject {
    @Published var progress: [ModuleUpdateProgress] = []
}

private struct ModuleUpdateContent: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var observation: ModuleObservation
    @State private var showingError = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.moduleUpdateError ?? "Xray 内核与分流规则数据独立维护")
                    .font(AppFont.caption).foregroundStyle(model.moduleUpdateError == nil ? Color.secondary : .orange)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    .help(model.moduleUpdateError ?? "")
                Button("详情") { showingError = true }
                    .environment(\.realityContentVisible, model.moduleUpdateError != nil)
                    .disabled(model.moduleUpdateError == nil)
                    .opacity(model.moduleUpdateError == nil ? 0 : 1)
                    .accessibilityHidden(model.moduleUpdateError == nil)
                    .popover(isPresented: $showingError) { UpdateDetails(text: model.moduleUpdateError ?? "") }
                Button("更新全部模块") { model.updateModules(.all) }
                    .disabled(!model.ready || model.busy || model.moduleUpdateActive)
            }.frame(height: 24)
            ForEach(model.moduleTargets, id: \.self) { id in
                ModuleUpdateRow(id: id, progress: observation.progress.first(where: { $0.coreType == id }),
                    queued: model.moduleUpdateActive && model.moduleScope?.targets.contains(id) == true,
                    disabled: !model.ready || model.busy || model.moduleUpdateActive) {
                        model.updateModules(id == "GeoFiles" ? .geo : .xray)
                    }
            }
        }
    }
}

/// Every update phase occupies the same row and the same columns. Only the
/// reserved progress slot changes its drawing, never the surrounding layout.
struct ModuleUpdateRow: View {
    let id: String
    let progress: ModuleUpdateProgress?
    let queued: Bool
    let disabled: Bool
    let update: () -> Void
    @State private var showingDetails = false
    private var active: Bool { progress.map { !$0.isComplete } ?? false }
    private var detail: String? { progress?.detail.flatMap { $0.isEmpty ? nil : $0 } }
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Label(id == "GeoFiles" ? "分流规则数据" : "Xray 内核", systemImage: id == "GeoFiles" ? "globe" : "shippingbox")
                    .font(AppFont.body).frame(width: 132, alignment: .leading)
                Text(progress?.phaseLabel ?? (queued ? "等待更新" : "尚未检查"))
                    .foregroundStyle(progress?.isComplete == true && progress?.success == false ? .orange : .secondary)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .trailing)
                    .help(detail ?? progress?.phaseLabel ?? "")
                Text(progress?.version ?? "").lineLimit(1).truncationMode(.middle)
                    .frame(width: 84, alignment: .trailing).help(progress?.version ?? "")
                Text(active && progress?.phase == "downloading" ? progress?.downloadFraction.map { "\(Int($0 * 100))%" } ?? "" : "")
                    .monospacedDigit().frame(width: 38, alignment: .trailing)
                Button("详情") { showingDetails = true }.frame(width: 36)
                    .environment(\.realityContentVisible, detail != nil)
                    .disabled(detail == nil).opacity(detail == nil ? 0 : 1).accessibilityHidden(detail == nil)
                    .popover(isPresented: $showingDetails) { UpdateDetails(text: detail ?? "") }
                Button(id == "GeoFiles" ? "更新数据" : "检查版本", action: update)
                    .disabled(disabled).frame(width: 76, alignment: .trailing)
            }.font(AppFont.caption).frame(height: 24)
            Color.clear.frame(height: 6).overlay {
                if active {
                    if let fraction = progress?.downloadFraction, progress?.phase == "downloading" {
                        ProgressView(value: fraction).progressViewStyle(.linear)
                    } else { ProgressView().progressViewStyle(.linear) }
                } else {
                    ProgressView(value: progress?.success == true ? 1 : 0).progressViewStyle(.linear)
                }
            }.accessibilityLabel("更新进度")
        }.padding(10)
            .realitySurface(.init(shape: .panel(8), depth: 3, level: 14))
    }
}

private struct UpdateDetails: View {
    let text: String
    var body: some View {
        ScrollView {
            Text(text).font(AppFont.body).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(14)
        }.frame(width: 390, height: 180)
    }
}
