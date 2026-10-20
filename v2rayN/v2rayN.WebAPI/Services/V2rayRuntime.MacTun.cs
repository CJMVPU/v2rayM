using ServiceLib.Common;
using ServiceLib.Handler;
using v2rayN.WebAPI.Contracts;

namespace v2rayN.WebAPI.Services;

public sealed record MacTunInput(bool Enabled);
public sealed record MacTunStatus(bool PlatformSupported, bool HelperAvailable, string HelperCode, string HelperState,
    bool Enabled, string[] SupportedCores, string CoreSource, string RuntimeState, int[] PrivilegedCoreProcessIds);

public sealed partial class V2rayRuntime
{
    public async Task<MacTunStatus> GetMacTunStatusAsync()
    {
        var helper = await _macTunLauncher.ProbeAsync();
        return new(OperatingSystem.IsMacOS(), helper.Success, helper.Code, helper.Success ? "ready" : helper.State,
            Config.TunModeItem.EnableTun, ["xray", "sing_box"], "signed-app-bundle", GetCoreRuntimeState(),
            _macTunLauncher.CaptureIdentities().Select(identity => identity.ProcessId).ToArray());
    }

    public async Task<OperationView> SetMacTunAsync(MacTunInput input)
    {
        if (!OperatingSystem.IsMacOS()) return OperationView.Fail("tun_not_supported", ApiMessageKeys.CoreTunNotSupported);
        if (input.Enabled)
        {
            var helper = await _macTunLauncher.ProbeAsync();
            if (!helper.Success) return OperationView.Fail("mac_tun_helper_unavailable", ApiMessageKeys.CoreTunNotSupported,
                new { helperCode = helper.Code });
        }
        await using var context = await BeginCoreSettingsApplyAsync();
        if (context.Failure is { } failure) return failure;
        var changed = Config.TunModeItem.EnableTun != input.Enabled;
        try
        {
            await _mutations.RunAsync(async () =>
            {
                Config.TunModeItem.EnableTun = input.Enabled;
                await EnsureConfigSaveSucceededAsync(() => ConfigHandler.SaveConfig(Config));
            });
            return await CompleteCoreAffectingChangeAsync("macos-tun", changed, context);
        }
        catch
        {
            await RollBackCoreSettingsAsync(context, "mac_tun_apply_failed");
            return OperationView.Fail("mac_tun_apply_failed", ApiMessageKeys.SettingsCoreApplyFailed);
        }
    }
}
