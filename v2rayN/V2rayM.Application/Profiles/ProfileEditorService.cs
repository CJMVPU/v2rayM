using V2rayM.Domain.Profiles;

namespace V2rayM.Application.Profiles;

/// Edit session retains the upstream document in the adapter. Only typed facts cross into
/// the application; adding upstream fields does not require duplicating the whole DTO.
public interface IProfileEditSession
{
    ProfileEditFacts Facts { get; }
    string Id { get; }
    void Bind(ProfileIdentity identity);
    Task<bool> HasCycleAsync();
    Task<int> PersistAsync(bool isNew);
}
public interface IProfileEditorRepository
{
    string SelectedGroup { get; }
    Task<ProfileIdentity?> FindAsync(string id);
    Task<bool> GroupExistsAsync(string id);
    Task<int> CountChildrenAsync(IReadOnlyList<string> ids);
    bool IsRunning(string id);
}
public enum ProfileSaveStatus { Saved, NotFound, ImmutableProtocol, GroupNotFound, InvalidChildren, ValidationFailed, Rejected, PersistenceFailed, RestartFailed }
public sealed record ProfileSaveResult(ProfileSaveStatus Status, string? Id = null, bool Restarted = false,
    ProfileValidation Validation = ProfileValidation.Valid, string? GroupId = null, int PersistenceCode = 0, Exception? Error = null);

/// Caller holds lifecycle serialization; validation, identity binding and persistence share
/// the mutation scope. Runtime restart occurs only after releasing that mutation scope.
public sealed class ProfileEditorService(IProfileEditorRepository repository, IMutationScope mutations,
    IProfileCatalogEvents events)
{
    public async Task<ProfileSaveResult> SaveAsync(IProfileEditSession edit, string? profileId, Func<Task<bool>> restart)
    {
        if (!edit.Facts.Supported) return new(ProfileSaveStatus.ValidationFailed, Validation: ProfileValidation.Unsupported);
        var isNew = string.IsNullOrWhiteSpace(profileId);
        var wasRunning = false;
        var result = await mutations.RunAsync(async () =>
        {
            ProfileIdentity identity;
            if (!isNew)
            {
                var existing = await repository.FindAsync(profileId!);
                if (existing is null) return new ProfileSaveResult(ProfileSaveStatus.NotFound);
                if (existing.ProtocolIdentity != edit.Facts.ProtocolIdentity) return new ProfileSaveResult(ProfileSaveStatus.ImmutableProtocol);
                identity = existing;
            }
            else
            {
                var group = repository.SelectedGroup;
                if (group.Length > 0 && !await repository.GroupExistsAsync(group))
                    return new ProfileSaveResult(ProfileSaveStatus.GroupNotFound, GroupId: group);
                identity = new(string.Empty, edit.Facts.ProtocolIdentity, group, false);
            }
            edit.Bind(identity);
            var facts = edit.Facts;
            var validation = ProfileEditing.Validate(facts);
            if (validation != ProfileValidation.Valid) return new ProfileSaveResult(ProfileSaveStatus.ValidationFailed, Validation: validation);
            if (facts.Kind == ProfileKind.Group)
            {
                if (!string.IsNullOrWhiteSpace(facts.ChildGroup) && !await repository.GroupExistsAsync(facts.ChildGroup))
                    return new ProfileSaveResult(ProfileSaveStatus.GroupNotFound);
                if (await repository.CountChildrenAsync(facts.ChildIds) != facts.ChildIds.Distinct(StringComparer.Ordinal).Count()
                    || await edit.HasCycleAsync()) return new ProfileSaveResult(ProfileSaveStatus.InvalidChildren);
            }
            wasRunning = !isNew && repository.IsRunning(identity.Id);
            int code;
            try { code = await edit.PersistAsync(isNew); }
            catch (Exception error) { return new ProfileSaveResult(ProfileSaveStatus.PersistenceFailed, edit.Id, Error: error); }
            return code == 0 ? new ProfileSaveResult(ProfileSaveStatus.Saved, edit.Id)
                : new ProfileSaveResult(ProfileSaveStatus.Rejected, edit.Id, PersistenceCode: code);
        });
        if (result.Status != ProfileSaveStatus.Saved) return result;
        if (wasRunning)
        {
            var restarted = await restart();
            result = result with { Status = restarted ? ProfileSaveStatus.Saved : ProfileSaveStatus.RestartFailed, Restarted = restarted };
        }
        events.Changed(repository.SelectedGroup);
        return result;
    }
}
