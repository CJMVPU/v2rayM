using System.Reflection;
using ServiceLib.Helper;
using ServiceLib.Manager;
using ServiceLib.Models.Entities;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Tests;

public class ShutdownStatisticsCheckpointTests
{
    [Test]
    public async Task ActualStatisticsSnapshotIsCommittedToDiskBeforeCoreStopFailure()
    {
        var directory = Path.Combine(Path.GetTempPath(), "v2raym-shutdown-statistics-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "fixture.db");
        var database = new SQLiteHelper(path);
        try
        {
            database.CreateTable<ServerStatItem>();
            var statistics = new StatisticsManager(database);
            typeof(StatisticsManager).GetField("_lstServerStat", BindingFlags.NonPublic | BindingFlags.Instance)!
                .SetValue(statistics, new List<ServerStatItem> { new() { IndexId = "fixture", TotalUp = 1234567, TotalDown = 7654321 } });
            var steps = ShutdownStatisticsCheckpoint.WrapCoreStop(statistics.SaveTo,
                _ => throw new IOException("helper_connection_lost_cleanup_unconfirmed"), _ => { });

            var complete = await ShutdownCleanupSequence.RunAsync(steps, TimeSpan.FromSeconds(10), CancellationToken.None, _ => { });

            await complete.Should().BeFalse();
            using var reopened = new SQLite.SQLiteConnection(path, false);
            var saved = reopened.Table<ServerStatItem>().Single();
            await saved.TotalUp.Should().BeEqualTo(1234567L);
            await saved.TotalDown.Should().BeEqualTo(7654321L);
        }
        finally { await database.DisposeDbConnectionAsync(); Directory.Delete(directory, true); }
    }

    [Test]
    public async Task FailedCoreStopStillPreservesCountersBeforeFailClosedCleanup()
    {
        var visited = new List<string>();
        var saved = 0L;
        var steps = new List<ShutdownCleanupStep> { new("operation drain", _ => { visited.Add("drain"); return Task.FromResult(true); }) };
        steps.AddRange(ShutdownStatisticsCheckpoint.WrapCoreStop(
            () => { saved = 123456789; visited.Add("checkpoint"); return Task.CompletedTask; },
            _ => { visited.Add("Core stop"); throw new IOException("helper_connection_lost_cleanup_unconfirmed"); },
            _ => { }));
        steps.Add(new("statistics close", _ => { visited.Add("statistics close"); return Task.FromResult(true); }));
        steps.Add(new("database close", _ => { visited.Add("database close"); return Task.FromResult(true); }));

        var complete = await ShutdownCleanupSequence.RunAsync(steps, TimeSpan.FromSeconds(1), CancellationToken.None, _ => { });

        await complete.Should().BeFalse();
        await saved.Should().BeEqualTo(123456789L);
        await visited.SequenceEqual(["drain", "checkpoint", "Core stop"]).Should().BeTrue();
    }

    [Test]
    public async Task CheckpointFailureIsLoggedButDoesNotPreventCoreStopAndFinalSave()
    {
        var visited = new List<string>();
        var logs = new List<string>();
        var steps = ShutdownStatisticsCheckpoint.WrapCoreStop(
            () => { visited.Add("checkpoint"); throw new IOException("injected_checkpoint_write_failure"); },
            _ => { visited.Add("Core stop"); return Task.FromResult(true); }, logs.Add).ToList();
        steps.Add(new("statistics close", _ => { visited.Add("statistics close"); return Task.FromResult(true); }));
        steps.Add(new("database close", _ => { visited.Add("database close"); return Task.FromResult(true); }));

        var complete = await ShutdownCleanupSequence.RunAsync(steps, TimeSpan.FromSeconds(1), CancellationToken.None, logs.Add);

        await complete.Should().BeTrue();
        await visited.SequenceEqual(["checkpoint", "Core stop", "statistics close", "database close"]).Should().BeTrue();
        await logs.Any(message => message.Contains("injected_checkpoint_write_failure", StringComparison.Ordinal)).Should().BeTrue();
    }

    [Test]
    public async Task CheckpointAndDiagnosticFailureCannotSkipCoreStop()
    {
        var stopped = false;
        var steps = ShutdownStatisticsCheckpoint.WrapCoreStop(
            () => throw new IOException("checkpoint failed"),
            _ => { stopped = true; return Task.FromResult(true); },
            _ => throw new IOException("log pipe closed"));

        var complete = await ShutdownCleanupSequence.RunAsync(steps, TimeSpan.FromSeconds(1), CancellationToken.None, _ => { });

        await complete.Should().BeTrue();
        await stopped.Should().BeTrue();
    }

    [Test]
    public async Task CheckpointTimeoutWithBrokenDiagnosticsStillStopsCoreBeforeDraining()
    {
        var pending = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var stopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var steps = ShutdownStatisticsCheckpoint.WrapCoreStop(() => pending.Task,
            _ => { stopped.SetResult(); return Task.FromResult(true); },
            _ => throw new IOException("log pipe closed"), TimeSpan.FromMilliseconds(10));

        var execution = ShutdownCleanupSequence.RunAsync(steps, TimeSpan.FromSeconds(1), CancellationToken.None, _ => { });
        await stopped.Task.WaitAsync(TimeSpan.FromSeconds(1));
        await execution.IsCompleted.Should().BeFalse();
        pending.SetResult();
        await (await execution).Should().BeTrue();
    }

    [Test]
    public async Task SlowCheckpointAllowsCoreStopButKeepsDatabaseOpenUntilWriteFinishes()
    {
        var pending = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var coreStopped = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var databaseClosed = false;
        var finalStatisticsSaved = false;
        var steps = ShutdownStatisticsCheckpoint.WrapCoreStop(
            () => pending.Task,
            _ => { coreStopped.SetResult(); return Task.FromResult(true); }, _ => { }, TimeSpan.FromMilliseconds(20)).ToList();
        steps.Add(new("statistics close", _ => { finalStatisticsSaved = true; return Task.FromResult(true); }));
        steps.Add(new("database close", _ => { databaseClosed = true; return Task.FromResult(true); }));

        var execution = ShutdownCleanupSequence.RunAsync(steps, TimeSpan.FromSeconds(2), CancellationToken.None, _ => { });
        await coreStopped.Task.WaitAsync(TimeSpan.FromSeconds(1));
        await databaseClosed.Should().BeFalse();
        await finalStatisticsSaved.Should().BeFalse();
        await execution.IsCompleted.Should().BeFalse();
        pending.SetResult();
        await (await execution).Should().BeTrue();
        await finalStatisticsSaved.Should().BeTrue();
        await databaseClosed.Should().BeTrue();
    }

    [Test]
    public async Task NeverCompletingCheckpointCannotDelayCoreStopOrRaceDatabaseClose()
    {
        var pending = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var coreStopped = false;
        var databaseClosed = false;
        var steps = ShutdownStatisticsCheckpoint.WrapCoreStop(
            () => pending.Task,
            _ => { coreStopped = true; return Task.FromResult(true); }, _ => { }, TimeSpan.FromMilliseconds(10)).ToList();
        steps.Add(new("database close", _ => { databaseClosed = true; return Task.FromResult(true); }));

        var complete = await ShutdownCleanupSequence.RunAsync(steps, TimeSpan.FromMilliseconds(100), CancellationToken.None, _ => { });

        await complete.Should().BeFalse();
        await coreStopped.Should().BeTrue();
        await databaseClosed.Should().BeFalse();
        pending.SetResult();
    }

    [Test]
    public async Task FailedOperationDrainStillSkipsCheckpointAndSharedResourceCleanup()
    {
        var touched = false;
        var steps = new List<ShutdownCleanupStep> { new("operation drain", _ => Task.FromResult(false)) };
        steps.AddRange(ShutdownStatisticsCheckpoint.WrapCoreStop(
            () => { touched = true; return Task.CompletedTask; },
            _ => { touched = true; return Task.FromResult(true); }, _ => { }));

        await (await ShutdownCleanupSequence.RunAsync(steps, TimeSpan.FromSeconds(1), CancellationToken.None, _ => { })).Should().BeFalse();
        await touched.Should().BeFalse();
    }
}
