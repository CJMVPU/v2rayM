using V2rayM.Domain.Runtime;
using V2rayM.Application.Runtime;
namespace v2rayN.WebAPI.Services;

/// Owns live process identity, health observation and core serialization. No
/// configuration persistence or HTTP concerns cross this boundary.
internal sealed class CoreLifecycleService(
    RuntimeExecutionContext execution,
    Func<Task> stopCore,
    Func<CancellationToken, Task> confirmCleanup,
    Func<int, CancellationToken, Task<bool>> isListening,
    Action<CoreRuntimeSnapshot> changed,
    Action<string> log,
    Func<CoreProcessIdentity[], CoreProcessIdentity[]> activeProcesses) : ICoreHealthPublication<CoreRuntimeSnapshot>
{
    private readonly object _snapshotGate = new();
    private readonly SemaphoreSlim _coreMonitorGate = new(1, 1);
    private CoreRuntimeSnapshot _snapshot = CoreRuntimeSnapshot.Stopped;
    private CancellationTokenSource? _coreMonitorCancellation;
    private Task? _coreMonitorTask;
    private CoreProcessIdentity[] _trackedCoreProcesses = [];
    public CoreRuntimeSnapshot Snapshot => Volatile.Read(ref _snapshot);
    public Task<T> ExecuteAsync<T>(Func<Task<T>> action, CancellationToken token) => execution.WithCoreAsync(action, token);
    public void SetSnapshot(CoreRuntimeSnapshot value)
    {
        lock (_snapshotGate)
        {
            PublishSnapshot(value with { ProcessIds = GetActiveProcessIds() });
        }
    }

    private void PublishSnapshot(CoreRuntimeSnapshot value)
    {
        Volatile.Write(ref _snapshot, value);
        if (value.State != CoreRuntimeState.Running) _coreMonitorCancellation?.Cancel();
        changed(value);
    }

    public bool TryMarkFaulted(CoreRuntimeSnapshot expected, CoreHealthFailure failure)
    {
        lock (_snapshotGate)
        {
            // Snapshot identity is the revision; even equal-valued command
            // transitions create a new snapshot and invalidate older probes.
            if (!ReferenceEquals(expected, _snapshot) || _snapshot.State != CoreRuntimeState.Running) return false;
            PublishSnapshot(expected with { State = CoreRuntimeState.Faulted,
                ProcessIds = GetActiveProcessIds(), LastFailure = FailureMessage(failure) });
            return true;
        }
    }

    internal static string FailureMessage(CoreHealthFailure failure) => failure switch
    {
        CoreHealthFailure.ProcessExited => "The tracked Core child process exited unexpectedly.",
        CoreHealthFailure.ListenerUnavailable => "The running Core no longer owns its expected proxy listener.",
        _ => throw new ArgumentOutOfRangeException(nameof(failure)),
    };

    public CoreHealthObservation ObserveHealth(CoreRuntimeSnapshot captured, int[] processIds, bool listening, CancellationToken token = default) =>
        new CoreHealthObservationService<CoreRuntimeSnapshot>(this).Observe(captured,
            new(captured.State, processIds.Length > 0, listening), token);
    public async Task StartMonitorAsync()
    {
        await StopMonitorAsync();
        var cancellation = new CancellationTokenSource();
        var token = cancellation.Token;
        lock (_snapshotGate)
        {
            _coreMonitorCancellation = cancellation;
            _coreMonitorTask = Task.Run(() => MonitorCoreRuntimeAsync(token));
        }
    }

    public async Task StopMonitorAsync()
    {
        await _coreMonitorGate.WaitAsync();
        try
        {
            CancellationTokenSource? cancellation;
            Task? task;
            lock (_snapshotGate)
            {
                cancellation = _coreMonitorCancellation;
                task = _coreMonitorTask;
                _coreMonitorCancellation = null;
                _coreMonitorTask = null;
            }
            if (cancellation is null) return;
            cancellation.Cancel();
            if (task is not null)
            {
                try { await task.WaitAsync(TimeSpan.FromSeconds(2)); }
                catch (OperationCanceledException) { }
                catch (TimeoutException) { log("Core runtime monitor did not stop within its cleanup budget."); }
            }
            cancellation.Dispose();
        }
        finally
        {
            _coreMonitorGate.Release();
        }
    }

    public CoreProcessIdentity[] GetActiveProcesses() =>
        activeProcesses(Volatile.Read(ref _trackedCoreProcesses));

    public int[] GetActiveProcessIds() =>
        GetActiveProcesses().Select(process => process.ProcessId).ToArray();

    public bool HasTrackedProcesses => GetActiveProcesses().Length > 0;

    public void SetTrackedProcesses(IEnumerable<CoreProcessIdentity> processes) =>
        Volatile.Write(ref _trackedCoreProcesses, processes.DistinctBy(process => process.ProcessId).ToArray());

    public async Task StopAndConfirmAsync(CancellationToken cancellationToken)
    {
        await stopCore();
        await confirmCleanup(cancellationToken);

        var deadline = DateTimeOffset.UtcNow.AddSeconds(5);
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var activeProcesses = GetActiveProcesses();
            // Port occupancy is not process ownership: another program may bind a just-released
            // TCP or UDP port before this check. Only Web's captured process identities can
            // keep stop pending or cause a stop failure.
            if (activeProcesses.Length == 0)
            {
                SetTrackedProcesses([]);
                return;
            }

            if (DateTimeOffset.UtcNow >= deadline)
            {
                var details = new List<string>();
                if (activeProcesses.Length > 0)
                {
                    details.Add($"Core processes remain: {string.Join(",", activeProcesses.Select(process => process.ProcessId))}.");
                }
                throw new TimeoutException(string.Join(" ", details));
            }

            await Task.Delay(TimeSpan.FromMilliseconds(100), cancellationToken);
        }
    }

    private async Task MonitorCoreRuntimeAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                await Task.Delay(TimeSpan.FromMilliseconds(750), cancellationToken);
                var snapshot = Snapshot;
                if (snapshot.State != CoreRuntimeState.Running || snapshot.ProxyPort is not int port)
                {
                    continue;
                }

                var processIds = GetActiveProcessIds();
                var listening = await isListening(port, cancellationToken);
                var observed = ObserveHealth(snapshot, processIds, listening, cancellationToken);
                if (observed.PublishedFailure)
                {
                    log(FailureMessage(processIds.Length == 0 ? CoreHealthFailure.ProcessExited : CoreHealthFailure.ListenerUnavailable));
                    return;
                }
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // Expected when the Core is stopped, restarted, or the Web host shuts down.
        }
        catch (Exception exception)
        {
            log($"Core runtime monitor failed: {exception}");
        }
    }

}
