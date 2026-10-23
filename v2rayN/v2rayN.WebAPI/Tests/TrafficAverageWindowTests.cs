using ServiceLib.Models.Dto;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Tests;

public class TrafficAverageWindowTests
{
    private static readonly DateTimeOffset Start = DateTimeOffset.Parse("2026-10-22T00:00:00Z");
    private static ServerSpeedItem Sample(long value, double seconds = 5) => new()
    { ProxyUp = value, ProxyDown = value * 2, DirectUp = value * 3, DirectDown = value * 4, SampleSeconds = seconds };

    [Test]
    public async Task StartupUsesMeasuredDurationThenEvictsOldestMinute()
    {
        var window = new TrafficAverageWindow();
        window.Add(Sample(50), Start);
        await window.Read(Start)!.SampleSeconds.Should().BeEqualTo(5);
        for (var i = 1; i <= 12; i++) window.Add(Sample(100), Start.AddSeconds(i * 5));
        var value = window.Read(Start.AddSeconds(60))!;
        await value.SampleSeconds.Should().BeEqualTo(60);
        await value.ProxyUp.Should().BeEqualTo(1200);
        await value.DirectDown.Should().BeEqualTo(4800);
    }

    [Test]
    public async Task BoundaryIntervalIsWeightedAndStaleSamplesDisappear()
    {
        var window = new TrafficAverageWindow();
        window.Add(Sample(100, 10), Start);
        for (var i = 1; i <= 11; i++) window.Add(Sample(100), Start.AddSeconds(i * 5));
        var value = window.Read(Start.AddSeconds(55))!;
        await value.SampleSeconds.Should().BeEqualTo(60);
        await value.ProxyUp.Should().BeEqualTo(1150);
        await (window.Read(Start.AddSeconds(66)) != null).Should().BeTrue();
        await (window.Read(Start.AddSeconds(67)) == null).Should().BeTrue();
    }

    [Test]
    public async Task CounterResetGapAndStopNeverReusePreviousRates()
    {
        var window = new TrafficAverageWindow();
        window.Add(Sample(100), Start);
        window.Add(Sample(0, 0), Start.AddSeconds(5));
        await (window.Read(Start.AddSeconds(5)) == null).Should().BeTrue();
        window.Add(Sample(5), Start.AddSeconds(10));
        window.Add(Sample(500, 30), Start.AddSeconds(40));
        await (window.Read(Start.AddSeconds(40)) == null).Should().BeTrue();
        window.Add(Sample(10), Start.AddSeconds(45));
        await window.Read(Start.AddSeconds(45))!.ProxyUp.Should().BeEqualTo(10);
        window.Clear();
        await (window.Read(Start.AddSeconds(45)) == null).Should().BeTrue();
    }
}
