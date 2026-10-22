using ServiceLib.Enums;
using ServiceLib.Handler.Builder;
using v2rayN.WebAPI.Contracts;

namespace v2rayN.WebAPI.MacOS;

internal static class MacTunLaunchPolicy
{
    internal static OperationView? Validate(CoreConfigContextBuilderAllResult built, bool isMacOS, bool helperReady)
    {
        var contexts = new[] { built.MainResult.Context, built.PreSocksResult?.Context }
            .Where(context => context?.IsTunEnabled == true).ToArray();
        if (contexts.Length == 0) return null;
        if (!isMacOS) return OperationView.Fail("tun_not_supported", ApiMessageKeys.CoreTunNotSupported);
        if (contexts.Any(context => context!.Node.ConfigType == EConfigType.Custom
            || context.RunCoreType != ECoreType.Xray
            || built.PreSocksResult is not null))
            return OperationView.Fail("mac_tun_generated_core_required", ApiMessageKeys.CoreTunNotSupported);
        return helperReady ? null : OperationView.Fail("mac_tun_helper_unavailable", ApiMessageKeys.CoreTunNotSupported);
    }
}
