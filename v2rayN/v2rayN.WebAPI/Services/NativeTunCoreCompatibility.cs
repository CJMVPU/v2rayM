using ServiceLib.Models.Dto;

namespace v2rayN.WebAPI.Services;

internal static class NativeTunCoreCompatibility
{
    internal const string RepairedCurrentMessage = "已安装同版本修复版，无需更新";
    // All newly discovered native Xray builds require explicit compatibility
    // validation. Checking releases never grants permission to replace a core.
    internal static bool? ApplyUpdatePolicy(XrayBuildIdentity? installed, UpdateResult remote)
    {
        if (remote.Version is null) return null;
        if (!SemanticVersion.TryParse(remote.ReleaseTag ?? remote.Version.ToString(), out var candidate) || candidate is null)
        {
            remote.Decision = UpdateCheckDecision.Failed; remote.Success = false; remote.Url = null;
            remote.Msg = "The upstream release version is invalid.";
            return false;
        }
        var repaired = installed?.RepairId is "darwin-bind1" or "darwin-bind2";
        if (installed is not null && SemanticVersion.TryParse(installed.UpstreamVersion, out var current) && current is not null)
        {
            if (candidate <= current)
            {
                if (!repaired) return null;
                remote.Decision = UpdateCheckDecision.Current;
                remote.Success = false;
                remote.Url = null;
                remote.Msg = candidate.Equals(current) ? RepairedCurrentMessage : "已安装较新修复版，无需更新";
                return true;
            }
        }
        remote.Success = false;
        remote.Url = null;
        remote.AwaitingCompatibilityValidation = true;
        remote.Msg = $"发现上游新版本 {remote.VersionLabel}，等待验证后再替换内核；尚未通过原生 TUN 兼容验证，当前内核保持不变。";
        return false;
    }
    // Known upstream regression. Keep other versions eligible for normal verification;
    // do not accept an unverified binary merely because it advertises the marker.
    internal static bool HasKnownDarwinBindingBug(string version) =>
        version.StartsWith("Xray 26.10.21 ", StringComparison.Ordinal)
        && InstalledXrayVersion.ParseRepairId(version) is null;
}
