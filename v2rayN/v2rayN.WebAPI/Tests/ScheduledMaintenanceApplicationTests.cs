using V2rayM.Application.Runtime;
using V2rayM.Domain.Runtime;

namespace v2rayN.WebAPI.Tests;

public class ScheduledMaintenanceApplicationTests
{
    [Test]
    [Arguments(1L, 24, "Subscriptions,CoreUpdateCheck")]
    [Arguments(20L, 24, "Subscriptions,SaveState")]
    [Arguments(60L, 2, "Subscriptions,SaveState,CleanupFiles")]
    [Arguments(120L, 2, "Subscriptions,SaveState,CleanupFiles,GeoUpdate")]
    [Arguments(1440L, 24, "Subscriptions,SaveState,CleanupFiles,GeoUpdate")]
    [Arguments(1441L, 24, "Subscriptions,CoreUpdateCheck")]
    [Arguments(1440L, 0, "Subscriptions,SaveState,CleanupFiles")]
    public async Task CadencePreservesOrderedMaintenanceAndDisabledGeoUpdates(long minute, int hours, string expected)
    {
        await string.Join(",", MaintenanceSchedule.Due(minute, hours)).Should().BeEqualTo(expected);
    }

    [Test]
    public async Task OneMaintenanceFailureDoesNotSkipOtherDueActions()
    {
        var runtime = new Runtime { FailSubscriptions = true };
        await new ScheduledMaintenanceService(runtime).RunOnceAsync(60, default);
        await string.Join(",", runtime.Actions).Should().BeEqualTo("Subscriptions,SaveState,CleanupFiles,GeoUpdate");
        await runtime.Errors.Single().Should().BeEqualTo(MaintenanceAction.Subscriptions);
    }

    [Test]
    public async Task CallerCancellationStopsTheRemainingActions()
    {
        using var cancel = new CancellationTokenSource();
        var runtime = new Runtime { Cancel = cancel };
        var cancelled = false;
        try { await new ScheduledMaintenanceService(runtime).RunOnceAsync(60, cancel.Token); }
        catch (OperationCanceledException) { cancelled = true; }
        await cancelled.Should().BeTrue();
        await runtime.Actions.Count.Should().BeEqualTo(1);
        await runtime.Errors.Count.Should().BeEqualTo(0);
    }

    [Test]
    public async Task TimedOutStopRetainsTaskOwnershipUntilItIsDrained()
    {
        var pending = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var runtime = new Runtime { Pending = pending.Task };
        var service = new ScheduledMaintenanceService(runtime, new FastClock());
        try
        {
            await service.Start(default, default).Should().BeTrue();
            await runtime.Entered.Task.WaitAsync(TimeSpan.FromSeconds(2));
            await service.Start(default, default).Should().BeFalse();
            using var deadline = new CancellationTokenSource(TimeSpan.FromMilliseconds(60));
            var cancelled = false;
            try { await service.StopAsync(deadline.Token); }
            catch (OperationCanceledException) { cancelled = true; }
            await cancelled.Should().BeTrue();
            await service.Start(default, default).Should().BeFalse();
            pending.TrySetResult();
            await (await service.StopAsync(default)).Should().BeTrue();
            await service.Start(default, default).Should().BeTrue();
        }
        finally { pending.TrySetResult(); await service.StopAsync(default); }
    }

    [Test]
    public async Task ConcurrentStopsShareCancellationAndDrainTheSameRun()
    {
        var pending = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var runtime = new Runtime { Pending = pending.Task };
        var service = new ScheduledMaintenanceService(runtime, new FastClock());
        try
        {
            service.Start(default, default);
            await runtime.Entered.Task.WaitAsync(TimeSpan.FromSeconds(2));
            var first = service.StopAsync(default);
            var second = service.StopAsync(default);
            pending.TrySetResult();
            await (await first).Should().BeTrue();
            await (await second).Should().BeTrue();
            await service.Start(default, default).Should().BeTrue();
        }
        finally { pending.TrySetResult(); await service.StopAsync(default); }
    }

    private sealed class FastClock : TimeProvider
    {
        public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period) =>
            System.CreateTimer(callback, state, TimeSpan.FromMilliseconds(1), period);
    }

    [Test]
    public async Task StopCannotReportDrainedWhileCancellationCallbackStillOwnsResources()
    {
        var runtime = new CallbackRuntime();
        var service = new ScheduledMaintenanceService(runtime, new FastClock());
        using var deadline = new CancellationTokenSource();
        try
        {
            service.Start(default, default);
            await runtime.Entered.Task.WaitAsync(TimeSpan.FromSeconds(2));
            var stopping = service.StopAsync(deadline.Token);
            await runtime.CallbackStarted.Task.WaitAsync(TimeSpan.FromSeconds(2));
            deadline.Cancel();
            var cancelled = false;
            try { await stopping; }
            catch (OperationCanceledException) { cancelled = true; }
            await cancelled.Should().BeTrue();
            await service.Start(default, default).Should().BeFalse();
            runtime.Release.TrySetResult();
            await (await service.StopAsync(default)).Should().BeTrue();
        }
        finally
        {
            runtime.Release.TrySetResult();
            await service.StopAsync(default);
            runtime.Registration.Dispose();
        }
    }

    private sealed class CallbackRuntime : IScheduledMaintenance
    {
        public int GeoUpdateIntervalHours => 0;
        public TaskCompletionSource Entered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource CallbackStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Release { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public CancellationTokenRegistration Registration;
        public async Task ExecuteAsync(MaintenanceAction action, CancellationToken token)
        {
            Registration = token.Register(() => { CallbackStarted.TrySetResult(); Release.Task.GetAwaiter().GetResult(); });
            var pending = Task.Delay(Timeout.InfiniteTimeSpan, token);
            Entered.TrySetResult();
            await pending;
        }
        public void Log(MaintenanceAction action, string detail) { }
    }

    private sealed class Runtime : IScheduledMaintenance
    {
        public int GeoUpdateIntervalHours => 1;
        public bool FailSubscriptions;
        public CancellationTokenSource? Cancel;
        public Task? Pending;
        public List<MaintenanceAction> Actions { get; } = [];
        public List<MaintenanceAction> Errors { get; } = [];
        public TaskCompletionSource Entered { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public async Task ExecuteAsync(MaintenanceAction action, CancellationToken token)
        {
            Actions.Add(action);
            Entered.TrySetResult();
            if (Pending is not null) await Pending;
            Cancel?.Cancel();
            token.ThrowIfCancellationRequested();
            if (FailSubscriptions && action == MaintenanceAction.Subscriptions) throw new IOException("fixture failure");
        }
        public void Log(MaintenanceAction action, string detail) => Errors.Add(action);
    }
}
