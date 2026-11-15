namespace V2rayM.Domain.Telemetry;

/// Time-weighted trailing minute. Values remain KiB deltas; cumulative accounting stays upstream.
public sealed class TrafficAverageWindow
{
    private sealed record Sample(DateTimeOffset End, double Seconds, double[] Values);
    private readonly object _gate = new();
    private readonly Queue<Sample> _samples = new();
    private const double WindowSeconds = 60;
    private DateTimeOffset? _lastEnd;
    public void Clear() { lock (_gate) Reset(); }
    private void Reset() { _samples.Clear(); _lastEnd = null; }

    public void Add(TrafficMeasurement item)
    {
        var at = item.SampledAt;
        lock (_gate)
        {
            var values = new double[] { item.ProxyUp, item.ProxyDown, item.DirectUp, item.DirectDown };
            if (!double.IsFinite(item.SampleSeconds) || item.SampleSeconds <= 0
                || values.Any(value => !double.IsFinite(value) || value < 0)) { Reset(); return; }
            if (_lastEnd is { } previous && at <= previous) { Reset(); return; }
            // Do not average across a lost sampler, sleep, or a core reset.
            if (item.SampleSeconds > 15 || (_lastEnd is { } last && (at - last).TotalSeconds > 15))
                Reset();
            if (item.SampleSeconds > 15) return;
            _samples.Enqueue(new(at, item.SampleSeconds, values));
            _lastEnd = at;
            while (_samples.TryPeek(out var first) && first.End <= at.AddSeconds(-WindowSeconds)) _samples.Dequeue();
        }
    }

    public TrafficMeasurement? Read(DateTimeOffset now)
    {
        lock (_gate)
        {
            if (_samples.Count == 0) return null;
            var end = _lastEnd!.Value;
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
