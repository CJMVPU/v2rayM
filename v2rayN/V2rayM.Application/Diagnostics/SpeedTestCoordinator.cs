using V2rayM.Domain.Diagnostics;

namespace V2rayM.Application.Diagnostics;

public interface ISpeedTestBatch
{
    IReadOnlyList<string> ProfileIds { get; }
    bool SupportsXray { get; }
    bool CanProbeSingle { get; }
    Task RunAsync(SpeedTestAction action, CancellationToken token);
    void Stop();
}
public interface ISpeedTestSource
{
    Task<ISpeedTestBatch> PrepareAsync(IReadOnlyList<string>? ids);
}
public interface ISpeedTestEvents
{
    void Started(SpeedTestAction action, IReadOnlyList<string> ids);
    void Failed(Exception error);
}
public enum SpeedTestAdmission { Started, Empty, Unsupported, Busy, InvalidProfile }
public sealed record SpeedTestStartResult(SpeedTestAdmission Admission, int Count = 0);

public sealed class SpeedTestCoordinator(IOperationScope operations, IMutationScope mutations,
    ISpeedTestSource source, ISpeedTestEvents events)
{
    private readonly object _gate = new();
    private Task? _task;
    private CancellationTokenSource? _cancellation;
    private ISpeedTestBatch? _batch;
    public bool IsRunning { get { lock (_gate) return _task is { IsCompleted: false }; } }
    public Task? RunningTask { get { lock (_gate) return _task; } }

    public async Task<SpeedTestStartResult> StartAsync(SpeedTestAction action, IReadOnlyList<string>? ids, CancellationToken token, bool singleProfile = false)
    {
        token.ThrowIfCancellationRequested();
        var admission = new TaskCompletionSource<SpeedTestStartResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        CancellationTokenSource cancellation;
        lock (_gate)
        {
            if (operations.IsStopping || _task is { IsCompleted: false }) return new(SpeedTestAdmission.Busy);
            cancellation = new CancellationTokenSource();
            _cancellation = cancellation;
            _task = Task.Run(async () =>
            {
                try
                {
                    // One lease covers both storage reads and execution. Maintenance cannot
                    // replace the configuration between preparation and running the batch.
                    await operations.RunAsync(async operationToken =>
                    {
                        var batch = await mutations.RunAsync(() => source.PrepareAsync(ids), operationToken);
                        ThrowIfStopping(operationToken);
                        if (singleProfile && !batch.CanProbeSingle)
                        { admission.TrySetResult(new(SpeedTestAdmission.InvalidProfile)); return; }
                        if (batch.ProfileIds.Count == 0) { admission.TrySetResult(new(SpeedTestAdmission.Empty)); return; }
                        if (action != SpeedTestAction.Tcping && !batch.SupportsXray)
                        { admission.TrySetResult(new(SpeedTestAdmission.Unsupported)); return; }
                        lock (_gate)
                        {
                            ThrowIfStopping(operationToken);
                            _batch = batch;
                        }
                        events.Started(action, batch.ProfileIds);
                        admission.TrySetResult(new(SpeedTestAdmission.Started, batch.ProfileIds.Count));
                        ThrowIfStopping(operationToken);
                        await batch.RunAsync(action, operationToken);
                    }, cancellation.Token);
                }
                catch (OperationCanceledException) when (operations.IsStopping || cancellation.IsCancellationRequested)
                { admission.TrySetCanceled(); }
                catch (Exception error)
                {
                    if (!admission.TrySetException(error)) events.Failed(error);
                }
                finally
                {
                    lock (_gate)
                    {
                        if (ReferenceEquals(_cancellation, cancellation)) { _cancellation = null; _batch = null; }
                        cancellation.Dispose();
                    }
                }
            });
        }
        try { return await admission.Task.WaitAsync(token); }
        catch (OperationCanceledException)
        {
            // Request cancellation applies only while awaiting admission. Once returned,
            // the batch belongs to the coordinator and is stopped via Stop or shutdown.
            lock (_gate)
            {
                if (ReferenceEquals(_cancellation, cancellation)) cancellation.Cancel();
            }
            throw;
        }
    }
    private void ThrowIfStopping(CancellationToken token)
    {
        // Admission closes synchronously. Linked cancellation callbacks can still
        // be queued while storage preparation completes on another worker.
        if (operations.IsStopping) throw new OperationCanceledException(operations.ShutdownToken);
        token.ThrowIfCancellationRequested();
    }
    public void Stop()
    {
        lock (_gate) { _cancellation?.Cancel(); _batch?.Stop(); }
    }
}
