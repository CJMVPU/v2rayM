using ServiceLib.Common;
using ServiceLib.Handler;
using v2rayN.WebAPI.Contracts;

namespace v2rayN.WebAPI.Services;

public sealed record MacTunInput(bool Enabled);
public sealed record MacNativeTunSettings(int Mtu, bool EnableIPv6Address, string[]? RouteExcludeAddress);
public sealed record MacTunStatus(bool PlatformSupported, bool HelperAvailable, string HelperCode, string HelperState,
    bool Enabled, string[] SupportedCores, string CoreSource, string RuntimeState, int[] PrivilegedCoreProcessIds);

public sealed partial class V2rayRuntime
{
    public MacNativeTunSettings GetMacNativeTunSettings() => new(Config.TunModeItem.Mtu,
        Config.TunModeItem.EnableIPv6Address, Config.TunModeItem.RouteExcludeAddress?.ToArray() ?? []);

    internal static bool ValidMacNativeTunSettings(MacNativeTunSettings input) => input.Mtu is >= 1280 and <= 65535
        && (input.RouteExcludeAddress ?? []).Length <= 128
        && (input.RouteExcludeAddress ?? []).All(value =>
        {
            if (string.IsNullOrWhiteSpace(value)) return false;
            var parts = value.Split('/');
            return parts.Length == 2 && System.Net.IPAddress.TryParse(parts[0], out var address)
                && int.TryParse(parts[1], out var prefix) && prefix >= 0
                && prefix <= (address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork ? 32 : 128);
        });

    public async Task<MacTunStatus> GetMacTunStatusAsync(bool fresh = false)
    {
        if (fresh) _macTunLauncher.InvalidateProbe();
        var helper = fresh ? await _macTunLauncher.ProbeAsync() : await _macTunLauncher.ProbeCachedAsync();
        return new(OperatingSystem.IsMacOS(), helper.Success, helper.Code, helper.Success ? "ready" : helper.State,
            Config.TunModeItem.EnableTun, ["xray"], "helper-verified-xray", GetCoreRuntimeState(),
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
                await EnsureConfigSaveSucceededAsync(() => _configStore.SaveAsync());
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
