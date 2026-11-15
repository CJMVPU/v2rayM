using V2rayM.Domain.Runtime;

namespace V2rayM.Application.Runtime;

public interface IScheduledMaintenance
{
    int GeoUpdateIntervalHours { get; }
    Task ExecuteAsync(MaintenanceAction action, CancellationToken token);
    void Log(MaintenanceAction action, string detail);
}

public sealed class ScheduledMaintenanceService(IScheduledMaintenance runtime, TimeProvider? timeProvider = null)
{
    private readonly TimeProvider _time = timeProvider ?? TimeProvider.System;
    private readonly object _sync = new();
    private CancellationTokenSource? _cancellation;
    private Task? _task;
    private Task? _cancellationTask;

    public bool Start(CancellationToken hostToken, CancellationToken shutdownToken)
    {
        lock (_sync)
        {
            // A completed/canceled run is still owned until Stop drains its
            // callbacks and disposes it. Start never replaces an undrained run.
            if (_task is not null) return false;
            _cancellation?.Dispose();
            _cancellation = CancellationTokenSource.CreateLinkedTokenSource(hostToken, shutdownToken);
            var token = _cancellation.Token;
            _task = Task.Run(() => RunAsync(token));
            return true;
        }
    }

    public async Task<bool> StopAsync(CancellationToken shutdownToken)
    {
        Task? task;
        CancellationTokenSource? cancellation;
        Task cancellationTask;
        lock (_sync)
        {
            task = _task; cancellation = _cancellation;
            if (task is null || cancellation is null) return true;
            cancellationTask = _cancellationTask ??= cancellation.CancelAsync();
        }
        try
        {
            await cancellationTask.WaitAsync(shutdownToken);
            await task.WaitAsync(shutdownToken);
        }
        catch (OperationCanceledException) when (task.IsCanceled && cancellation.IsCancellationRequested && cancellationTask.IsCompletedSuccessfully) { }
        finally
        {
            lock (_sync)
            {
                if (task.IsCompleted && cancellationTask.IsCompleted && ReferenceEquals(_task, task))
                {
                    cancellation.Dispose();
                    _cancellation = null;
                    _task = null;
                    _cancellationTask = null;
                }
            }
        }
        return true;
    }

    private async Task RunAsync(CancellationToken token)
    {
        for (long elapsedMinutes = 1; ; elapsedMinutes++)
        {
            await Task.Delay(TimeSpan.FromMinutes(1), _time, token);
            await RunOnceAsync(elapsedMinutes, token);
        }
    }

    public async Task RunOnceAsync(long elapsedMinutes, CancellationToken token)
    {
        foreach (var action in MaintenanceSchedule.Due(elapsedMinutes, runtime.GeoUpdateIntervalHours))
        {
            token.ThrowIfCancellationRequested();
            try { await runtime.ExecuteAsync(action, token); }
            catch (OperationCanceledException) when (token.IsCancellationRequested) { throw; }
            catch (Exception exception) { ApplicationDiagnostics.Report(message => runtime.Log(action, message), exception.Message); }
        }
    }
}
