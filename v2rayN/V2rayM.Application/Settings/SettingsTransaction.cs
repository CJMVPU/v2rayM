using V2rayM.Domain.Runtime;

namespace V2rayM.Application.Settings;

public interface IExclusiveScope
{
    Task<IAsyncDisposable> EnterAsync(CancellationToken token);
}
public interface ISettingsSnapshotStore<TSnapshot>
{
    Task<TSnapshot> CaptureAsync();
    Task RestoreAsync(TSnapshot snapshot);
    Task RecoverPendingRestoreAsync();
}

// Lock order is lifecycle -> mutation. Recovery and capture see the same storage
// generation; the lifecycle lease remains owned until apply/compensation finishes.
public sealed class SettingsTransaction<TSnapshot, TRuntime>(IExclusiveScope lifecycle,
    IMutationScope mutations, ISettingsSnapshotStore<TSnapshot> store)
{
    public async Task<SettingsTransactionContext<TSnapshot, TRuntime>> BeginAsync(Func<TRuntime> runtime,
        Func<TRuntime, CoreRuntimeState> state, Func<bool> hasActiveChild, CancellationToken token)
    {
        var lease = await lifecycle.EnterAsync(token);
        try
        {
            var previous = runtime();
            var active = hasActiveChild();
            var admission = CoreSettingsApplyPolicy.Decide(state(previous), active, changed: false);
            var snapshot = await mutations.RunAsync(async () =>
            {
                await store.RecoverPendingRestoreAsync();
                return await store.CaptureAsync();
            }, token);
            return new(lease, snapshot, previous, active, admission);
        }
        catch { await lease.DisposeAsync(); throw; }
    }

    public Task RestoreAsync(SettingsTransactionContext<TSnapshot, TRuntime> context) =>
        mutations.RunAsync(async () => { await store.RestoreAsync(context.Snapshot); return true; });
}

public sealed class SettingsTransactionContext<TSnapshot, TRuntime>(IAsyncDisposable lease,
    TSnapshot snapshot, TRuntime runtime, bool active, CoreSettingsApplyAction admission) : IAsyncDisposable
{
    private int _disposed;
    public TSnapshot Snapshot { get; } = snapshot;
    public TRuntime PreviousRuntime { get; } = runtime;
    public bool HadActiveChild { get; } = active;
    public CoreSettingsApplyAction Admission { get; } = admission;
    public ValueTask DisposeAsync() => Interlocked.Exchange(ref _disposed, 1) == 0
        ? lease.DisposeAsync() : ValueTask.CompletedTask;
}
