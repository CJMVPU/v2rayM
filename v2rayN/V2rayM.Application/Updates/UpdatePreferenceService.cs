using V2rayM.Domain.Updates;

namespace V2rayM.Application.Updates;

public interface IUpdatePreferenceSession
{
    UpdatePreferences Current { get; }
    Task SaveAsync(UpdatePreferences preferences);
    Task RestoreAsync();
}
public interface IUpdatePreferenceStore { Task<IUpdatePreferenceSession> CaptureAsync(); }
public enum UpdatePreferenceStatus { Saved, Invalid, PersistenceFailed }
public sealed record UpdatePreferenceResult(UpdatePreferenceStatus Status, bool Restored = false,
    string? Detail = null, string? RollbackDetail = null);

public sealed class UpdatePreferenceService(IUpdatePreferenceStore store, IMutationScope mutations, UpdatePreferencePolicy policy)
{
    public Task<UpdatePreferenceResult> SaveAsync(UpdatePreferenceRequest request)
    {
        var validated = policy.Validate(request);
        if (validated is null) return Task.FromResult(new UpdatePreferenceResult(UpdatePreferenceStatus.Invalid));
        return mutations.RunAsync(async () =>
        {
            IUpdatePreferenceSession? session = null;
            try
            {
                session = await store.CaptureAsync();
                await session.SaveAsync(policy.Merge(session.Current, validated));
                return new UpdatePreferenceResult(UpdatePreferenceStatus.Saved);
            }
            catch (Exception failure)
            {
                var restored = false;
                string? rollbackDetail = null;
                if (session is not null)
                {
                    try { await session.RestoreAsync(); restored = true; }
                    catch (Exception rollback) { rollbackDetail = rollback.Message; }
                }
                return new UpdatePreferenceResult(UpdatePreferenceStatus.PersistenceFailed, restored, failure.Message, rollbackDetail);
            }
        });
    }
}
