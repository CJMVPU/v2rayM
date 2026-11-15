using ServiceLib.Common;
using ServiceLib.Enums;
using ServiceLib.Models.Entities;
using V2rayM.Application.Settings;
using v2rayN.WebAPI.Adapters.Settings;
using v2rayN.WebAPI.Services;

namespace v2rayN.WebAPI.Tests;

public class RegionalPresetApplicationTests
{
    [Test]
    public async Task ConflictLeavesTheNewerConfigurationAndRuntimeUntouched()
    {
        var session = new Session { IsCurrent = false };
        var result = await new RegionalPresetService().ApplyAsync(session, default);
        await result.Status.Should().BeEqualTo(RegionalPresetStatus.Conflict);
        await session.Calls.Count.Should().BeEqualTo(0);
    }

    [Test]
    public async Task ApplyCommitsFilesOnlyAfterRuntimeAcceptance()
    {
        var session = new Session();
        var result = await new RegionalPresetService().ApplyAsync(session, default);
        await result.Status.Should().BeEqualTo(RegionalPresetStatus.Applied);
        await string.Join(",", session.Calls).Should().BeEqualTo("write,files,runtime,commit-files");
    }

    [Test]
    [Arguments(false)]
    [Arguments(true)]
    public async Task PartialConfigurationFailureRestoresBeforeAnyFilesOrRuntimeApply(bool restoreFails)
    {
        var session = new Session { FailWrite = true, FailConfigRestore = restoreFails };
        var result = await new RegionalPresetService().ApplyAsync(session, default);
        await result.Status.Should().BeEqualTo(RegionalPresetStatus.ConfigurationFailed);
        await string.Join(",", session.Calls).Should().BeEqualTo(restoreFails
            ? "write,restore-config,restore-runtime" : "write,restore-config");
    }

    [Test]
    [Arguments(false)]
    [Arguments(true)]
    public async Task FileFailureRestoresRuntimeAndReportsIncompleteFileRecovery(bool restoreFails)
    {
        var session = new Session { FailFiles = true, FailFilesRestore = restoreFails };
        var result = await new RegionalPresetService().ApplyAsync(session, default);
        await result.Status.Should().BeEqualTo(RegionalPresetStatus.FilesFailed);
        await result.FilesRestored.Should().BeEqualTo(!restoreFails);
        await result.Rollback!.RolledBack.Should().BeEqualTo(!restoreFails);
        await session.RecoveryFilesRestored.Should().BeEqualTo(!restoreFails);
        await string.Join(",", session.Calls).Should().BeEqualTo("write,files,restore-files,restore-runtime");
    }

    [Test]
    [Arguments(false)]
    [Arguments(true)]
    public async Task FailedRuntimeDoesNotRecoverTwiceAndTracksFileRollbackFailure(bool restoreFails)
    {
        var session = new Session { FailRuntime = true, FailFilesRestore = restoreFails };
        var result = await new RegionalPresetService().ApplyAsync(session, default);
        await result.Status.Should().BeEqualTo(RegionalPresetStatus.RuntimeFailed);
        await result.FilesRestored.Should().BeEqualTo(!restoreFails);
        await session.Calls.Contains("restore-runtime").Should().BeFalse();
        await session.Calls.Contains("commit-files").Should().BeFalse();
    }

    [Test]
    [Arguments(false)]
    [Arguments(true)]
    public async Task CancellationAfterWritingWaitsForCompensation(bool duringFiles)
    {
        using var cancel = new CancellationTokenSource();
        var session = new Session { Cancel = cancel, CancelDuringFiles = duringFiles };
        var cancelled = false;
        try { await new RegionalPresetService().ApplyAsync(session, cancel.Token); }
        catch (OperationCanceledException) { cancelled = true; }
        await cancelled.Should().BeTrue();
        await string.Join(",", session.Calls).Should().BeEqualTo(duringFiles
            ? "write,files,restore-files,restore-runtime" : "write,restore-runtime");
    }

    [Test]
    public async Task RelevantStagedStateDetectsLocalEditsButIgnoresUnrelatedSettingsAndReadOrder()
    {
        var config = SniffingSettingsIntegrationTests.CreateConfig();
        var snapshot = new RuntimeConfigSnapshot(config,
            [new RoutingItem { Id = "b", RuleSet = "[]" }, new RoutingItem { Id = "a", Remarks = "local" }],
            [new DNSItem { Id = "dns", CoreType = ECoreType.Xray, Enabled = true, NormalDNS = "original" }], []);
        var fingerprint = ServiceLibRegionalPresetStore.Fingerprint(snapshot);
        var reordered = snapshot with { Routing = snapshot.Routing.Reverse().ToArray() };
        await ServiceLibRegionalPresetStore.Fingerprint(reordered).Should().BeEqualTo(fingerprint);
        config.SpeedTestItem.SpeedTestTimeout += 1;
        await ServiceLibRegionalPresetStore.Fingerprint(snapshot).Should().BeEqualTo(fingerprint);
        var edits = new Action<RuntimeConfigSnapshot>[]
        {
            value => value.Dns[0].Remarks = "renamed during download",
            value => value.Dns[0].Enabled = false,
            value => value.Routing[0].IsActive = true,
            value => value.Routing[0].RuleSet = "[{\"process\":[\"new\"]}]",
            value => value.Config.RoutingBasicItem.RoutingIndexId = "new legacy selection",
            value => value.Config.SimpleDNSItem.RemoteDNS = "new DNS",
        };
        foreach (var edit in edits)
        {
            var changed = JsonUtils.DeepCopy(snapshot)!;
            edit(changed);
            await (ServiceLibRegionalPresetStore.Fingerprint(changed) != fingerprint).Should().BeTrue();
        }
        await (ServiceLibRegionalPresetStore.Fingerprint(snapshot with { Dns = [] }) != fingerprint).Should().BeTrue();
        await (ServiceLibRegionalPresetStore.Fingerprint(snapshot with { Routing = [] }) != fingerprint).Should().BeTrue();
    }

    private sealed class FileRestoreException(Exception inner) : Exception("File restore failed", inner);
    private sealed class Session : IRegionalPresetSession
    {
        public bool IsCurrent { get; init; } = true;
        public bool FailWrite, FailConfigRestore, FailFiles, FailFilesRestore, FailRuntime, CancelDuringFiles;
        public CancellationTokenSource? Cancel;
        public bool RecoveryFilesRestored;
        public List<string> Calls { get; } = [];
        public Task WriteConfigurationAsync(CancellationToken token)
        {
            Calls.Add("write");
            if (FailWrite) throw new IOException("Partial write");
            if (Cancel is not null && !CancelDuringFiles) Cancel.Cancel();
            return Task.CompletedTask;
        }
        public Task<bool> RestoreConfigurationAsync() { Calls.Add("restore-config"); return Task.FromResult(!FailConfigRestore); }
        public Task<SettingsRollbackResult> RestoreRuntimeAsync(string reason, bool filesRestored = true)
        {
            Calls.Add("restore-runtime");
            RecoveryFilesRestored = filesRestored;
            return Task.FromResult(new SettingsRollbackResult(filesRestored, filesRestored, true, null));
        }
        public async Task UpdateFilesAsync(Func<Func<Task>, CancellationToken, Task> beforeCommit, CancellationToken token)
        {
            Calls.Add("files");
            try
            {
                if (CancelDuringFiles) Cancel!.Cancel();
                token.ThrowIfCancellationRequested();
                if (FailFiles) throw new IOException("Partial file replace");
                await beforeCommit(RestoreFilesAsync, token);
                Calls.Add("commit-files");
            }
            catch (Exception exception)
            {
                try { await RestoreFilesAsync(); }
                catch { throw new FileRestoreException(exception); }
                throw;
            }
        }
        private Task RestoreFilesAsync()
        {
            Calls.Add("restore-files");
            if (FailFilesRestore) throw new IOException("File rollback failed");
            return Task.CompletedTask;
        }
        public async Task<bool> ApplyRuntimeAsync(Func<Task> rollbackFiles)
        {
            Calls.Add("runtime");
            if (FailRuntime) { try { await rollbackFiles(); } catch { } return false; }
            return true;
        }
        public bool FilesWereRestored(Exception exception) => exception is not FileRestoreException;
        public void Log(string message) { }
    }
}
