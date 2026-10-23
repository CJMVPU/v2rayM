using ServiceLib.Models.Dto;
using v2rayN.WebAPI.Contracts;

namespace v2rayN.WebAPI.Services;

/// Time-weighted trailing minute. Values remain KiB deltas; cumulative accounting stays upstream.
internal sealed class TrafficAverageWindow
{
    private sealed record Sample(DateTimeOffset End, double Seconds, double[] Values);
    private readonly object _gate = new();
    private readonly Queue<Sample> _samples = new();
    private const double WindowSeconds = 60;
    public void Clear() { lock (_gate) _samples.Clear(); }

    public void Add(ServerSpeedItem item, DateTimeOffset at)
    {
        lock (_gate)
        {
            var values = new double[] { item.ProxyUp, item.ProxyDown, item.DirectUp, item.DirectDown };
            if (!double.IsFinite(item.SampleSeconds) || item.SampleSeconds <= 0
                || values.Any(value => !double.IsFinite(value) || value < 0)) { _samples.Clear(); return; }
            if (_samples.TryPeek(out _) && at <= _samples.Last().End) { _samples.Clear(); return; }
            // Do not average across a lost sampler, sleep, or a core reset.
            if (item.SampleSeconds > 15 || (_samples.Count > 0 && (at - _samples.Last().End).TotalSeconds > 15))
                _samples.Clear();
            if (item.SampleSeconds > 15) return;
            _samples.Enqueue(new(at, item.SampleSeconds, values));
            while (_samples.TryPeek(out var first) && first.End <= at.AddSeconds(-WindowSeconds)) _samples.Dequeue();
        }
    }

    public TrafficView? Read(DateTimeOffset now)
    {
        lock (_gate)
        {
            if (_samples.Count == 0) return null;
            var end = _samples.Last().End;
            if (now < end.AddSeconds(-2) || now >= end.AddSeconds(12)) return null;
            var start = end.AddSeconds(-WindowSeconds);
            double seconds = 0;
            var totals = new double[4];
            foreach (var sample in _samples)
            {
                var duration = Math.Min(sample.Seconds, (sample.End - start).TotalSeconds);
                if (duration <= 0) continue;
                seconds += duration;
                for (var i = 0; i < 4; i++) totals[i] += sample.Values[i] * duration / sample.Seconds;
            }
            return seconds <= 0 ? null : new(totals[0], totals[1], totals[2], totals[3], seconds, end);
        }
    }
}
