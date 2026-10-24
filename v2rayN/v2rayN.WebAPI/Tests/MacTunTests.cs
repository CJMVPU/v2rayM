using System.Diagnostics;
using System.Text.Json;
using ServiceLib.Enums;
using ServiceLib.Handler.Builder;
using ServiceLib.Models.CoreConfigs;
using ServiceLib.Models.Entities;
using v2rayN.WebAPI.MacOS;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Tests;

public class MacTunTests
{
    [Test]
    public async Task NativeTunSettingsRejectInvalidMtuAndExclusions()
    {
        await V2rayRuntime.ValidMacNativeTunSettings(new(1500, false, ["192.168.0.0/16", "fd00::/8"])).Should().BeTrue();
        await V2rayRuntime.ValidMacNativeTunSettings(new(0, false, [])).Should().BeFalse();
        await V2rayRuntime.ValidMacNativeTunSettings(new(1280, false, [])).Should().BeTrue();
        await V2rayRuntime.ValidMacNativeTunSettings(new(65535, false, [])).Should().BeTrue();
        await V2rayRuntime.ValidMacNativeTunSettings(new(1279, false, [])).Should().BeFalse();
        await V2rayRuntime.ValidMacNativeTunSettings(new(65536, false, [])).Should().BeFalse();
        await V2rayRuntime.ValidMacNativeTunSettings(new(1500, false, ["example.org/24"])).Should().BeFalse();
        await V2rayRuntime.ValidMacNativeTunSettings(new(1500, false, ["10.0.0.0/33"])).Should().BeFalse();
        await V2rayRuntime.ValidMacNativeTunSettings(new(1500, true, ["::/129"])).Should().BeFalse();
        await V2rayRuntime.ValidMacNativeTunSettings(new(1500, true, [null!])).Should().BeFalse();
        await V2rayRuntime.ValidMacNativeTunSettings(new(1500, true, [" "])).Should().BeFalse();
    }

    private static CoreConfigContextBuilderAllResult Built(bool tun, ECoreType core = ECoreType.Xray, EConfigType config = EConfigType.VMess) =>
        new(new CoreConfigContextBuilderResult(new CoreConfigContext
        {
            Node = new ProfileItem { ConfigType = config }, RunCoreType = core, IsTunEnabled = tun,
        }, NodeValidatorResult.Empty()), null);

    [Test]
    public async Task TunRequiresMacHelperAndGeneratedAllowlistedCore()
    {
        await (MacTunLaunchPolicy.Validate(Built(false), false, false) is null).Should().BeTrue();
        await MacTunLaunchPolicy.Validate(Built(true), false, true)!.Code.Should().BeEqualTo("tun_not_supported");
        await MacTunLaunchPolicy.Validate(Built(true), true, false)!.Code.Should().BeEqualTo("mac_tun_helper_unavailable");
        await (MacTunLaunchPolicy.Validate(Built(true), true, true) is null).Should().BeTrue();
        await MacTunLaunchPolicy.Validate(Built(true, (ECoreType)24), true, true)!.Code.Should().BeEqualTo("mac_tun_generated_core_required");
        await MacTunLaunchPolicy.Validate(Built(true, ECoreType.mihomo), true, true)!.Code.Should().BeEqualTo("mac_tun_generated_core_required");
        await MacTunLaunchPolicy.Validate(Built(true, config: EConfigType.Custom), true, true)!.Code.Should().BeEqualTo("mac_tun_generated_core_required");
    }

    [Test]
    public async Task NativeMacLaunchKeepsSavedConfigurationIndependent()
    {
        var saved = new ServiceLib.Models.Configs.Config
        {
            TunModeItem = new ServiceLib.Models.Configs.TunModeItem { EnableTun = true },
        };
        var native = MacNativeTunConfig.ForLaunch(saved, true);
        await native.TunModeItem.EnableTun.Should().BeTrue();
        await ReferenceEquals(saved, MacNativeTunConfig.ForLaunch(saved, false)).Should().BeTrue();
        saved.TunModeItem.EnableTun = false;
        await ReferenceEquals(saved, MacNativeTunConfig.ForLaunch(saved, true)).Should().BeTrue();
    }

    [Test]
    public async Task LegacyPreSocksTunIsRejectedBeforeStoppingTheServingCore()
    {
        var built = new CoreConfigContextBuilderAllResult(Built(false).MainResult, Built(true).MainResult);
        await MacTunLaunchPolicy.Validate(built, true, true)!.Code.Should().BeEqualTo("mac_tun_generated_core_required");
    }

    [Test]
    public async Task FailedHelperPreflightDoesNotStopRunningCore()
    {
        var built = Built(true);
        var preflight = CoreLaunchPreflight.Validate(new ProfileItem(), built, _ => null,
            context => MacTunLaunchPolicy.Validate(context, true, false));
        var stopped = false;
        var result = await CoreRestartFlow.ExecuteAsync(() => Task.FromResult(preflight),
            () => { stopped = true; return Task.CompletedTask; }, () => { }, _ => throw new InvalidOperationException());
        await stopped.Should().BeFalse();
        await result.Code.Should().BeEqualTo("mac_tun_helper_unavailable");
    }

    [Test]
    public async Task RequestCarriesImmutableResourceBytesWithoutGivingRootAUserFilePath()
    {
        var directory = Path.Combine(Path.GetTempPath(), "v2raym-request-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var rules = Path.Combine(directory, "certificate.pem");
            var config = Path.Combine(directory, "config.json");
            await File.WriteAllBytesAsync(rules, [1, 2, 3]);
            await File.WriteAllTextAsync(config, JsonSerializer.Serialize(new
            {
                inbounds = new[] { new { protocol = "tun" } },
                streamSettings = new { tlsSettings = new { certificates = new[] { new { certificateFile = rules } } } },
            }));
            using var request = JsonDocument.Parse(MacTunCoreLauncher.BuildRequest("xray", config));
            await File.WriteAllBytesAsync(rules, [9]);
            var name = request.RootElement.GetProperty("paths").GetProperty(rules).GetString()!;
            var snapshot = request.RootElement.GetProperty("resources").GetProperty(name).GetBytesFromBase64();
            await snapshot.SequenceEqual(new byte[] { 1, 2, 3 }).Should().BeTrue();
            await name.Contains('/').Should().BeFalse();
            await request.RootElement.TryGetProperty("executable", out _).Should().BeFalse();
            await request.RootElement.TryGetProperty("arguments", out _).Should().BeFalse();
        }
        finally { Directory.Delete(directory, true); }
    }

    [Test]
    public async Task MissingSignedBundleIsAReportedState()
    {
        var launcher = new MacTunCoreLauncher(null);
        var response = await launcher.ProbeAsync();
        await response.Success.Should().BeFalse();
        await response.Code.Should().BeEqualTo("signed_app_bundle_required");
    }

    [Test]
    public async Task BridgeHandshakeAndStopUseTheOwnedCorePid()
    {
        if (OperatingSystem.IsWindows()) return;
        var directory = Path.Combine(Path.GetTempPath(), "v2raym-fake-bridge-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var bridge = Path.Combine(directory, "bridge.sh");
            // This fixture launches only ordinary /bin/sleep; no XPC service, root or network.
            await File.WriteAllTextAsync(bridge, """
                #!/bin/sh
                IFS= read -r request
                /bin/sleep 30 &
                owned_pid=$!
                printf '{"success":true,"code":"ok","state":"running","protocolVersion":2,"pid":%s,"executablePath":"/bin/sleep"}\n' "$owned_pid"
                IFS= read -r stop
                kill -TERM "$owned_pid"
                wait "$owned_pid" 2>/dev/null
                printf '{"success":true,"code":"ok","state":"stopped","protocolVersion":2}\n'
                """);
            File.SetUnixFileMode(bridge, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            var failures = new List<string>();
            using var process = await MacTunProcess.StartAsync(bridge, "{}", null, failures.Add);
            await (process.Id > 1).Should().BeTrue();
            using var owned = Process.GetProcessById(process.Id);
            await owned.HasExited.Should().BeFalse();
            await process.StopAsync();
            await process.HasExited.Should().BeTrue();
            await failures.Count.Should().BeEqualTo(0);
        }
        finally { Directory.Delete(directory, true); }
    }
}
