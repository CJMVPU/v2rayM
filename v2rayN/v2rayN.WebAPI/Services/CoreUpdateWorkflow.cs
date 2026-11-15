using ServiceLib.Enums;
using v2rayN.WebAPI.MacOS;

namespace v2rayN.WebAPI.Services;

internal static class CoreUpdateRuntimePolicy
{
    public static bool IsTargetRunning(ECoreType target, ECoreType runningCore, DateTimeOffset? startedAt) =>
        startedAt is not null && target == runningCore;
}

internal static class CoreUpdateWorkflow
{
    internal const string CommittedUpdateUnconfirmedDetail =
        "The new Core was already committed and has been retained in both update stores. " +
        "Final acknowledgement was interrupted; runtime health still requires confirmation. No rollback was performed.";
    public static void RestorePreviousDirectory(
        string installPath,
        string backupPath,
        bool candidateInstalled,
        bool hadInstalledCore)
    {
        if (candidateInstalled && Directory.Exists(installPath))
        {
            Directory.Delete(installPath, recursive: true);
        }
        if (hadInstalledCore && Directory.Exists(backupPath) && !Directory.Exists(installPath))
        {
            Directory.Move(backupPath, installPath);
        }
    }

    public static async Task<CoreUpdateRollbackResult> RollBackAndRestoreAsync(
        Func<Task> restoreFilesAsync,
        Func<Task> initializePreviousCoreAsync,
        bool wasRunning,
        Func<Task<bool>> restartPreviousCoreAsync,
        Func<Task>? rollbackTrustedCoreAsync = null)
    {
        if (rollbackTrustedCoreAsync is not null)
        {
            try { await rollbackTrustedCoreAsync(); }
            catch (MacHelperUpdateException exception) when (exception.Code == "update_already_committed")
            {
                // The helper's durable commit cannot be undone. Leave the matching
                // local candidate and runtime untouched; commit alone is not health.
                return new CoreUpdateRollbackResult(false, false, UpdateCommitted: true);
            }
        }
        await restoreFilesAsync();
        await initializePreviousCoreAsync();
        var restarted = !wasRunning || await restartPreviousCoreAsync();
        return new CoreUpdateRollbackResult(FilesRestored: true, CoreRestarted: restarted);
    }

    public static async Task<TResult> StageThenApplyAsync<TStage, TResult>(
        Func<Task<TStage>> stageAsync,
        Func<TStage, Task<TResult>> applyAsync)
    {
        var staged = await stageAsync();
        return await applyAsync(staged);
    }

    public static async Task<TResult> StageAllThenApplyAsync<TTarget, TStage, TResult>(
        IReadOnlyList<TTarget> targets,
        Func<TTarget, Task<TStage>> stageAsync,
        Func<IReadOnlyList<TStage>, Task<TResult>> applyAsync,
        Func<Task>? beforeApplyAsync = null)
    {
        var staged = new List<TStage>(targets.Count);
        foreach (var target in targets)
        {
            staged.Add(await stageAsync(target));
        }
        if (beforeApplyAsync is not null)
        {
            await beforeApplyAsync();
        }
        return await applyAsync(staged);
    }
}

internal sealed record CoreUpdateRollbackResult(bool FilesRestored, bool CoreRestarted, bool UpdateCommitted = false)
{
    public bool Completed => !UpdateCommitted && FilesRestored && CoreRestarted;
}
