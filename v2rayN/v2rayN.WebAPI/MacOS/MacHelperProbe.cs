namespace v2rayN.WebAPI.MacOS;

/// Cache availability, never owned core liveness. Concurrent observers share one
/// bounded bridge invocation; critical actions bypass the completed cache.
internal sealed class MacHelperProbe(Func<Task<MacHelperResponse>> probe, Func<DateTimeOffset>? clock = null)
{
    private readonly object _gate = new();
    private readonly Func<DateTimeOffset> _clock = clock ?? (() => DateTimeOffset.UtcNow);
    private Task<MacHelperResponse>? _pending;
    private MacHelperResponse? _cached;
    private DateTimeOffset _expires;
    private long _generation;

    internal Task<MacHelperResponse> ReadAsync(bool fresh = false)
    {
        lock (_gate)
        {
            if (!fresh && _cached is not null && _clock() < _expires) return Task.FromResult(_cached);
            if (_pending is not null) return _pending;
            var generation = _generation;
            return _pending = Task.Run(async () =>
            {
                try
                {
                    var result = await probe();
                    lock (_gate)
                    {
                        if (generation == _generation)
                        {
                            _cached = result;
                            _expires = _clock().AddSeconds(result.Success ? 30 : 2);
                        }
                    }
                    return result;
                }
                finally { lock (_gate) { if (generation == _generation) _pending = null; } }
            });
        }
    }
    internal void Invalidate()
    {
        lock (_gate) { _generation++; _cached = null; _pending = null; }
    }
}
