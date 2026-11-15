using ServiceLib.Models.Dto;
using v2rayN.WebAPI.Contracts;
using V2rayM.Domain.Telemetry;

namespace v2rayN.WebAPI.Services;

/// Anti-corruption adapter: upstream counters and HTTP DTOs stay outside the domain.
internal sealed class TrafficAverageWindow
{
    private readonly V2rayM.Domain.Telemetry.TrafficAverageWindow _window = new();
    public void Clear() => _window.Clear();
    public void Add(ServerSpeedItem item, DateTimeOffset at) => _window.Add(
        new TrafficMeasurement(item.ProxyUp, item.ProxyDown, item.DirectUp, item.DirectDown, item.SampleSeconds, at));
    public TrafficView? Read(DateTimeOffset now)
    {
        var value = _window.Read(now);
        return value is null ? null : new(value.ProxyUp, value.ProxyDown, value.DirectUp,
            value.DirectDown, value.SampleSeconds, value.SampledAt);
    }
}
