namespace ServiceLib.Services.Statistics;

public class StatisticsXrayService
{
    public const int SamplingSeconds = 5;
    private readonly object _sampleGate = new();
    private long _sampleGeneration;
    private bool _discardFirstCounter;
    private const long linkBase = 1024;
    private ServerSpeedItem _serverSpeedItem = new();
    private long _sampleTime = System.Diagnostics.Stopwatch.GetTimestamp();
    private readonly Config _config;
    private readonly CancellationTokenSource _cts = new();
    private readonly Func<ServerSpeedItem, Task>? _updateFunc;
    private string Url => $"{Global.HttpProtocol}{Global.Loopback}:{AppManager.Instance.StatePort}/debug/vars";
    private static readonly string _tag = "StatisticsXrayService";

    public StatisticsXrayService(Config config, Func<ServerSpeedItem, Task> updateFunc)
    {
        _config = config;
        _updateFunc = updateFunc;
        // Re-enabling statistics while a core is already running must not add its
        // lifetime counters a second time to the saved node totals.
        _discardFirstCounter = AppManager.Instance.RunningCoreType == ECoreType.Xray;

    }

    public async Task StartAsync()
    {
        // Capture the existing core's baseline before returning from the settings
        // change, so traffic generated after enabling counters is not discarded.
        if (_discardFirstCounter)
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(_cts.Token);
            timeout.CancelAfter(TimeSpan.FromSeconds(2));
            try
            {
                var generation = Interlocked.Read(ref _sampleGeneration);
                var result = await HttpClientHelper.Instance.TryGetAsync(Url, timeout.Token);
                lock (_sampleGate)
                {
                    if (result != null && generation == _sampleGeneration) ParseOutput(result);
                }
            }
            catch (OperationCanceledException) when (!_cts.IsCancellationRequested) { }
        }
        _ = Task.Run(Run);
    }

    public void ResetSample()
    {
        lock (_sampleGate)
        {
            _sampleGeneration++;
            _serverSpeedItem = new();
            _discardFirstCounter = false;
            _sampleTime = System.Diagnostics.Stopwatch.GetTimestamp();
        }
    }

    public void Close()
    {
        try
        {
            _cts.Cancel();
        }
        catch (Exception ex)
        {
            Logging.SaveLog(_tag, ex);
        }
    }

    private async Task Run()
    {
        var token = _cts.Token;

        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(SamplingSeconds));
        try
        {
            while (await timer.WaitForNextTickAsync(token).ConfigureAwait(false))
            {
                try
                {
                    if (AppManager.Instance.RunningCoreType != ECoreType.Xray)
                    {
                        continue;
                    }

                    var generation = Interlocked.Read(ref _sampleGeneration);
                    var result = await HttpClientHelper.Instance.TryGetAsync(Url, token);
                    if (result != null)
                    {
                        ServerSpeedItem? server;
                        lock (_sampleGate)
                        {
                            if (generation != _sampleGeneration) continue;
                            server = ParseOutput(result);
                        }
                        if (server is not null && generation == Interlocked.Read(ref _sampleGeneration))
                            await _updateFunc!.Invoke(server);
                    }
                }
                catch (OperationCanceledException) when (token.IsCancellationRequested)
                {
                    break;
                }
                catch
                {
                    await Task.Delay(3000, token).ConfigureAwait(false);
                }
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        finally { _cts.Dispose(); }
    }

    private ServerSpeedItem? ParseOutput(string result)
    {
        try
        {
            var source = JsonUtils.Deserialize<V2rayMetricsVars>(result);
            if (source?.stats?.outbound == null)
            {
                return null;
            }

            ServerSpeedItem server = new();
            foreach (var key in source.stats.outbound.Keys.Cast<string>())
            {
                var value = source.stats.outbound[key];
                if (value == null)
                {
                    continue;
                }
                var state = JsonUtils.Deserialize<V2rayMetricsVarsLink>(value.ToString());

                if (key.StartsWith(Global.ProxyTag))
                {
                    server.ProxyUp += state.uplink;
                    server.ProxyDown += state.downlink;
                }
                else if (key == Global.DirectTag)
                {
                    server.DirectUp = state.uplink;
                    server.DirectDown = state.downlink;
                }
            }

            server.ProxyUp /= linkBase; server.ProxyDown /= linkBase;
            server.DirectUp /= linkBase; server.DirectDown /= linkBase;
            var now = System.Diagnostics.Stopwatch.GetTimestamp();
            var elapsed = System.Diagnostics.Stopwatch.GetElapsedTime(_sampleTime, now).TotalSeconds;
            _sampleTime = now;
            if (_discardFirstCounter)
            {
                _discardFirstCounter = false;
                _serverSpeedItem = server;
                return new ServerSpeedItem { SampleSeconds = 0 };
            }
            if (server.DirectDown < _serverSpeedItem.DirectDown || server.ProxyDown < _serverSpeedItem.ProxyDown
                || server.DirectUp < _serverSpeedItem.DirectUp || server.ProxyUp < _serverSpeedItem.ProxyUp)
            {
                _serverSpeedItem = server;
                // Invalidate the rolling window without adding negative cumulative bytes.
                return new ServerSpeedItem { SampleSeconds = 0 };
            }

            ServerSpeedItem curItem = new()
            {
                SampleSeconds = Math.Max(elapsed, 0.001),
                ProxyUp = server.ProxyUp - _serverSpeedItem.ProxyUp,
                ProxyDown = server.ProxyDown - _serverSpeedItem.ProxyDown,
                DirectUp = server.DirectUp - _serverSpeedItem.DirectUp,
                DirectDown = server.DirectDown - _serverSpeedItem.DirectDown,
            };
            _serverSpeedItem = server;
            return curItem;
        }
        catch
        {
            // ignored
        }

        return null;
    }
}
