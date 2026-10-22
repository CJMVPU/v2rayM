using ServiceLib.Common;
using ServiceLib.Models.Configs;

namespace v2rayN.WebAPI.MacOS;

/// <summary>Keep the native Mac launch choice local to this client; upstream defaults stay intact.</summary>
internal static class MacNativeTunConfig
{
    internal static Config ForLaunch(Config config, bool isMacOS)
    {
        if (!isMacOS || !config.TunModeItem.EnableTun) return config;
        var native = JsonUtils.DeepCopy(config) ?? throw new InvalidOperationException("mac_tun_config_clone_failed");
        return native;
    }
}
