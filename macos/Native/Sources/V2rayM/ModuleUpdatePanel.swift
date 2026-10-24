import SwiftUI
import V2rayMKit

struct ModuleUpdatePanel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(ModuleUpdateScope.allCases) { scope in
                    if scope == .all { Spacer(minLength: 8) }
                    Button(model.moduleScope == scope && model.moduleUpdateActive ? "更新中…" : scope.buttonLabel) {
                        model.updateModules(scope)
                    }.disabled(!model.ready || model.busy || model.moduleUpdateActive)
                }
            }
            ForEach(model.moduleTargets, id: \.self) { id in
                let progress = model.moduleProgress.first(where: { $0.coreType == id })
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(ModuleUpdateNames.label(id))
                        Spacer()
                        Text(progress?.phaseLabel ?? (model.moduleUpdateActive && model.moduleScope?.targets.contains(id) == true ? "等待更新" : "尚未检查"))
                            .foregroundStyle(progress?.isComplete == true && progress?.success == false ? .orange : .secondary)
                            .help(progress?.detail ?? "")
                        if let version = progress?.version { Text(version).lineLimit(1).frame(maxWidth: 200, alignment: .trailing) }
                        if let fraction = progress?.downloadFraction, progress?.phase == "downloading" {
                            Text("\(Int(fraction * 100))%")
                        }
                    }.font(AppFont.caption)
                    if let progress, !progress.isComplete && progress.phase != "downloading" {
                        ProgressView().progressViewStyle(.linear)
                    } else if let progress, progress.phase == "downloading", progress.downloadFraction == nil {
                        ProgressView().progressViewStyle(.linear)
                    } else {
                        ProgressView(value: progress?.isComplete == true && progress?.success == true ? 1 : progress?.downloadFraction ?? 0)
                            .tint(progress?.isComplete == true && progress?.success == false ? .orange : .accentColor)
                    }
                    if let progress, progress.isComplete && !progress.success, let detail = progress.detail {
                        Text(detail).font(AppFont.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
            }
            if let error = model.moduleUpdateError {
                Text(error).font(AppFont.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            Text("检查最新版本（含预发布版）；发现新版本后等待验证，不自动替换 Xray 内核。")
                .font(AppFont.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 6)
    }
}
