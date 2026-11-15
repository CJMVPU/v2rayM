using V2rayM.Domain.Updates;

namespace V2rayM.Application.Updates;

public enum BatchTargetKind { Core, GeoFiles, Application }
public sealed record BatchUpdateTarget(string Id, BatchTargetKind Kind);
public sealed record BatchUpdateCheck(UpdateDecision Decision, string? Version, string? Detail,
    bool CanInstall = true, string? InstallRestriction = null);
public sealed record BatchUpdateProgress(string Phase, bool Complete, bool Success, string? Version = null, string? Detail = null, bool? CoreWasRunning = null);
public interface IBatchUpdateArtifact { string? Version { get; } }
public interface IUpdateBatchRuntime
{
    bool IsStopping { get; }
    bool CoreRunning { get; }
    ValueTask<IUpdateOperationLease> EnterAsync();
    Task<BatchUpdateCheck> CheckAsync(BatchUpdateTarget target, bool apply, CancellationToken token);
    Task<IBatchUpdateArtifact> StageAsync(BatchUpdateTarget target, CancellationToken token);
    Task<CoreUpdateApplyResult> ApplyCoreAsync(IBatchUpdateArtifact artifact, CancellationToken token);
    Task ApplyGeoAsync(CancellationToken token);
    Task<bool> ReloadGeoAsync(CancellationToken token);
    Task HandoffApplicationAsync(IBatchUpdateArtifact artifact, CancellationToken token);
    Task DiscardAsync(IBatchUpdateArtifact artifact);
    void Cleanup(IBatchUpdateArtifact artifact);
    void Publish(BatchUpdateTarget target, BatchUpdateProgress progress);
    void Complete(bool success, bool apply);
    void Log(string message);
}

/// Selected updates share a maintenance lease. Each core commits independently;
/// staging all packages is not a promise to roll back an already committed target.
public sealed class UpdateBatchService(IUpdateBatchRuntime runtime)
{
    public async Task RunAsync(IReadOnlyList<BatchUpdateTarget> requested, bool apply)
    {
        var targets = requested.DistinctBy(target => target.Id, StringComparer.Ordinal).ToArray();
        var pending = targets.ToDictionary(target => target.Id, _ => (string?)null, StringComparer.Ordinal);
        var artifacts = new List<(BatchUpdateTarget Target, IBatchUpdateArtifact Artifact)>();
        var checks = new Dictionary<string, BatchUpdateCheck>(StringComparer.Ordinal);
        BatchUpdateTarget? current = null;
        var success = true;
        var geo = targets.FirstOrDefault(target => target.Kind == BatchTargetKind.GeoFiles);
        var application = targets.FirstOrDefault(target => target.Kind == BatchTargetKind.Application);
        var reloadGeo = geo is not null && runtime.CoreRunning;
        var handedOff = false;

        void Publish(BatchUpdateTarget target, BatchUpdateProgress progress)
        {
            if (progress.Complete) pending.Remove(target.Id);
            else pending[target.Id] = progress.Version;
            runtime.Publish(target, progress);
        }
        void FailPending(string detail)
        {
            foreach (var target in targets.Where(target => pending.ContainsKey(target.Id)))
                Publish(target, new("failed", true, false, pending[target.Id], detail));
        }
        try
        {
            await using var maintenance = await runtime.EnterAsync();
            var token = maintenance.Token;
            foreach (var target in targets)
            {
                current = target;
                Publish(target, new("checking", false, false));
                if (target.Kind == BatchTargetKind.GeoFiles)
                {
                    if (!apply) Publish(target, new("completed", true, true, Detail:
                        "GeoFiles will be downloaded, validated, and applied only when batch apply is enabled."));
                    continue;
                }
                var check = await runtime.CheckAsync(target, apply, token);
                checks[target.Id] = check;
                switch (check.Decision)
                {
                    case UpdateDecision.Current:
                        Publish(target, new("completed", true, true, check.Version, check.Detail ?? "Already up to date."));
                        break;
                    case UpdateDecision.AwaitingValidation:
                        success = false;
                        Publish(target, new("awaiting-validation", true, false, check.Version, check.Detail));
                        break;
                    case UpdateDecision.Available when !apply:
                        Publish(target, new("completed", true, true, check.Version,
                            check.CanInstall ? "An update is available." : $"An update is available; {check.InstallRestriction}"));
                        break;
                    case UpdateDecision.Available:
                        pending[target.Id] = check.Version;
                        break;
                    default:
                        success = false;
                        Publish(target, new("failed", true, false, check.Version, check.Detail ?? "The update check failed."));
                        break;
                }
            }
            if (!apply) { runtime.Complete(success, false); return; }
            // Unknown decisions fail closed, like explicit failed checks.
            if (checks.Values.Any(check => check.Decision is not (UpdateDecision.Current or UpdateDecision.Available or UpdateDecision.AwaitingValidation)))
            {
                FailPending("No targets were installed because at least one selected update check failed.");
                runtime.Complete(false, true);
                return;
            }
            foreach (var target in targets.Where(target => checks.TryGetValue(target.Id, out var check)
                && check.Decision == UpdateDecision.Available && !check.CanInstall))
            {
                success = false;
                var check = checks[target.Id];
                Publish(target, new("failed", true, false, check.Version, check.InstallRestriction));
            }
            var coreTargets = targets.Where(target => target.Kind == BatchTargetKind.Core && pending.ContainsKey(target.Id)).ToArray();
            foreach (var target in coreTargets)
            {
                current = target;
                var artifact = await runtime.StageAsync(target, token)
                    ?? throw new InvalidOperationException("The update did not produce a staged package.");
                artifacts.Add((target, artifact));
            }
            // Rule files are transactional and applied before restarting any core.
            if (geo is not null)
            {
                current = geo;
                Publish(geo, new("downloading", false, false));
                await runtime.ApplyGeoAsync(token);
                Publish(geo, new("completed", true, true));
            }
            IBatchUpdateArtifact? appArtifact = null;
            if (application is not null && pending.ContainsKey(application.Id))
            {
                current = application;
                appArtifact = await runtime.StageAsync(application, token)
                    ?? throw new InvalidOperationException("The application update did not produce a staged package.");
                artifacts.Add((application, appArtifact));
            }
            foreach (var item in artifacts.Where(item => item.Target.Kind == BatchTargetKind.Core))
                Publish(item.Target, new("waiting", false, false, item.Artifact.Version, "All selected Core packages are staged and verified."));
            foreach (var item in artifacts.Where(item => item.Target.Kind == BatchTargetKind.Core))
            {
                current = item.Target;
                var result = await runtime.ApplyCoreAsync(item.Artifact, token);
                success &= result.Success;
                if (result.Success && result.CoreWasRunning) reloadGeo = false;
                Publish(item.Target, new(result.Success ? "completed" : "failed", true, result.Success,
                    result.Version ?? item.Artifact.Version, result.Detail, result.CoreWasRunning));
            }
            if (reloadGeo && runtime.CoreRunning)
            {
                current = geo;
                Publish(geo!, new("restarting-core", false, false));
                var reloaded = await runtime.ReloadGeoAsync(token);
                success &= reloaded;
                Publish(geo!, new(reloaded ? "completed" : "failed", true, reloaded, Detail:
                    reloaded ? null : "规则文件已更新，但运行内核未能重新加载，请重新连接。"));
            }
            if (appArtifact is not null)
            {
                current = application;
                await runtime.HandoffApplicationAsync(appArtifact, token);
                handedOff = true;
                // Completion belongs to the restart helper after handoff.
                return;
            }
            runtime.Complete(success, true);
        }
        catch (Exception failure)
        {
            var detail = failure is OperationCanceledException && runtime.IsStopping
                ? "Canceled during graceful shutdown." : failure.Message;
            ApplicationDiagnostics.Report(runtime.Log, $"Update batch failed at {current?.Id}: {failure}");
            if (current is not null) Publish(current, new("failed", true, false, Detail: detail));
            FailPending("This target was not applied because the batch could not complete.");
            runtime.Complete(false, apply);
        }
        finally
        {
            // Do not reinterpret the restart helper's ownership as an incomplete update.
            if (handedOff && application is not null) pending.Remove(application.Id);
            try { FailPending("This target was not applied because the batch could not complete."); }
            finally
            {
                foreach (var item in artifacts)
                {
                    try { await runtime.DiscardAsync(item.Artifact); }
                    catch (Exception failure) { ApplicationDiagnostics.Report(runtime.Log, $"Update batch trusted cleanup failed: {failure}"); }
                    try { runtime.Cleanup(item.Artifact); }
                    catch (Exception failure) { ApplicationDiagnostics.Report(runtime.Log, $"Update batch local cleanup failed: {failure}"); }
                }
            }
        }
    }
}
