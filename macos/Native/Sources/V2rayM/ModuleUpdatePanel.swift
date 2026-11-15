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
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Xray 与 Geo 数据独立维护").font(AppFont.caption).foregroundStyle(.secondary)
                Spacer()
                Button(model.moduleUpdateActive ? "处理中…" : "更新全部模块") { model.updateModules(.all) }
                    .disabled(!model.ready || model.busy || model.moduleUpdateActive)
            }
            ForEach(model.moduleTargets, id: \.self) { id in
                let progress = observation.progress.first(where: { $0.coreType == id })
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label(ModuleUpdateNames.label(id), systemImage: id == "GeoFiles" ? "globe" : "shippingbox")
                            .font(AppFont.body).frame(width: 168, alignment: .leading)
                        Spacer(minLength: 12)
                        Text(progress?.phaseLabel ?? (model.moduleUpdateActive && model.moduleScope?.targets.contains(id) == true ? "等待更新" : "尚未检查"))
                            .foregroundStyle(progress?.isComplete == true && progress?.success == false ? .orange : .secondary)
                            .help(progress?.detail ?? "")
                        if let version = progress?.version { Text(version).lineLimit(1).frame(maxWidth: 200, alignment: .trailing) }
                        if let fraction = progress?.downloadFraction, progress?.phase == "downloading" {
                            Text("\(Int(fraction * 100))%").monospacedDigit()
                        }
                        Button(id == "GeoFiles" ? "更新数据" : "检查版本") {
                            model.updateModules(id == "GeoFiles" ? .geo : .xray)
                        }.disabled(!model.ready || model.busy || model.moduleUpdateActive)
                            .frame(width: 76, alignment: .trailing)
                    }.font(AppFont.caption)
                    if progress != nil {
                    if let progress, !progress.isComplete && progress.phase != "downloading" {
                        ProgressView().progressViewStyle(.linear)
                    } else if let progress, progress.phase == "downloading", progress.downloadFraction == nil {
                        ProgressView().progressViewStyle(.linear)
                    } else {
                        ProgressView(value: progress?.isComplete == true && progress?.success == true ? 1 : progress?.downloadFraction ?? 0)
                            .tint(progress?.isComplete == true && progress?.success == false ? .orange : .accentColor)
                    }
                    }
                    if let progress, progress.isComplete && !progress.success, let detail = progress.detail {
                        Text(detail).font(AppFont.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }.padding(10)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            }
            if let error = model.moduleUpdateError {
                Text(error).font(AppFont.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            Text("检查最新版本（含预发布版）；发现新版本后等待验证，不自动替换 Xray 内核。")
                .font(AppFont.caption).foregroundStyle(.secondary)
        }
    }
}
