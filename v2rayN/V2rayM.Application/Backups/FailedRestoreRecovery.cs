using V2rayM.Domain.Runtime;
using V2rayM.Application.Runtime;

namespace V2rayM.Application.Backups;

public static class FailedRestoreRecovery
{
    public static async Task<RuntimeStartResult?> RecoverAsync(RuntimeRestartIntent intent, int[] remainingProcessIds,
        Action<int[], string> fault, Func<string?, CancellationToken, Task<RuntimeStartResult>> start, Action<string> log)
    {
        if (remainingProcessIds.Length > 0)
        {
            const string detail = "Restore was canceled before database replacement; the runtime could not confirm that the previous Core had stopped.";
            fault(remainingProcessIds, detail);
            BackupDiagnostics.Report(log, detail);
            return null;
        }
        if (!intent.WasRunning) return null;
        var result = await start(intent.PreferredProfileId, CancellationToken.None);
        if (!result.Success) BackupDiagnostics.Report(log, $"The previous Core runtime could not be restored: {result.Code}");
        return result;
    }
}
