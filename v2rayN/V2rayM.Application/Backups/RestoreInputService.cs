namespace V2rayM.Application.Backups;

public interface IRestoreInput
{
    bool IsStopping { get; }
    ValueTask<IRestoreLease> EnterAsync(CancellationToken token);
    Task<bool> ReceiveAsync(CancellationToken token);
    void DeleteArchive();
    void Log(string message);
}

public sealed class RestoreInputService(IRestoreInput input)
{
    // Receiving owns a shared operation only. Release it before the caller enters
    // exclusive restore; do not attempt shared-to-exclusive lock promotion.
    public async Task<bool> PrepareAsync(CancellationToken token)
    {
        var transferred = false;
        try
        {
            await using (var lease = await input.EnterAsync(token))
            {
                lease.Token.ThrowIfCancellationRequested();
                if (!await input.ReceiveAsync(lease.Token)) return false;
                if (input.IsStopping) throw new OperationCanceledException(lease.Token);
                lease.Token.ThrowIfCancellationRequested();
            }
            transferred = true;
            return true;
        }
        finally
        {
            if (!transferred)
            {
                try { input.DeleteArchive(); }
                catch (Exception failure) { ApplicationDiagnostics.Report(input.Log, $"Restore input cleanup failed: {failure}"); }
            }
        }
    }
}
