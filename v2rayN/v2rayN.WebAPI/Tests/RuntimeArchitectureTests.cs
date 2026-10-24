using ServiceLib.Models.Configs;
using ServiceLib.Models.Dto;
using ServiceLib.Models.Entities;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Tests;

public class RuntimeArchitectureTests
{
    private static RuntimeConfigSnapshot Snapshot(string id) => new(new Config(),
        [new RoutingItem { Id = id, RuleSet = "unexposed-routing-data" }],
        [new DNSItem { Id = id, TunDNS = "unexposed-dns-data" }],
        [new FullConfigTemplateItem { Id = id, TunConfig = "unexposed-template-data" }]);

    [Test]
    public async Task MultiTableRestoreRollsBackEveryTableWhenAnInsertFails()
    {
        using var db = new SQLite.SQLiteConnection(":memory:");
        db.CreateTable<RoutingItem>(); db.CreateTable<DNSItem>(); db.CreateTable<FullConfigTemplateItem>();
        var original = Snapshot("original");
        db.RunInTransaction(() => ServiceLibRuntimeConfigStore.RestoreTables(db, original));
        var broken = Snapshot("replacement") with { Dns = [new DNSItem { Id = "duplicate" }, new DNSItem { Id = "duplicate" }] };
        var failed = false;
        try { db.RunInTransaction(() => ServiceLibRuntimeConfigStore.RestoreTables(db, broken)); }
        catch (SQLite.SQLiteException) { failed = true; }
        await failed.Should().BeTrue();
        await db.Table<RoutingItem>().Single().Id.Should().BeEqualTo("original");
        await db.Table<DNSItem>().Single().TunDNS.Should().BeEqualTo("unexposed-dns-data");
        await db.Table<FullConfigTemplateItem>().Single().TunConfig.Should().BeEqualTo("unexposed-template-data");
    }

    [Test]
    public async Task FailedJsonSaveAndFailedReplayRetainTheSameIntentUntilNextStartup()
    {
        var directory = Path.Combine(Path.GetTempPath(), "v2raym-recovery-" + Guid.NewGuid().ToString("N"));
        var path = Path.Combine(directory, "restore.json");
        try
        {
            string? database = null;
            string? json = null;
            var first = new JournaledConfigRestorer(() => path, snapshot =>
            {
                database = snapshot.Routing.Single().Id;
                throw new IOException("Injected JSON persistence failure after database commit");
            });
            try { await first.RestoreAsync(Snapshot("old")); } catch (IOException) { }
            await database.Should().BeEqualTo("old");
            await File.Exists(path).Should().BeTrue();
            var savedIntent = await File.ReadAllTextAsync(path);
            if (!OperatingSystem.IsWindows())
                await File.GetUnixFileMode(path).Should().BeEqualTo(UnixFileMode.UserRead | UnixFileMode.UserWrite);
            var second = new JournaledConfigRestorer(() => path, _ => throw new IOException("Injected database restore failure"));
            try { await second.RestoreAsync(Snapshot("must-not-overwrite-pending")); } catch (IOException) { }
            await (await File.ReadAllTextAsync(path)).Should().BeEqualTo(savedIntent);
            var restarted = new JournaledConfigRestorer(() => path, snapshot =>
            {
                database = snapshot.Routing.Single().Id;
                json = snapshot.Dns.Single().Id;
                return Task.CompletedTask;
            });
            await restarted.RecoverAsync();
            await database.Should().BeEqualTo("old");
            await json.Should().BeEqualTo("old");
            await File.Exists(path).Should().BeFalse();
            await restarted.RecoverAsync(); // replay is idempotent after success
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }

    [Test]
    public async Task IncompleteRecoveryJournalIsRetainedAndNeverApplied()
    {
        var path = Path.Combine(Path.GetTempPath(), "v2raym-invalid-recovery-" + Guid.NewGuid().ToString("N"));
        try
        {
            await File.WriteAllTextAsync(path, "{\"Config\":null}");
            var applied = false;
            var restorer = new JournaledConfigRestorer(() => path, _ => { applied = true; return Task.CompletedTask; });
            var failed = false;
            try { await restorer.RecoverAsync(); } catch (InvalidDataException) { failed = true; }
            await failed.Should().BeTrue();
            await applied.Should().BeFalse();
            await File.Exists(path).Should().BeTrue();
        }
        finally { File.Delete(path); }
    }

    [Test]
    public async Task SettingsTransactionOwnsLifecycleGateUntilRollbackFinishes()
    {
        var execution = new RuntimeExecutionContext(new RuntimeOperationCoordinator());
        var store = new MemoryConfigStore();
        var transaction = new CoreSettingsTransaction(execution, store);
        var lifecycle = new CoreLifecycleService(execution, () => Task.CompletedTask, () => { },
            (_, _) => Task.FromResult(true), _ => { }, _ => { }, processes => processes);
        var context = await transaction.BeginAsync(() => lifecycle.Snapshot, () => false, CancellationToken.None);
        var entered = false;
        var start = lifecycle.ExecuteAsync(() => { entered = true; return Task.FromResult(1); }, CancellationToken.None);
        await start.IsCompleted.Should().BeFalse();
        await store.Recovered.Should().BeTrue();
        await transaction.RestoreAsync(context);
        await entered.Should().BeFalse();
        await store.Restored.Should().BeTrue();
        await context.DisposeAsync();
        await context.DisposeAsync();
        await (await start.WaitAsync(TimeSpan.FromSeconds(1))).Should().BeEqualTo(1);
    }

    [Test]
    public async Task LifecycleStopConfirmsOwnedProcessesWithoutTreatingListenersAsOwnership()
    {
        var execution = new RuntimeExecutionContext(new RuntimeOperationCoordinator());
        var exited = false;
        var cleaned = false;
        var listeningCalls = 0;
        var lifecycle = new CoreLifecycleService(execution, () => { exited = true; return Task.CompletedTask; },
            () => cleaned = true, (_, _) => { listeningCalls++; return Task.FromResult(true); },
            _ => { }, _ => { }, processes => exited ? [] : processes);
        lifecycle.SetTrackedProcesses([new CoreProcessIdentity(123, "xray", 1, "/isolated/xray")]);
        lifecycle.SetSnapshot(CoreRuntimeSnapshot.Stopped with { State = CoreRuntimeState.Running, ProxyPort = 10808 });
        await lifecycle.Snapshot.ProcessIds.Single().Should().BeEqualTo(123);
        await lifecycle.StopAndConfirmAsync(CancellationToken.None);
        await cleaned.Should().BeTrue();
        await lifecycle.HasTrackedProcesses.Should().BeFalse();
        await listeningCalls.Should().BeEqualTo(0);
    }

    [Test]
    public async Task UpdateCoordinatorRejectsOverlapAndReleasesAdmissionAfterFailure()
    {
        var coordinator = new ModuleUpdateCoordinator(new RuntimeExecutionContext(new RuntimeOperationCoordinator()));
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await coordinator.TryStart("single", () => { }, async () => { await release.Task; throw new IOException("injected"); }).Should().BeTrue();
        var task = coordinator.GetTask("single")!;
        await coordinator.TryStart("batch", () => throw new Exception("must not queue"), () => Task.CompletedTask).Should().BeFalse();
        release.SetResult();
        try { await task; } catch (IOException) { }
        await coordinator.RunningOperations().Count.Should().BeEqualTo(0);
        await coordinator.TryStart("batch", () => { }, () => Task.CompletedTask).Should().BeTrue();
    }

    [Test]
    public async Task TypedUpdateDecisionBlocksCurrentWaitingFailedAndMalformedAvailable()
    {
        foreach (var decision in new[] { UpdateCheckDecision.Current, UpdateCheckDecision.AwaitingValidation, UpdateCheckDecision.Failed })
        {
            var result = new UpdateResult(false, (string?)null) { Decision = decision, Success = true, Version = new SemanticVersion("26.10.21"), Url = "https://example.invalid/xray.zip" };
            await ModuleUpdateCoordinator.Classify(result, false).CanStage.Should().BeFalse();
        }
        await ModuleUpdateCoordinator.Classify(new UpdateResult(false, (string?)null) { Decision = UpdateCheckDecision.Available, Success = true }, false).CanStage.Should().BeFalse();
        await ModuleUpdateCoordinator.Classify(new UpdateResult(false, (string?)null) { Success = true, Version = new SemanticVersion("26.10.21"), Url = "https://example.invalid/xray.zip" }, false).CanStage.Should().BeTrue();
    }

    private sealed class MemoryConfigStore : IRuntimeConfigStore
    {
        public Config Current { get; } = new();
        public bool Recovered { get; private set; }
        public bool Restored { get; private set; }
        public Task<int> SaveAsync() => Task.FromResult(0);
        public Task RecoverPendingRestoreAsync() { Recovered = true; return Task.CompletedTask; }
        public Task<RuntimeConfigSnapshot> CaptureAsync() => Task.FromResult(Snapshot("memory"));
        public Task RestoreAsync(RuntimeConfigSnapshot snapshot) { Restored = true; return Task.CompletedTask; }
    }
}
