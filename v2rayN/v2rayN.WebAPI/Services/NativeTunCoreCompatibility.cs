using ServiceLib.Models.Dto;

namespace v2rayN.WebAPI.Services;

internal static class NativeTunCoreCompatibility
{
    internal const string RepairedCurrentMessage = "已安装同版本修复版，无需更新";
    // Null means normal official update policy applies. A local repair is retired
    // only after reviewing and regression-testing an upstream fix, not by version age.
    internal static bool? ApplyRepairUpdatePolicy(XrayBuildIdentity? installed, UpdateResult remote)
    {
        if (installed?.RepairId is not ("darwin-bind1" or "darwin-bind2") || remote.Version is null) return null;
        // Synchronizing the privileged store can rewrite Version to the installed
        // version. Compare the original release tag, when provided, instead.
        if (!SemanticVersion.TryParse(remote.ReleaseTag ?? remote.Version.ToString(), out var candidate) || candidate is null) return null;
        if (!SemanticVersion.TryParse(installed.UpstreamVersion, out var current) || current is null) return null;
        remote.Success = false;
        remote.Url = null; // No package download or live core replacement in either branch.
        if (candidate <= current)
        {
            remote.Msg = candidate.Equals(current) ? RepairedCurrentMessage : "已安装较新修复版，无需更新";
            return true;
        }
        remote.Msg = $"发现上游新版本 {candidate}，尚未通过原生 TUN 兼容验证，已保留当前修复版。";
        return false;
    }
    // Known upstream regression. Keep other versions eligible for normal verification;
    // do not accept an unverified binary merely because it advertises the marker.
    internal static bool HasKnownDarwinBindingBug(string version) =>
        version.StartsWith("Xray 26.10.21 ", StringComparison.Ordinal)
        && InstalledXrayVersion.ParseRepairId(version) is null;
}
