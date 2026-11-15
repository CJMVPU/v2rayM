namespace V2rayM.Application.Updates;

public interface IApplicationUpdateHandoff
{
    bool OwnershipTransferred { get; }
    Task WriteIntentAsync();
    Task WritePlanAsync();
    void LaunchHelper();
    void PublishStopping();
    void StopHost();
    Task DeleteIntentAsync();
    void DeletePlan();
    void Log(string message);
}

/// Before launch the host owns recovery artifacts; after launch the detached
/// updater owns them, even if a notification or shutdown request fails.
public sealed class ApplicationUpdateHandoffService(IApplicationUpdateHandoff handoff)
{
    public async Task ExecuteAsync(CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        try
        {
            await handoff.WriteIntentAsync();
            await handoff.WritePlanAsync();
            token.ThrowIfCancellationRequested();
            handoff.LaunchHelper();
            if (!handoff.OwnershipTransferred) throw new InvalidOperationException("The update helper did not accept ownership.");
        }
        catch
        {
            if (!handoff.OwnershipTransferred)
            {
                try { await handoff.DeleteIntentAsync(); }
                catch (Exception failure) { ApplicationDiagnostics.Report(handoff.Log, $"Update intent cleanup failed: {failure}"); }
                try { handoff.DeletePlan(); }
                catch (Exception failure) { ApplicationDiagnostics.Report(handoff.Log, $"Update plan cleanup failed: {failure}"); }
            }
            else
            {
                // Launch may have succeeded before its acknowledgement failed.
                // Keep the helper's recovery files and still release the host.
                try { handoff.StopHost(); }
                catch (Exception failure) { ApplicationDiagnostics.Report(handoff.Log, $"Update host shutdown failed after handoff: {failure}"); }
            }
            throw;
        }
        try { handoff.PublishStopping(); }
        catch (Exception failure) { ApplicationDiagnostics.Report(handoff.Log, $"Update handoff notification failed: {failure}"); }
        ApplicationDiagnostics.Report(handoff.Log, "Handing off the application update to the detached helper.");
        handoff.StopHost();
    }
}
