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
    private static CoreConfigContextBuilderAllResult Built(bool tun, ECoreType core = ECoreType.sing_box, EConfigType config = EConfigType.VMess) =>
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
        await MacTunLaunchPolicy.Validate(Built(true, ECoreType.mihomo), true, true)!.Code.Should().BeEqualTo("mac_tun_generated_core_required");
        await MacTunLaunchPolicy.Validate(Built(true, config: EConfigType.Custom), true, true)!.Code.Should().BeEqualTo("mac_tun_generated_core_required");
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
            var rules = Path.Combine(directory, "rules.srs");
            var config = Path.Combine(directory, "config.json");
            await File.WriteAllBytesAsync(rules, [1, 2, 3]);
            await File.WriteAllTextAsync(config, JsonSerializer.Serialize(new
            {
                inbounds = new[] { new { type = "tun" } },
                route = new { rule_set = new[] { new { type = "local", path = rules } } },
            }));
            using var request = JsonDocument.Parse(MacTunCoreLauncher.BuildRequest("sing_box", config));
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
                printf '{"success":true,"code":"ok","state":"running","protocolVersion":1,"pid":%s,"executablePath":"/bin/sleep"}\n' "$owned_pid"
                IFS= read -r stop
                kill -TERM "$owned_pid"
                wait "$owned_pid" 2>/dev/null
                printf '{"success":true,"code":"ok","state":"stopped","protocolVersion":1}\n'
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
