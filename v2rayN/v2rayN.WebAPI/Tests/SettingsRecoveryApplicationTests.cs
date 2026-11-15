using V2rayM.Application;
using V2rayM.Application.Settings;
using V2rayM.Domain.Runtime;

namespace v2rayN.WebAPI.Tests;

public class SettingsRecoveryApplicationTests
{
    [Test]
    public async Task ApplyRestartsChangedRunningCoreExactlyOnceAndNormalizesEmptyFault()
    {
        var runtime = new Runtime { Current = new(CoreRuntimeState.Running, true) };
        var service = new SettingsApplyService();
        var result = await service.CompleteAsync(runtime, "test", true, _ => throw new Exception("Unexpected rollback"));
        await result.Restarted.Should().BeTrue();
        await string.Join(",", runtime.Calls).Should().BeEqualTo("restart");
        runtime.Calls.Clear();
        await (await service.CompleteAsync(runtime, "test", false, _ => throw new Exception())).Success.Should().BeTrue();
        await runtime.Calls.Count.Should().BeEqualTo(0);
        runtime.Current = new(CoreRuntimeState.Faulted, false);
        await (await service.CompleteAsync(runtime, "test", true, _ => throw new Exception())).Restarted.Should().BeFalse();
        await runtime.Current.State.Should().BeEqualTo(CoreRuntimeState.Stopped);
    }

    [Test]
    [Arguments(CoreRuntimeState.Restarting, true, "core_runtime_busy")]
    [Arguments(CoreRuntimeState.Running, false, "core_runtime_faulted")]
    [Arguments(CoreRuntimeState.Stopped, true, "core_runtime_faulted")]
    public async Task InconsistentOrTransitionStateCompensatesWithoutRestart(CoreRuntimeState state, bool child, string code)
    {
        var runtime = new Runtime { Current = new(state, child) };
        var calls = 0;
        var result = await new SettingsApplyService().CompleteAsync(runtime, "test", true, failure =>
        { calls++; return Task.FromResult(new SettingsRollbackResult(true, true, true, failure)); });
        await calls.Should().BeEqualTo(1);
        await result.Success.Should().BeFalse();
        await result.FailureCode.Should().BeEqualTo(code);
        await result.Rollback!.Detail.Should().BeEqualTo(code);
        await runtime.Calls.Count.Should().BeEqualTo(0);
    }

    [Test]
    [Arguments(false)]
    [Arguments(true)]
    public async Task StructuredAndThrownRestartFailuresBothCompensate(bool throws)
    {
        var runtime = new Runtime { Current = new(CoreRuntimeState.Running, true), FailRestart = true, ThrowRestart = throws };
        var rollback = new SettingsRollbackResult(false, false, true, "incomplete");
        var calls = 0;
        var result = await new SettingsApplyService().CompleteAsync(runtime, "test", true, _ => { calls++; return Task.FromResult(rollback); });
        await result.Success.Should().BeFalse();
        await result.Restarted.Should().BeFalse();
        await result.Rollback.Should().BeEqualTo(rollback);
        await calls.Should().BeEqualTo(1);
    }

    [Test]
    public async Task RecoveryRestoresConfigurationBeforeTouchingRuntimeAndKeepsOriginalHealthyProcess()
    {
        var runtime = new Runtime { Current = new(CoreRuntimeState.Running, true, true) };
        var result = await new SettingsRecoveryService().RestoreAsync(runtime, true, "failed", () =>
        { runtime.Calls.Add("files"); return Task.CompletedTask; });
        await result.RolledBack.Should().BeTrue();
        await string.Join(",", runtime.Calls).Should().BeEqualTo("files,restore");
    }

    [Test]
    public async Task DifferentRunningProcessMustBeStoppedBeforeRestoringPreviousRuntime()
    {
        var runtime = new Runtime { Current = new(CoreRuntimeState.Running, true, false) };
        var result = await new SettingsRecoveryService().RestoreAsync(runtime, true, "failed");
        await result.RolledBack.Should().BeTrue();
        await string.Join(",", runtime.Calls).Should().BeEqualTo("restore,stop,start");
    }

    [Test]
    public async Task StoppedIntentNeverStartsCoreDuringRecovery()
    {
        var runtime = new Runtime { Current = new(CoreRuntimeState.Faulted, false) };
        var result = await new SettingsRecoveryService().RestoreAsync(runtime, false, "failed");
        await result.OldRuntimeRestored.Should().BeTrue();
        await string.Join(",", runtime.Calls).Should().BeEqualTo("restore,stop,stopped");
    }

    [Test]
    [Arguments(false)]
    [Arguments(true)]
    public async Task AdditionalRollbackFailureStillRestoresConfigButPreventsRelaunch(bool originalHealthy)
    {
        var runtime = new Runtime { Current = new(originalHealthy ? CoreRuntimeState.Running : CoreRuntimeState.Stopped, originalHealthy, originalHealthy) };
        var result = await new SettingsRecoveryService().RestoreAsync(runtime, true, "failed", () => throw new Exception("files failed"));
        await result.RolledBack.Should().BeFalse();
        await result.ConfigRestored.Should().BeTrue();
        await result.OldRuntimeRestored.Should().BeEqualTo(originalHealthy);
        await runtime.Calls.Contains("start").Should().BeFalse();
        await result.Detail.Should().BeEqualTo("files failed");
    }

    [Test]
    [Arguments("restore", false)]
    [Arguments("stop", true)]
    [Arguments("start", true)]
    public async Task RecoveryFailureReportsActualConfigurationRestoration(string failure, bool configRestored)
    {
        var runtime = new Runtime { Current = new(CoreRuntimeState.Faulted, true), Failure = failure };
        var result = await new SettingsRecoveryService().RestoreAsync(runtime, true, "apply failed");
        await result.ConfigRestored.Should().BeEqualTo(configRestored);
        await result.RolledBack.Should().BeFalse();
        await runtime.Current.State.Should().BeEqualTo(CoreRuntimeState.Faulted);
        await runtime.Calls.Last().Should().BeEqualTo("fault");
        if (failure is "restore" or "stop") await runtime.Calls.Contains("start").Should().BeFalse();
    }

    [Test]
    public async Task FailedCaptureReleasesLifecycleLeaseAndRecoveryRemainsInMutationScope()
    {
        var scope = new Scope(); var store = new Store(scope) { RejectCapture = true };
        var service = new SettingsTransaction<string, CoreRuntimeState>(scope, scope, store);
        var failed = false;
        try { await service.BeginAsync(() => CoreRuntimeState.Stopped, state => state, () => false, CancellationToken.None); }
        catch (InvalidOperationException) { failed = true; }
        await failed.Should().BeTrue();
        await scope.Releases.Should().BeEqualTo(1);
        store.RejectCapture = false;
        var context = await service.BeginAsync(() => CoreRuntimeState.Running, state => state, () => true, CancellationToken.None);
        await context.HadActiveChild.Should().BeTrue();
        await service.RestoreAsync(context);
        await scope.Releases.Should().BeEqualTo(1);
        await context.DisposeAsync(); await context.DisposeAsync();
        await scope.Releases.Should().BeEqualTo(2);
        await string.Join(",", store.Calls).Should().BeEqualTo("recover,capture,recover,capture,restore");
    }

    private sealed class Runtime : ISettingsRecoveryRuntime, ISettingsApplyRuntime
    {
        public SettingsRuntimeState Current { get; set; } = new(CoreRuntimeState.Stopped, false);
        public List<string> Calls = [];
        public string? Failure;
        public bool ThrowRestart, FailRestart;
        public Task RestoreConfigurationAsync()
        { Calls.Add("restore"); if (Failure == "restore") throw new InvalidOperationException("restore failed"); return Task.CompletedTask; }
        public Task<RuntimeCommandResult> RestartAsync()
        { Calls.Add("restart"); if (ThrowRestart) throw new InvalidOperationException("restart threw"); return Task.FromResult(new RuntimeCommandResult(!FailRestart, "restart failed")); }
        public Task<RuntimeCommandResult> StopAsync()
        { Calls.Add("stop"); if (Failure != "stop") Current = new(CoreRuntimeState.Stopped, false); return Task.FromResult(new RuntimeCommandResult(Failure != "stop", "stop failed")); }
        public Task<RuntimeCommandResult> StartPreviousAsync()
        { Calls.Add("start"); return Task.FromResult(new RuntimeCommandResult(Failure != "start", "start failed")); }
        public void SetStopped() { Calls.Add("stopped"); Current = new(CoreRuntimeState.Stopped, false); }
        public void SetFaulted(string detail) { Calls.Add("fault"); Current = Current with { State = CoreRuntimeState.Faulted }; }
        public void Log(string message) { }
    }
    private sealed class Scope : IExclusiveScope, IMutationScope, IAsyncDisposable
    {
        public int Releases;
        public bool Mutation;
        public Task<IAsyncDisposable> EnterAsync(CancellationToken token) => Task.FromResult<IAsyncDisposable>(this);
        public ValueTask DisposeAsync() { Releases++; return ValueTask.CompletedTask; }
        public async Task<T> RunAsync<T>(Func<Task<T>> action, CancellationToken token = default)
        { Mutation = true; try { return await action(); } finally { Mutation = false; } }
    }
    private sealed class Store(Scope scope) : ISettingsSnapshotStore<string>
    {
        public bool RejectCapture;
        public List<string> Calls = [];
        private void Check(string step) { if (!scope.Mutation) throw new Exception("Mutation scope required"); Calls.Add(step); }
        public Task<string> CaptureAsync() { Check("capture"); if (RejectCapture) throw new InvalidOperationException(); return Task.FromResult("snapshot"); }
        public Task RestoreAsync(string snapshot) { Check("restore"); return Task.CompletedTask; }
        public Task RecoverPendingRestoreAsync() { Check("recover"); return Task.CompletedTask; }
    }
}
