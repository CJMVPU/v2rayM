using V2rayM.Application.Settings;
using V2rayM.Domain.Runtime;
using ServiceLib.Models.Configs;
using ServiceLib.Models.Entities;
using v2rayN.WebAPI.Contracts;

namespace v2rayN.WebAPI.Services;

/// Binds application transaction leases to the existing lifecycle and mutation gates.
internal sealed class CoreSettingsTransaction
{
    private readonly SettingsTransaction<RuntimeConfigSnapshot, CoreRuntimeSnapshot> _transaction;
    public CoreSettingsTransaction(RuntimeExecutionContext execution, IRuntimeConfigStore store) =>
        _transaction = new(new LifecycleScope(execution.CoreGate), execution.Mutations, new SnapshotStore(store));

    public async Task<CoreSettingsApplyContext> BeginAsync(Func<CoreRuntimeSnapshot> runtime,
        Func<bool> hasActiveChild, CancellationToken token) =>
        new(await _transaction.BeginAsync(runtime, value => value.State, hasActiveChild, token));
    public Task RestoreAsync(CoreSettingsApplyContext context) => _transaction.RestoreAsync(context.Transaction);

    private sealed class SnapshotStore(IRuntimeConfigStore store) : ISettingsSnapshotStore<RuntimeConfigSnapshot>
    {
        public Task<RuntimeConfigSnapshot> CaptureAsync() => store.CaptureAsync();
        public Task RestoreAsync(RuntimeConfigSnapshot snapshot) => store.RestoreAsync(snapshot);
        public Task RecoverPendingRestoreAsync() => store.RecoverPendingRestoreAsync();
    }
    private sealed class LifecycleScope(SemaphoreSlim gate) : IExclusiveScope
    {
        public async Task<IAsyncDisposable> EnterAsync(CancellationToken token)
        {
            await gate.WaitAsync(token);
            return new Lease(gate);
        }
        private sealed class Lease(SemaphoreSlim gate) : IAsyncDisposable
        {
            public ValueTask DisposeAsync() { gate.Release(); return ValueTask.CompletedTask; }
        }
    }
}

internal sealed class CoreSettingsApplyContext(SettingsTransactionContext<RuntimeConfigSnapshot, CoreRuntimeSnapshot> transaction) : IAsyncDisposable
{
    internal SettingsTransactionContext<RuntimeConfigSnapshot, CoreRuntimeSnapshot> Transaction => transaction;
    public RuntimeConfigSnapshot Snapshot => transaction.Snapshot;
    public Config OldConfig => Snapshot.Config;
    public RoutingItem[] OldRoutingItems => Snapshot.Routing;
    public DNSItem[] OldDnsItems => Snapshot.Dns;
    public FullConfigTemplateItem[] OldFullConfigTemplates => Snapshot.Templates;
    public CoreRuntimeSnapshot OldRuntime => transaction.PreviousRuntime;
    public bool HadActiveChild => transaction.HadActiveChild;
    public OperationView? Failure => transaction.Admission switch
    {
        CoreSettingsApplyAction.Busy => OperationView.Fail("core_runtime_busy", ApiMessageKeys.CoreRuntimeBusy,
            new { runtimeState = OldRuntime.State.ToString().ToLowerInvariant() }),
        CoreSettingsApplyAction.Inconsistent => OperationView.Fail("core_runtime_faulted", ApiMessageKeys.SettingsCoreApplyFailed,
            new { runtimeState = OldRuntime.State.ToString().ToLowerInvariant(), processIds = OldRuntime.ProcessIds }),
        _ => null,
    };
    public ValueTask DisposeAsync() => transaction.DisposeAsync();
}
