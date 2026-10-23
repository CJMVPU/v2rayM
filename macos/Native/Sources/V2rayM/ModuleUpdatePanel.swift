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
                    if let progress, progress.isComplete && !progress.success && !progress.awaitingCompatibilityValidation, let detail = progress.detail {
                        Text(detail).font(AppFont.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
            }
            if let error = model.moduleUpdateError {
                Text(error).font(AppFont.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            Text("检查最新预发布版；修复版遇同版本会跳过，新版本待兼容验证。允许更新时，失败自动恢复旧版。")
                .font(AppFont.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 6)
    }
}
