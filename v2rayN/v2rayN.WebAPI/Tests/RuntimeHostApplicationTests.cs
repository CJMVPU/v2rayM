using System.Collections.Concurrent;
using V2rayM.Application.Runtime;
using V2rayM.Domain.Runtime;

namespace v2rayN.WebAPI.Tests;

public class RuntimeHostApplicationTests
{
    [Test]
    public async Task ConfigurationRecoveryPrecedesComponentsAndRecoveryLaunch()
    {
        var runtime = new Startup { Restore = new(true, "previous") };
        await new RuntimeStartupService(runtime).InitializeAsync(default, false);
        await string.Join(",", runtime.Calls).Should().BeEqualTo(
            "restore-intent,load,recover,components,prepare,services,ready,exists:previous,start:previous,commit-restore,schedules");
    }

    [Test]
    public async Task RecoveryExceptionKeepsItsIntentAndDoesNotStartScheduledMutators()
    {
        var runtime = new Startup { Restore = new(true, "previous"), FailAt = "start:previous" };
        var failed = false;
        try { await new RuntimeStartupService(runtime).InitializeAsync(default, false); }
        catch (InvalidOperationException) { failed = true; }
        await failed.Should().BeTrue();
        await runtime.Calls.Contains("ready").Should().BeTrue();
        await runtime.Calls.Contains("commit-restore").Should().BeFalse();
        await runtime.Calls.Contains("schedules").Should().BeFalse();
    }

    [Test]
    [Arguments(false)]
    [Arguments(true)]
    public async Task StartupWithoutAnIntentHonorsConfiguredAutostart(bool configured)
    {
        var runtime = new Startup { AutoStartConfigured = configured };
        await new RuntimeStartupService(runtime).InitializeAsync(default, false);
        await runtime.Calls.Contains("start:").Should().BeEqualTo(configured);
        await runtime.Calls.Last().Should().BeEqualTo("schedules");
    }

    [Test]
    [Arguments("load")]
    [Arguments("recover")]
    [Arguments("components")]
    [Arguments("prepare")]
    [Arguments("services")]
    public async Task InitializationFailureKeepsTheRecoveryIntentAndDoesNotStartBackgroundWork(string stage)
    {
        var runtime = new Startup { Restore = new(true, "previous"), FailAt = stage };
        var failed = false;
        try { await new RuntimeStartupService(runtime).InitializeAsync(default, false); }
        catch (InvalidOperationException) { failed = true; }
        await failed.Should().BeTrue();
        await runtime.Calls.Contains("commit-restore").Should().BeFalse();
        await runtime.Calls.Contains("schedules").Should().BeFalse();
        await runtime.Calls.Any(call => call.StartsWith("start:")).Should().BeFalse();
        if (stage is "load" or "recover") await runtime.Calls.Contains("components").Should().BeFalse();
    }

    [Test]
    public async Task StoppedRestoreIntentWinsOverUpdateIntentAndConfiguredAutostart()
    {
        var runtime = new Startup { Restore = new(false, null), Update = new(true, "update"), AutoStartConfigured = true };
        await new RuntimeStartupService(runtime).InitializeAsync(default, false);
        await runtime.Calls.Contains("update-intent").Should().BeFalse();
        await runtime.Calls.Any(call => call.StartsWith("start:")).Should().BeFalse();
        await runtime.Calls.Contains("commit-restore").Should().BeTrue();
    }

    [Test]
    public async Task UpdateIntentRemainsOwnedByExternalHealthVerification()
    {
        var runtime = new Startup { Update = new(true, "previous") };
        await new RuntimeStartupService(runtime).InitializeAsync(default, false);
        await runtime.Calls.Contains("start:previous").Should().BeTrue();
        await runtime.Calls.Contains("commit-restore").Should().BeFalse();
    }

    [Test]
    [Arguments(false)]
    [Arguments(true)]
    public async Task FirstRunSetupPreventsBothRecoveryAndConfiguredAutostart(bool restore)
    {
        var runtime = new Startup { Restore = restore ? new(true, "previous") : null, AutoStartConfigured = true };
        await new RuntimeStartupService(runtime).InitializeAsync(default, true);
        await runtime.Calls.Any(call => call.StartsWith("start:")).Should().BeFalse();
        await runtime.Calls.Contains("commit-restore").Should().BeEqualTo(restore);
    }

    [Test]
    public async Task CancellationAfterServicesInitializeStillEnablesShutdownCleanup()
    {
        using var cancel = new CancellationTokenSource();
        var runtime = new Startup { Restore = new(true, "previous"), CancelAfterServices = cancel };
        var cancelled = false;
        try { await new RuntimeStartupService(runtime).InitializeAsync(cancel.Token, false); }
        catch (OperationCanceledException) { cancelled = true; }
        await cancelled.Should().BeTrue();
        await runtime.Calls.Contains("ready").Should().BeTrue();
        await runtime.Calls.Contains("schedules").Should().BeFalse();
        await runtime.Calls.Contains("commit-restore").Should().BeFalse();
    }

    [Test]
    public async Task FullShutdownOrdersDrainsCheckpointStopPersistenceAndDatabaseClose()
    {
        var runtime = new Shutdown();
        var completed = await new RuntimeShutdownService(runtime).ShutdownAsync(default);
        await completed.Should().BeTrue();
        await string.Join(",", runtime.Calls).Should().BeEqualTo(
            "restore-request,schedules,drain,statistics,core,profiles,statistics-close,config,database-close");
    }

    [Test]
    [Arguments("schedules", "restore-request,schedules")]
    [Arguments("drain", "restore-request,schedules,drain")]
    [Arguments("core", "restore-request,schedules,drain,statistics,core")]
    [Arguments("config", "restore-request,schedules,drain,statistics,core,profiles,statistics-close,config")]
    public async Task FailedShutdownBarrierNeverRunsUnsafeLaterSteps(string failAt, string expected)
    {
        var runtime = new Shutdown { FailAt = failAt };
        await (await new RuntimeShutdownService(runtime).ShutdownAsync(default)).Should().BeFalse();
        await string.Join(",", runtime.Calls).Should().BeEqualTo(expected);
    }

    [Test]
    public async Task RestoreOwnedOrUninitializedHostDoesNotSaveOverExternalState()
    {
        var runtime = new Shutdown { ShouldSaveState = false };
        await (await new RuntimeShutdownService(runtime).ShutdownAsync(default)).Should().BeTrue();
        await string.Join(",", runtime.Calls).Should().BeEqualTo("restore-request,schedules,drain");
    }

    [Test]
    public async Task SlowCheckpointAllowsCoreStopButDatabaseCloseWaitsForItsWrite()
    {
        var pending = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var runtime = new Shutdown { PendingStatistics = pending.Task };
        var execution = new RuntimeShutdownService(runtime).ShutdownAsync(default, TimeSpan.FromSeconds(4));
        try
        {
            await runtime.CoreStopped.Task.WaitAsync(TimeSpan.FromSeconds(3));
            await runtime.Calls.Contains("database-close").Should().BeFalse();
            await runtime.Calls.Contains("profiles").Should().BeFalse();
        }
        finally { pending.TrySetResult(); }
        await (await execution).Should().BeTrue();
        await runtime.Calls.Last().Should().BeEqualTo("database-close");
    }

    [Test]
    public async Task DeadlineDisposalKeepsLateTokenUsableAndDoesNotWaitForBlockingCallbacks()
    {
        var deadline = new ShutdownDeadline(TimeSpan.FromSeconds(10), default);
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var registration = deadline.Token.Register(() => { started.TrySetResult(); release.Task.GetAwaiter().GetResult(); });
        var disposal = Task.Run(deadline.Dispose);
        try
        {
            await started.Task.WaitAsync(TimeSpan.FromSeconds(2));
            await disposal.WaitAsync(TimeSpan.FromSeconds(1));
            await deadline.Token.IsCancellationRequested.Should().BeTrue();
            deadline.Dispose(); // Late cleanup can still read the same token.
            await deadline.Token.IsCancellationRequested.Should().BeTrue();
        }
        finally { release.TrySetResult(); await disposal; }
    }

    private sealed class Startup : IRuntimeStartup
    {
        public bool AutoStartConfigured { get; init; }
        public RuntimeRestartIntent? Restore, Update;
        public string? FailAt;
        public CancellationTokenSource? CancelAfterServices;
        public List<string> Calls { get; } = [];
        private void Step(string name) { Calls.Add(name); if (FailAt == name) throw new InvalidOperationException(name); }
        public Task<RuntimeRestartIntent?> LoadRestoreIntentAsync(CancellationToken token) { Step("restore-intent"); return Task.FromResult(Restore); }
        public Task<RuntimeRestartIntent?> LoadUpdateIntentAsync(CancellationToken token) { Step("update-intent"); return Task.FromResult(Update); }
        public void LoadConfiguration() => Step("load");
        public Task RecoverPendingConfigurationAsync() { Step("recover"); return Task.CompletedTask; }
        public void InitializeComponents() => Step("components");
        public Task<StartupProfileSelection> PrepareConfigurationAsync() { Step("prepare"); return Task.FromResult(new StartupProfileSelection("selected", "default")); }
        public Task InitializeServicesAsync() { Step("services"); CancelAfterServices?.Cancel(); return Task.CompletedTask; }
        public void MarkReady() => Step("ready");
        public void StartScheduledOperations(CancellationToken token) => Step("schedules");
        public Task<bool> ProfileExistsAsync(string id, CancellationToken token) { Step("exists:" + id); return Task.FromResult(true); }
        public Task<RuntimeStartResult> StartCoreAsync(string? id, CancellationToken token)
        { Step("start:" + id); return Task.FromResult(new RuntimeStartResult(true, "ok")); }
        public Task CommitRestoreIntentAsync() { Step("commit-restore"); return Task.CompletedTask; }
        public void Log(string source, string message) { }
    }

    private sealed class Shutdown : IRuntimeShutdown
    {
        public bool ShouldSaveState { get; init; } = true;
        public string? FailAt;
        public Task? PendingStatistics;
        public TaskCompletionSource CoreStopped { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public ConcurrentQueue<string> Calls { get; } = [];
        private void Step(string name) { Calls.Enqueue(name); if (FailAt == name) throw new InvalidOperationException(name); }
        public Task WaitForRestoreShutdownRequestAsync(CancellationToken token) { Step("restore-request"); return Task.CompletedTask; }
        public Task<bool> StopSchedulesAsync(CancellationToken token) { Step("schedules"); return Task.FromResult(true); }
        public Task<bool> DrainOperationsAsync(CancellationToken token, TimeSpan remaining) { Step("drain"); return Task.FromResult(true); }
        public Task SaveStatisticsAsync() { Step("statistics"); return PendingStatistics ?? Task.CompletedTask; }
        public Task StopCoreAsync(CancellationToken token) { Step("core"); CoreStopped.TrySetResult(); return Task.CompletedTask; }
        public Task SaveProfilesAsync() { Step("profiles"); return Task.CompletedTask; }
        public Task CloseStatisticsAsync() { Step("statistics-close"); return Task.CompletedTask; }
        public Task SaveConfigurationAsync(CancellationToken token) { Step("config"); return Task.CompletedTask; }
        public Task CloseDatabaseAsync() { Step("database-close"); return Task.CompletedTask; }
        public void Log(string message) { }
        public void SetStage(string? stage) { }
    }
}
