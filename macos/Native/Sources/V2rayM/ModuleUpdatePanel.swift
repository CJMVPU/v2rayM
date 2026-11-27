import SwiftUI
import V2rayMKit

struct ModuleUpdatePanel: View {
    @EnvironmentObject var model: AppModel
    var body: some View { ModuleUpdateContent(observation: model.moduleObservation) }
}

@MainActor final class ModuleObservation: ObservableObject {
    @Published var progress: ModuleUpdateProgress?
}

private struct ModuleUpdateContent: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var observation: ModuleObservation
    @State private var showingError = false
    var body: some View {
        SettingsCard(title: "模块更新", symbol: .sync, headerAction: {
            HStack {
                if let error = model.moduleUpdateError {
                    Text(error).font(AppFont.caption).foregroundStyle(DashboardTheme.warning)
                        .lineLimit(1).help(error)
                    Button("详情") { showingError = true }
                        .popover(isPresented: $showingError) { UpdateDetails(text: error) }
                }
            }.frame(height: 24)
        }) {
            VStack(spacing: PageLayout.gap) {
                HStack {
                    RealityLabel(title: "Xray 内核", asset: .package)
                    Spacer()
                    Text(model.status?.installedXrayVersion ?? "—")
                    Text("随 App 更新").foregroundStyle(DashboardTheme.muted)
                }.font(AppFont.caption).padding(10).realityCard(radius: 6, depth: 3, level: 16)
                ModuleUpdateRow(progress: observation.progress,
                    queued: model.moduleUpdateActive,
                    disabled: !model.ready || model.busy || model.moduleUpdateActive,
                    update: model.updateGeoFiles)
            }
        }
    }
}

/// Every update phase occupies the same row and the same columns. Only the
/// reserved progress slot changes its drawing, never the surrounding layout.
struct ModuleUpdateRow: View {
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
                RealityLabel(title: "分流规则数据", asset: .globe)
                    .font(AppFont.body).frame(width: 132, alignment: .leading)
                Text(progress?.phaseLabel ?? (queued ? "等待更新" : "尚未检查"))
                    .foregroundStyle(progress?.isComplete == true && progress?.success == false ? DashboardTheme.warning : DashboardTheme.muted)
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .trailing)
                    .help(detail ?? progress?.phaseLabel ?? "")
                Text(progress?.version ?? "").lineLimit(1).truncationMode(.middle)
                    .frame(width: 84, alignment: .trailing).help(progress?.version ?? "")
                Text(active && progress?.phase == "downloading" && (progress?.totalBytes ?? 0) > 0 ? progress?.downloadFraction.map { "\(Int($0 * 100))%" } ?? "" : "")
                    .monospacedDigit().frame(width: 38, alignment: .trailing)
                Button("详情") { showingDetails = true }.frame(width: 36)
                    .disabled(detail == nil)
                    .help(detail == nil ? "当前没有可查看的更新详情" : "查看更新详情")
                    .popover(isPresented: $showingDetails) { UpdateDetails(text: detail ?? "") }
                Button("更新数据", action: update)
                    .disabled(disabled).frame(width: 76, alignment: .trailing)
            }.font(AppFont.caption).frame(height: 24)
            RealityProgressTrack(fraction: active
                ? (progress?.phase == "downloading" ? progress?.downloadFraction : nil)
                : (progress?.success == true ? 1 : 0))
        }.padding(10)
            .realityCard(radius: 6, depth: 3, level: 16)
    }
}

private struct UpdateDetails: View {
    let text: String
    var body: some View {
        RealityWindow {
            ScrollView(showsIndicators: false) {
                Text(text).font(AppFont.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14).background(SettingsWheelScroll())
            }.realityClipped().realityCard(radius: 8).padding(3)
        }.frame(width: 390, height: 180)
    }
}
