namespace V2rayM.Domain.Updates;

public enum UpdateDecision { Current, Available, AwaitingValidation, Failed }

/// Compatibility approval is authoritative even when a download candidate exists.
public static class UpdateAdmission
{
    public static UpdateDecision Decide(UpdateDecision? explicitDecision, bool isUpToDate,
        bool successful, bool hasVersion, bool hasDownload)
    {
        var valid = successful && hasVersion && hasDownload;
        var decision = explicitDecision ?? (isUpToDate ? UpdateDecision.Current
            : valid ? UpdateDecision.Available : UpdateDecision.Failed);
        return decision switch
        {
            UpdateDecision.Available => valid ? decision : UpdateDecision.Failed,
            UpdateDecision.Current or UpdateDecision.AwaitingValidation => decision,
            _ => UpdateDecision.Failed,
        };
    }
}
