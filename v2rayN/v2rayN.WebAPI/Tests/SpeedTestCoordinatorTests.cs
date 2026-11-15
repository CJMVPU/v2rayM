using V2rayM.Application.Diagnostics;
using V2rayM.Domain.Diagnostics;
using V2rayM.Domain.Profiles;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Tests;

public class SpeedTestCoordinatorTests
{
    [Test]
    public async Task StopCancelsActiveBatchAndReleasesAdmissionAfterCompletion()
    {
        var operations = new RuntimeOperationCoordinator(); var batch = new Batch(); var events = new Events();
        var service = new SpeedTestCoordinator(operations, new RuntimeMutationGate(), new Source(batch), events);
        await (await service.StartAsync(SpeedTestAction.Tcping, null, default)).Admission.Should().BeEqualTo(SpeedTestAdmission.Started);
        await batch.Entered.Task;
        await (await service.StartAsync(SpeedTestAction.Tcping, null, default)).Admission.Should().BeEqualTo(SpeedTestAdmission.Busy);
        service.Stop();
        await service.RunningTask!;
        await service.IsRunning.Should().BeFalse();
        await batch.Stopped.Should().BeTrue();
        await events.Failures.Should().BeEqualTo(0);
    }
    [Test]
    public async Task UnsupportedBatchCannotStartEngineButAllowsTcpProbe()
    {
        var batch = new Batch { Supported = false }; var events = new Events();
        var service = new SpeedTestCoordinator(new RuntimeOperationCoordinator(), new RuntimeMutationGate(), new Source(batch), events);
        await (await service.StartAsync(SpeedTestAction.Realping, null, default)).Admission.Should().BeEqualTo(SpeedTestAdmission.Unsupported);
        await service.RunningTask!;
        await service.IsRunning.Should().BeFalse();
        await (await service.StartAsync(SpeedTestAction.Tcping, null, default)).Admission.Should().BeEqualTo(SpeedTestAdmission.Started);
        await batch.Entered.Task; service.Stop(); await service.RunningTask!;
    }
    [Test]
    public async Task ShutdownDrainsActiveSpeedTestAndRejectsNewWork()
    {
        var operations = new RuntimeOperationCoordinator(); var batch = new Batch();
        var service = new SpeedTestCoordinator(operations, new RuntimeMutationGate(), new Source(batch), new Events());
        await service.StartAsync(SpeedTestAction.Tcping, null, default); await batch.Entered.Task;
        await (await operations.StopAndDrainAsync(default)).Should().BeTrue();
        await service.RunningTask!;
        await (await service.StartAsync(SpeedTestAction.Tcping, null, default)).Admission.Should().BeEqualTo(SpeedTestAdmission.Busy);
    }
    [Test]
    public async Task CleanupNeverRemovesUnsupportedComplexSelectedOrRunningRecords()
    {
        await ProfileCleanupPolicy.CanRemove(true, false, false).Should().BeTrue();
        await ProfileCleanupPolicy.CanRemove(false, false, false).Should().BeFalse();
        await ProfileCleanupPolicy.CanRemove(true, true, false).Should().BeFalse();
        await ProfileCleanupPolicy.CanRemove(true, false, true).Should().BeFalse();
    }
    [Test]
    public async Task MaintenanceWaitsForPreparationAndTheEntireBatch()
    {
        var operations = new RuntimeOperationCoordinator(); var batch = new Batch(); var source = new BlockingSource(batch);
        var service = new SpeedTestCoordinator(operations, new RuntimeMutationGate(), source, new Events());
        var start = service.StartAsync(SpeedTestAction.Tcping, null, default);
        await source.Entered.Task;
        var maintenance = operations.EnterExclusiveAsync().AsTask();
        await maintenance.IsCompleted.Should().BeFalse();
        source.Release.SetResult();
        await start; await batch.Entered.Task;
        await maintenance.IsCompleted.Should().BeFalse();
        service.Stop(); await service.RunningTask!;
        await using var lease = await maintenance.WaitAsync(TimeSpan.FromSeconds(2));
    }
    [Test]
    [Arguments(false)]
    [Arguments(true)]
    public async Task ShutdownCannotDrainWhilePreparationStillReadsStorage(bool delayCancellation)
    {
        var operations = new RuntimeOperationCoordinator(); var batch = new Batch(); var source = new BlockingSource(batch);
        var service = new SpeedTestCoordinator(operations, new RuntimeMutationGate(), source, new Events());
        var start = service.StartAsync(SpeedTestAction.Tcping, null, default);
        await source.Entered.Task;
        // Exercise the exact CI race deterministically: close admission before
        // propagating linked-token cancellation, then finish storage preparation.
        if (delayCancellation) operations.RejectNewOperations();
        var drain = delayCancellation ? null : operations.StopAndDrainAsync(default);
        if (drain is not null) await drain.IsCompleted.Should().BeFalse();
        source.Release.SetResult();
        var cancelled = false;
        try { await start; } catch (OperationCanceledException) { cancelled = true; }
        await cancelled.Should().BeTrue();
        await batch.Entered.Task.IsCompleted.Should().BeFalse();
        await (await (drain ?? operations.StopAndDrainAsync(default))).Should().BeTrue();
        await service.RunningTask!;
    }
    private sealed class BlockingSource(Batch batch) : ISpeedTestSource
    {
        public TaskCompletionSource Entered = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Release = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public async Task<ISpeedTestBatch> PrepareAsync(IReadOnlyList<string>? ids)
        { Entered.SetResult(); await Release.Task; return batch; }
    }
    private sealed class Source(Batch batch) : ISpeedTestSource
    { public Task<ISpeedTestBatch> PrepareAsync(IReadOnlyList<string>? ids) => Task.FromResult<ISpeedTestBatch>(batch); }
    private sealed class Batch : ISpeedTestBatch
    {
        public bool Supported = true; public bool Stopped;
        public TaskCompletionSource Entered = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public IReadOnlyList<string> ProfileIds => ["one"];
        public bool CanProbeSingle => true;
        public bool SupportsXray => Supported;
        public async Task RunAsync(SpeedTestAction action, CancellationToken token) { Entered.SetResult(); await Task.Delay(Timeout.Infinite, token); }
        public void Stop() => Stopped = true;
    }
    private sealed class Events : ISpeedTestEvents
    {
        public int Failures;
        public void Started(SpeedTestAction action, IReadOnlyList<string> ids) { }
        public void Failed(Exception error) => Failures++;
    }
}
