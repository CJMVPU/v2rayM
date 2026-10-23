using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Tests;

public class CoreLogPolicyTests
{
    [Test]
    public async Task KnownAffectedCoreCannotOverwriteTheDarwinFix()
    {
        await NativeTunCoreCompatibility.HasKnownDarwinBindingBug("Xray 26.10.21 (Xray) 1b1647c").Should().BeTrue();
        await NativeTunCoreCompatibility.HasKnownDarwinBindingBug("Xray 26.10.21 (Xray) 1b1647c-v2raym-darwin-bind1").Should().BeFalse();
        await NativeTunCoreCompatibility.HasKnownDarwinBindingBug("Xray 26.10.22 (Xray) next").Should().BeFalse();
    }
    private const string Probe = "proxy/socks: Connection closed immediately, likely health check connection";
    [Test]
    public async Task OnlyExactInformationalHealthProbeIsSuppressed()
    {
        await CoreLogPolicy.ShouldKeep("core", "2026/10/22 08:00:00.123456 [Info] [123] " + Probe).Should().BeFalse();
        await CoreLogPolicy.ShouldKeep("core", "[Info] [123] " + Probe).Should().BeFalse();
        foreach (var message in new[] { "[Error] [123] " + Probe, "[Warning] [123] " + Probe,
            "[Info] [123] " + Probe + ": failed", "[Info] [123] failed to set interface > invalid argument",
            "[Error] Unables to find local process name", "[Info] connection reset by peer" })
            await CoreLogPolicy.ShouldKeep("core", message).Should().BeTrue();
        await CoreLogPolicy.ShouldKeep("helper", "[Info] [123] " + Probe).Should().BeTrue();
    }
}
