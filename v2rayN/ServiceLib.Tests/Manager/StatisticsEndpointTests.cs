namespace ServiceLib.Tests.Manager;

public class StatisticsEndpointTests
{
    [Test]
    public async Task SamplerFollowsServingEndpointAcrossConfigurationChangesAndRestarts()
    {
        // The configuration port is only a candidate. A preflight/rollback can
        // change it while the original child still serves on the captured port.
        var config = new Config { Inbound = [new() { LocalPort = 21000 }] };
        var servingPort = 21004;
        var sampler = new StatisticsXrayService(config, _ => Task.CompletedTask, () => servingPort);
        var url = typeof(StatisticsXrayService).GetProperty("Url", BindingFlags.Instance | BindingFlags.NonPublic)!;
        string Endpoint() => (string)url.GetValue(sampler)!;
        await Endpoint().Should().BeEqualTo("http://127.0.0.1:21004/debug/vars");
        config.Inbound[0].LocalPort = 22000;
        await Endpoint().Should().BeEqualTo("http://127.0.0.1:21004/debug/vars");
        servingPort = 22004;
        await Endpoint().Should().BeEqualTo("http://127.0.0.1:22004/debug/vars");
        await sampler.CloseAsync();
    }
}
