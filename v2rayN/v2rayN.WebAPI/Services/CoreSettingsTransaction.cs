using ServiceLib.Models.Configs;
using ServiceLib.Models.Entities;
using v2rayN.WebAPI.Contracts;

namespace v2rayN.WebAPI.Services;

/// Holds the shared lifecycle gate for the complete apply/rollback window.
/// Config and DB snapshots are captured/restored under the same mutation gate.
internal sealed class CoreSettingsTransaction(RuntimeExecutionContext execution, IRuntimeConfigStore store)
{
    public async Task<CoreSettingsApplyContext> BeginAsync(Func<CoreRuntimeSnapshot> runtime,
        Func<bool> hasActiveChild, CancellationToken token)
    {
        await execution.CoreGate.WaitAsync(token);
        try
        {
            var oldRuntime = runtime();
            var active = hasActiveChild();
            var action = CoreSettingsApplyPolicy.Decide(oldRuntime.State, active, changed: false);
            var failure = action switch
            {
                CoreSettingsApplyAction.Busy => OperationView.Fail("core_runtime_busy", ApiMessageKeys.CoreRuntimeBusy,
                    new { runtimeState = oldRuntime.State.ToString().ToLowerInvariant() }),
                CoreSettingsApplyAction.Inconsistent => OperationView.Fail("core_runtime_faulted", ApiMessageKeys.SettingsCoreApplyFailed,
                    new { runtimeState = oldRuntime.State.ToString().ToLowerInvariant(), processIds = oldRuntime.ProcessIds }),
                _ => null,
            };
            var snapshot = await execution.Mutations.RunAsync(async () =>
            {
                await store.RecoverPendingRestoreAsync();
                return await store.CaptureAsync();
            }, token);
            return new CoreSettingsApplyContext(execution.CoreGate, snapshot, oldRuntime, active, failure);
        }
        catch { execution.CoreGate.Release(); throw; }
    }

    public Task RestoreAsync(CoreSettingsApplyContext context) =>
        execution.Mutations.RunAsync(() => store.RestoreAsync(context.Snapshot));
}

internal sealed class CoreSettingsApplyContext(SemaphoreSlim gate, RuntimeConfigSnapshot snapshot,
    CoreRuntimeSnapshot runtime, bool active, OperationView? failure) : IAsyncDisposable
{
    private int _disposed;
    public RuntimeConfigSnapshot Snapshot { get; } = snapshot;
    public Config OldConfig => Snapshot.Config;
    public RoutingItem[] OldRoutingItems => Snapshot.Routing;
    public DNSItem[] OldDnsItems => Snapshot.Dns;
    public FullConfigTemplateItem[] OldFullConfigTemplates => Snapshot.Templates;
    public CoreRuntimeSnapshot OldRuntime { get; } = runtime;
    public bool HadActiveChild { get; } = active;
    public OperationView? Failure { get; } = failure;
    public ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) == 0) gate.Release();
        return ValueTask.CompletedTask;
    }
}
