namespace V2rayM.Domain.Backups;

public sealed record RestoreAdmission(bool Allowed, bool RequiresReplacementPlan, bool HasReplacementPlan)
{
    public bool CanProceed => Allowed && (!RequiresReplacementPlan || HasReplacementPlan);
}
