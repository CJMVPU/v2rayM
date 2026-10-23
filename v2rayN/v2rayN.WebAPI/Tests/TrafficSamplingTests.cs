using System.Diagnostics;
using System.Reflection;
using System.Runtime.CompilerServices;
using ServiceLib.Manager;
using ServiceLib.Models.Configs;
using ServiceLib.Models.Dto;
using ServiceLib.Services.Statistics;

namespace v2rayN.WebAPI.Tests;

public class TrafficSamplingTests
{
    [Test]
    public async Task ReenabledSamplerUsesBaselineInsteadOfDuplicatingLifetimeCounters()
    {
        var instance = (StatisticsXrayService)RuntimeHelpers.GetUninitializedObject(typeof(StatisticsXrayService));
        typeof(StatisticsXrayService).GetField("_discardFirstCounter", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(instance, true);
        var parse = typeof(StatisticsXrayService).GetMethod("ParseOutput", BindingFlags.Instance | BindingFlags.NonPublic)!;
        var baseline = (ServerSpeedItem)parse.Invoke(instance, ["{\"stats\":{\"outbound\":{\"proxy\":{\"uplink\":102400,\"downlink\":204800}}}}"] )!;
        await baseline.SampleSeconds.Should().BeEqualTo(0);
        var next = (ServerSpeedItem)parse.Invoke(instance, ["{\"stats\":{\"outbound\":{\"proxy\":{\"uplink\":103424,\"downlink\":206848}}}}"] )!;
        await next.ProxyUp.Should().BeEqualTo(1);
        await next.ProxyDown.Should().BeEqualTo(2);
        await StatisticsXrayService.SamplingSeconds.Should().BeEqualTo(5);
    }
    [Test]
    public async Task CounterResetInEitherDirectionNeverPublishesNegativeTraffic()
    {
        var instance = (StatisticsXrayService)RuntimeHelpers.GetUninitializedObject(typeof(StatisticsXrayService));
        typeof(StatisticsXrayService).GetField("_serverSpeedItem", BindingFlags.Instance | BindingFlags.NonPublic)!
            .SetValue(instance, new ServerSpeedItem { ProxyUp = 100, ProxyDown = 1 });
        typeof(StatisticsXrayService).GetField("_sampleTime", BindingFlags.Instance | BindingFlags.NonPublic)!
            .SetValue(instance, Stopwatch.GetTimestamp() - Stopwatch.Frequency * 2);
        var parse = typeof(StatisticsXrayService).GetMethod("ParseOutput", BindingFlags.Instance | BindingFlags.NonPublic)!;
        var reset = parse.Invoke(instance, ["{\"stats\":{\"outbound\":{\"proxy\":{\"uplink\":1024,\"downlink\":2048}}}}"]);
        await ((ServerSpeedItem)reset!).SampleSeconds.Should().BeEqualTo(0);
        var next = (ServerSpeedItem)parse.Invoke(instance, ["{\"stats\":{\"outbound\":{\"proxy\":{\"uplink\":3072,\"downlink\":4096}}}}"])!;
        await next.ProxyUp.Should().BeEqualTo(2);
        await next.ProxyDown.Should().BeEqualTo(2);
        await (next.SampleSeconds > 0).Should().BeTrue();
    }

    [Test]
    public async Task RealTimeOnlyStillPublishesWithoutCreatingCumulativeRecords()
    {
        var manager = new StatisticsManager();
        var type = typeof(StatisticsManager);
        type.GetField("_config", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(manager,
            new Config { IndexId = "test", GuiItem = new GUIItem { EnableStatistics = false, DisplayRealTimeSpeed = true } });
        ServerSpeedItem? observed = null;
        type.GetField("_updateFunc", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(manager,
            (Func<ServerSpeedItem, Task>)(item => { observed = item; return Task.CompletedTask; }));
        var sample = new ServerSpeedItem { ProxyUp = 10, ProxyDown = 20 };
        await (Task)type.GetMethod("UpdateServerStat", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(manager, [sample])!;
        await ReferenceEquals(observed, sample).Should().BeTrue();
        await (type.GetField("_serverStatItem", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(manager) is null).Should().BeTrue();
    }
}
